// IdeaImprover.swift
// "Improve this idea": rounds in which the AI rewrites an idea to answer the devil's advocate's objection, then the
// devil's advocate scores the rewrite. Holds the rewrite instructions, schema and parser, the evidence cap and the
// stopping rules. The service in DigestService+Improve.swift makes the paid calls.

import Foundation

/// One version of an idea: its text and the devil's advocate's review of it. Stored as JSON on `KillerIdea`.
struct IdeaVersion: Codable, Equatable, Sendable {
    var pitch, buyer, pricing, whyNow, oneWeekTest, replaces, channel: String
    /// What the rewrite changed and why, in one or two sentences; empty for the original.
    var changes = ""
    var survives = true
    var objection, competitors, verdict: String
    var evidenceNeeded = ""
    var pain, willingToPay, timing, gap, fit, buildability, channelScore: Int

    /// The weighted killer score (the weighting lives on `KillerIdea`).
    var score: Double {
        KillerIdea.killerScore(pain: pain, willingToPay: willingToPay, timing: timing, gap: gap, fit: fit,
                               buildability: buildability, channel: channelScore)
    }

    /// Whether the devil's advocate kept it and no single score is a weak spot (the daily scan's rule).
    var passes: Bool {
        survives && [pain, willingToPay, timing, gap, fit, buildability, channelScore].min() ?? 0 >= KillerEngine.minimumSingleScore
    }
}

extension IdeaVersion {
    /// The idea as it stands now. The saved verdict may end with "Evidence that would raise the score: …", which
    /// is split back out so the rewrite can answer it.
    init(_ idea: KillerIdea) {
        let marker = " Evidence that would raise the score: "
        let parts = idea.verdict.components(separatedBy: marker)
        self.init(pitch: idea.pitch, buyer: idea.buyer, pricing: idea.pricing, whyNow: idea.whyNow,
                  oneWeekTest: idea.oneWeekTest, replaces: idea.replaces, channel: idea.channel,
                  objection: idea.objection, competitors: idea.competitors, verdict: parts[0],
                  evidenceNeeded: parts.count > 1 ? parts.dropFirst().joined(separator: marker) : "",
                  pain: idea.pain, willingToPay: idea.willingToPay, timing: idea.timing, gap: idea.gap, fit: idea.fit,
                  buildability: idea.buildability, channelScore: idea.channelScore)
    }

    /// Copies this version's text and scores onto the idea (the title, evidence and history stay).
    func apply(to idea: KillerIdea) {
        idea.pitch = pitch; idea.buyer = buyer; idea.pricing = pricing; idea.whyNow = whyNow
        idea.oneWeekTest = oneWeekTest; idea.replaces = replaces; idea.channel = channel
        idea.objection = objection; idea.competitors = competitors
        idea.verdict = evidenceNeeded.isEmpty ? verdict : "\(verdict) Evidence that would raise the score: \(evidenceNeeded)"
        idea.pain = pain; idea.willingToPay = willingToPay; idea.timing = timing; idea.gap = gap; idea.fit = fit
        idea.buildability = buildability; idea.channelScore = channelScore
    }

    /// Takes the devil's advocate's review of this version's text.
    func reviewed(by r: KillerEngine.Review) -> IdeaVersion {
        var v = self
        v.survives = r.survives; v.objection = r.objection; v.competitors = r.competitors; v.verdict = r.verdict
        v.evidenceNeeded = r.evidenceNeeded
        v.pain = r.pain; v.willingToPay = r.willingToPay; v.timing = r.timing; v.gap = r.gap; v.fit = r.fit
        v.buildability = r.buildability; v.channelScore = r.channelScore
        return v
    }
}

/// The rules of an improvement run. Testable without the network: the paid steps are passed in.
enum IdeaImprover {
    /// At most this many rounds (each is two paid calls: a rewrite and a review).
    static let maxRounds = 3

    /// Why a run stopped.
    enum Stop: String, Codable, Sendable {
        case reachedBar, noBetter, rejected, maxRounds

        /// Plain-English reason for the screen.
        var text: String {
            switch self {
            case .reachedBar: "Stopped: it reached your quality bar."
            case .noBetter: "Stopped: the last round didn't raise the score."
            case .rejected: "Stopped: the devil's advocate rejected the last rewrite."
            case .maxRounds: "Stopped after \(IdeaImprover.maxRounds) rounds."
            }
        }
    }

    /// A run so far: the original first, then one version per finished round.
    struct Run: Codable, Equatable, Sendable {
        var versions: [IdeaVersion]
        var stop: Stop?
        var madeAt = Date.now
        var model = ""
    }

    /// The rewrite adds no new evidence, so pain and willingness to pay can't rise above the original's: only
    /// scores a rewrite can honestly change (gap, fit, buildability, channel, timing) may go up. Enforced in code,
    /// because the same kind of model is marking a rewrite written to answer it.
    static func capped(_ review: KillerEngine.Review, original: IdeaVersion) -> KillerEngine.Review {
        var r = review
        r.pain = min(r.pain, original.pain)
        r.willingToPay = min(r.willingToPay, original.willingToPay)
        return r
    }

    /// Whether to stop after a round.
    /// - Parameters:
    ///   - latest: The version the round produced (already capped).
    ///   - best: The best score before this round.
    ///   - original: The original's score; the bar only stops a run that started below it.
    ///   - round: The round just finished (1-based).
    ///   - bar: The user's quality bar.
    static func stop(after latest: IdeaVersion, best: Double, original: Double, round: Int, bar: Double) -> Stop? {
        if !latest.passes { return .rejected }
        if latest.score <= best { return .noBetter }
        if original < bar && latest.score >= bar { return .reachedBar }
        return round >= maxRounds ? .maxRounds : nil
    }

    /// Runs rounds until a stop rule is met. Each finished round is reported through `onRound` before the next
    /// starts, so a failure part-way keeps the versions already made.
    /// - Parameters:
    ///   - original: The idea as it stands.
    ///   - bar: The quality bar.
    ///   - beforeCall: Called before every paid call; throws to stop (for example over the daily limit).
    ///   - rewrite: Rewrites a version to answer its objection (paid).
    ///   - review: The devil's advocate's review of a rewritten version (paid).
    ///   - onRound: The run after each round.
    /// - Returns: The finished run.
    @MainActor static func run(from original: IdeaVersion, bar: Double,
                    beforeCall: () throws -> Void,
                    rewrite: (IdeaVersion) async throws -> IdeaVersion,
                    review: (IdeaVersion) async throws -> KillerEngine.Review,
                    onRound: (Run) -> Void) async throws -> Run {
        var run = Run(versions: [original])
        var current = original
        for round in 1...maxRounds {
            try beforeCall()
            let rewritten = try await rewrite(current)
            try beforeCall()
            let latest = rewritten.reviewed(by: capped(try await review(rewritten), original: original))
            let best = run.versions.map(\.score).max() ?? original.score
            run.versions.append(latest)
            run.stop = stop(after: latest, best: best, original: original.score, round: round, bar: bar)
            onRound(run)
            if run.stop != nil { break }
            current = latest
        }
        return run
    }

    // MARK: - The rewrite

    /// Rewrite instructions. Field names must match `rewriteSchema`.
    static let rewriteInstructions = """
    You improve one software product idea for a solo builder who will vibe-code it (build it alone with AI coding \
    tools) and sell it without a sales team. A devil's advocate has reviewed it. Rewrite the idea so it answers the \
    strongest objection and, where you can, the evidence the devil's advocate asked for. You may narrow the buyer, \
    change the price or pricing model, pick a better sales channel, cut scope so it is buildable in about 4 weeks, \
    or sharpen the one-week test. Keep it the same product solving the same buyer problem: don't swap in a \
    different idea. Someone must still pay for it. Don't invent evidence, customers, numbers or competitors' \
    prices; if the objection can only be answered by evidence you don't have, make the one-week test collect it.
    Give: pitch (one sentence); buyer (a specific role in a specific type of business, or a specific type of \
    consumer); pricing (model and price per customer, per month or one-off); replaces (the manual task or \
    workaround it replaces); channel (the named place where the first 100 buyers would be found); why_now; \
    one_week_test (the cheapest way to check demand in 7 days, with a pass mark); changes (one or two sentences: \
    what you changed and how it answers the objection). Write everything in English.
    """ + Prompts.untrustedData

    /// The rewrite prompt: the idea, its review and its evidence titles.
    static func rewritePrompt(_ v: IdeaVersion, title: String, evidence: [String], aboutMe: String) -> String {
        var text = "About me: " + (aboutMe.isEmpty ? "(not provided)" : aboutMe) + "\n\n"
        text += ideaText(v, title: title, evidence: evidence)
        text += "\n\nDevil's advocate:\nStrongest objection: \(v.objection)\nCompetitors: \(v.competitors)\nVerdict: \(v.verdict)"
        if !v.evidenceNeeded.isEmpty { text += "\nEvidence that would raise the score: \(v.evidenceNeeded)" }
        return text
    }

    /// The review prompt, in the daily scan's shape so the devil's advocate judges it the same way. Only the new
    /// version is shown, not the earlier rounds.
    static func reviewPrompt(_ v: IdeaVersion, title: String, evidence: [String], aboutMe: String) -> String {
        "About me: " + (aboutMe.isEmpty ? "(not provided)" : aboutMe) + "\n\nIdeas:\n\n" + ideaText(v, title: title, evidence: evidence)
    }

    private static func ideaText(_ v: IdeaVersion, title: String, evidence: [String]) -> String {
        var text = "Title: \(title)\nPitch: \(v.pitch)\nBuyer: \(v.buyer)\nPricing: \(v.pricing)"
        if !v.replaces.isEmpty { text += "\nReplaces: \(v.replaces)" }
        if !v.channel.isEmpty { text += "\nSales channel: \(v.channel)" }
        text += "\nWhy now: \(v.whyNow)\nOne-week test: \(v.oneWeekTest)\nEvidence:" + (evidence.isEmpty ? " (none cited)" : "")
        for item in evidence { text += "\n- \(item)" }
        return text
    }

    static let rewriteFields = ["pitch", "buyer", "pricing", "replaces", "channel", "why_now", "one_week_test", "changes"]

    /// JSON Schema for the rewrite. Keep in sync with `parseRewrite` and the instructions.
    static let rewriteSchema: [String: Any] = [
        "type": "object",
        "properties": Dictionary(uniqueKeysWithValues: rewriteFields.map { ($0, ["type": "string"] as [String: Any]) }),
        "required": rewriteFields,
        "additionalProperties": false,
    ]

    /// Longest text kept for any field of a rewrite.
    static let maxFieldLength = 600

    /// Decodes a rewrite onto the version it rewrites: text is cleaned (links removed, length capped); the review
    /// fields are left for the devil's advocate to fill.
    /// - Throws: `SummarizerError.badResponse` if the pitch or buyer is empty, or decoding errors.
    static func parseRewrite(_ data: Data, from v: IdeaVersion) throws -> IdeaVersion {
        struct Out: Decodable { let pitch, buyer, pricing, replaces, channel, why_now, one_week_test, changes: String }
        let out = try JSONDecoder().decode(Out.self, from: try LLMSummarizer.extractJSON(data))
        let clean = { StarterKit.clean($0, maxFieldLength) }
        var r = v
        r.pitch = clean(out.pitch); r.buyer = clean(out.buyer); r.pricing = clean(out.pricing)
        r.replaces = clean(out.replaces); r.channel = clean(out.channel); r.whyNow = clean(out.why_now)
        r.oneWeekTest = clean(out.one_week_test); r.changes = clean(out.changes)
        guard !r.pitch.isEmpty, !r.buyer.isEmpty else { throw SummarizerError.badResponse("the rewritten idea was empty") }
        return r
    }
}
