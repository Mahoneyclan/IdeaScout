// IdeaImprover.swift
// "Improve this idea": rounds in which the AI rewrites an idea to answer the devil's advocate's objection, then the
// devil's advocate scores the rewrite. Before round 1 the same devil's advocate re-scores the original, so every round
// is compared with a score marked the same way; "Improve again" adds rounds to the last run (owner, 13 Nov 2026). Holds the rewrite instructions, schema and
// parser, the evidence cap and the stopping rules. The service in DigestService+Improve.swift makes the paid calls.

import Foundation

/// The rules of an improvement run. Testable without the network: the paid steps are passed in.
enum IdeaImprover {
    /// At most this many rounds (each is two paid calls: a rewrite and a review), after one review re-scoring the original.
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
            case .maxRounds: "Stopped after \(IdeaImprover.maxRounds) rounds, the most in one go. Improve again to carry on."
            }
        }
    }

    /// A run so far: the original first, then one version per finished round; "Improve again" adds rounds to it.
    struct Run: Codable, Equatable, Sendable {
        var versions: [IdeaVersion]
        var stop: Stop?
        var madeAt = Date.now
        var model = ""
        /// The original's score from the daily scan, before the re-score; `nil` for runs saved before re-scoring.
        var scanScore: Double?
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
    ///   - original: The score this run started from; the bar only stops a run that started below it.
    ///   - round: The round just finished in this run (1-based).
    ///   - bar: The user's quality bar.
    static func stop(after latest: IdeaVersion, best: Double, original: Double, round: Int, bar: Double) -> Stop? {
        if !latest.passes || !latest.survives { return .rejected }
        if latest.score <= best { return .noBetter }
        if original < bar && latest.score >= bar { return .reachedBar }
        return round >= maxRounds ? .maxRounds : nil
    }

    /// Where "Improve again" carries on from: the kept round if one is in use; while the original is in use, the
    /// best-scoring version so far (the later on a tie). `nil` when nothing in the run is in use (a version kept from
    /// a run saved before rounds carried on), so a new run starts from the idea as it stands.
    /// - Parameters:
    ///   - run: The last run.
    ///   - inUse: Whether a version is the one in use, given its index.
    /// - Returns: The index to continue from, or `nil`.
    static func continueIndex(_ run: Run, inUse: (IdeaVersion, Int) -> Bool) -> Int? {
        guard !run.versions.isEmpty else { return nil }
        if let kept = run.versions.indices.dropFirst().first(where: { inUse(run.versions[$0], $0) }) { return kept }
        guard inUse(run.versions[0], 0) else { return nil }
        var best = 0
        for index in run.versions.indices where run.versions[index].score >= run.versions[best].score { best = index }
        return best
    }

    /// Runs rounds until a stop rule is met. Each finished round is reported through `onRound` before the next
    /// starts, so a failure part-way keeps the versions already made.
    /// - Parameters:
    ///   - original: The idea before any kept improvement; caps the evidence scores and, on a new run, is re-scored.
    ///   - previous: The last run and the index to continue from ("Improve again"); its rounds stay and new ones
    ///     are numbered after them, with no re-score. `nil` starts a new run.
    ///   - bar: The quality bar.
    ///   - beforeCall: Called before every paid call; throws to stop (for example over the daily limit).
    ///   - rewrite: Rewrites a version to answer its objection (paid), with its round.
    ///   - review: The devil's advocate's review of a version (paid), with its round; round 0 re-scores the original.
    ///   - onRound: The run after each round.
    /// - Returns: The finished run.
    @MainActor static func run(from original: IdeaVersion, continuing previous: (run: Run, from: Int)? = nil, bar: Double,
                    beforeCall: () throws -> Void,
                    rewrite: (IdeaVersion, Int) async throws -> IdeaVersion,
                    review: (IdeaVersion, Int) async throws -> KillerEngine.Review,
                    onRound: (Run) -> Void) async throws -> Run {
        var run: Run
        if let previous, previous.run.versions.indices.contains(previous.from) {
            run = previous.run
            run.stop = nil
            run.madeAt = .now
        } else {
            // The daily scan marked the original with the full evidence among that day's ideas, a different setting
            // from the rounds' reviews; re-scoring it makes "did the round raise the score?" a like-for-like question.
            try beforeCall()
            let rescored = original.reviewed(by: capped(try await review(original, 0), original: original))
            run = Run(versions: [rescored], scanScore: original.score)
        }
        var current = run.versions[previous?.from ?? 0]
        let start = current.score, first = run.versions.count
        for step in 1...maxRounds {
            let round = first + step - 1
            try beforeCall()
            let rewritten = try await rewrite(current, round)
            try beforeCall()
            let latest = rewritten.reviewed(by: capped(try await review(rewritten, round), original: original))
            let best = run.versions.map(\.score).max() ?? start
            run.versions.append(latest)
            run.stop = stop(after: latest, best: best, original: start, round: step, bar: bar)
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
    change the price or pricing model, pick a better sales channel, cut scope so one person can build all of it with their tool, \
    or sharpen the one-week test. Keep it the same product solving the same buyer problem: don't swap in a \
    different idea. Someone must still pay for it. Don't invent evidence, customers, numbers or competitors' \
    prices; if the objection can only be answered by evidence you don't have, make the one-week test collect it.
    Aim at the principles: vibe-codable by one person with their tool (a must), people will pay, real pain, and \
    likely sales from a small number of customers covering the build cost. The price must be at most a quarter \
    (25%) of the cheapest competitor's comparable plan; a higher price is lowered to that in code. Doing the one \
    job people need with fewer features often helps.
    Give: pitch (one sentence); buyer (a specific role in a specific type of business, or a specific type of \
    consumer); pricing (model and price per customer, per month or one-off); replaces (the manual task or \
    workaround it replaces); channel (the named place where the first 100 buyers would be found); why_now; \
    one_week_test (the cheapest way to check demand in 7 days, with a pass mark); one_job (the one job it does); \
    keep_features and leave_out_features (2 to 6 each, compared with the competitors); price_per_month_usd (the \
    recommended price per customer per month in US dollars, a one-off price divided by 12); changes (one or two \
    sentences: what you changed and how it answers the objection). Write everything in English.
    """ + Prompts.untrustedData

    /// The rewrite prompt: the idea, its review and its evidence titles.
    static func rewritePrompt(_ v: IdeaVersion, title: String, evidence: [String], aboutMe: String,
                              tool: BuilderTool = .claudeCode, appType: BuilderTool.AppType? = nil) -> String {
        var text = "About me: " + (aboutMe.isEmpty ? "(not provided)" : aboutMe)
        text += "\nBuilder's tool: \(tool.label). The idea must stay \(tool.forAI(appType)).\n\n"
        text += ideaText(v, title: title, evidence: evidence)
        text += "\n\nDevil's advocate:\nStrongest objection: \(v.objection)\nCompetitors: \(v.competitors)\nVerdict: \(v.verdict)"
        if !v.evidenceNeeded.isEmpty { text += "\nEvidence that would raise the score: \(v.evidenceNeeded)" }
        return text
    }

    /// The review prompt, in the daily scan's shape so the devil's advocate judges it the same way. Only the new
    /// version is shown, not the earlier rounds.
    static func reviewPrompt(_ v: IdeaVersion, title: String, evidence: [String], aboutMe: String,
                             tool: BuilderTool = .claudeCode, appType: BuilderTool.AppType? = nil) -> String {
        "About me: " + (aboutMe.isEmpty ? "(not provided)" : aboutMe)
            + "\nBuilder's tool: \(tool.label). Each idea must be \(tool.forAI(appType)).\n\nIdeas:\n\n"
            + ideaText(v, title: title, evidence: evidence)
    }

    private static func ideaText(_ v: IdeaVersion, title: String, evidence: [String]) -> String {
        var text = "Title: \(title)\nPitch: \(v.pitch)\nBuyer: \(v.buyer)\nPricing: \(v.pricing)"
        if !v.replaces.isEmpty { text += "\nReplaces: \(v.replaces)" }
        if !v.channel.isEmpty { text += "\nSales channel: \(v.channel)" }
        text += "\nWhy now: \(v.whyNow)\nOne-week test: \(v.oneWeekTest)"
        if let o = v.offer {
            text += KillerEngine.offerText(oneJob: o.oneJob, keep: o.keepFeatures, leaveOut: o.leaveOutFeatures,
                                           price: o.monthlyPrice, competitors: o.competitors, fillsGap: o.fillsGap,
                                           salesModel: o.salesPlan?.model)
        }
        text += "\nEvidence:" + (evidence.isEmpty ? " (none cited)" : "")
        for item in evidence { text += "\n- \(item)" }
        return text
    }

    static let rewriteFields = ["pitch", "buyer", "pricing", "replaces", "channel", "why_now", "one_week_test", "one_job",
                                "keep_features", "leave_out_features", "price_per_month_usd", "changes"]

    /// JSON Schema for the rewrite. Keep in sync with `parseRewrite` and the instructions.
    static let rewriteSchema: [String: Any] = [
        "type": "object",
        "properties": Dictionary(uniqueKeysWithValues: rewriteFields.map { field -> (String, Any) in
            switch field {
            case "keep_features", "leave_out_features": (field, ["type": "array", "items": ["type": "string"]] as [String: Any])
            case "price_per_month_usd": (field, ["type": "number"] as [String: Any])
            default: (field, ["type": "string"] as [String: Any])
            }
        }),
        "required": rewriteFields,
        "additionalProperties": false,
    ]

    /// Longest text kept for any field of a rewrite.
    static let maxFieldLength = 600

    /// Decodes a rewrite onto the version it rewrites: text is cleaned (links removed, length capped); the review
    /// fields are left for the devil's advocate to fill.
    /// - Throws: `SummarizerError.badResponse` if the pitch or buyer is empty, or decoding errors.
    static func parseRewrite(_ data: Data, from v: IdeaVersion) throws -> IdeaVersion {
        struct Out: Decodable {
            let pitch, buyer, pricing, replaces, channel, why_now, one_week_test, changes: String
            let one_job: String?
            let keep_features, leave_out_features: [String]?
            let price_per_month_usd: Double?
        }
        let out = try JSONDecoder().decode(Out.self, from: try LLMSummarizer.extractJSON(data))
        let clean = { StarterKit.clean($0, maxFieldLength) }
        var r = v
        r.pitch = clean(out.pitch); r.buyer = clean(out.buyer); r.pricing = clean(out.pricing)
        r.replaces = clean(out.replaces); r.channel = clean(out.channel); r.whyNow = clean(out.why_now)
        r.oneWeekTest = clean(out.one_week_test); r.changes = clean(out.changes)
        if var offer = r.offer {
            if let job = out.one_job.map(clean), !job.isEmpty { offer.oneJob = job }
            if let keep = out.keep_features { offer.keepFeatures = KillerEngine.cleanList(keep) }
            if let leave = out.leave_out_features { offer.leaveOutFeatures = KillerEngine.cleanList(leave) }
            let price = KillerEngine.cleanPrice(out.price_per_month_usd)
            if price > 0 { offer.monthlyPrice = price }
            // The 25% cap (owner, 16 Nov 2026) applies to a rewrite's price too.
            offer.monthlyPrice = FiveTests.capped(offer.monthlyPrice, competitors: offer.competitors)
            r.offer = offer
        }
        guard !r.pitch.isEmpty, !r.buyer.isEmpty else { throw SummarizerError.badResponse("the rewritten idea was empty") }
        return r
    }
}
