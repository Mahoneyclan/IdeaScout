// IdeaImproverTests.swift
// "Improve this idea": the evidence cap, the stopping rules, the loop keeping finished rounds when a later one
// fails, the rewrite parser and schema, the cost estimate, and the service's rules (blocked before any paid call,
// the idea unchanged until a version is kept, undo). Offline: the AI is scripted and the database is in memory.

import Foundation
import Testing
import SwiftData
@testable import IdeaScout

/// A version with every score set to `score` (pain and willingness to pay can be set separately).
private func version(_ score: Int, pain: Int? = nil, pay: Int? = nil, survives: Bool = true) -> IdeaVersion {
    IdeaVersion(pitch: "Chases invoices.", buyer: "Plumbers", pricing: "$29/month", whyNow: "w", oneWeekTest: "t",
                replaces: "Emails", channel: "Xero App Store", survives: survives, objection: "o", competitors: "c",
                verdict: "v", pain: pain ?? score, willingToPay: pay ?? score, timing: score, gap: score, fit: score,
                buildability: score, channelScore: score)
}

/// A devil's-advocate review with every score set to `score`.
private func review(_ score: Int, survives: Bool = true) -> KillerEngine.Review {
    KillerEngine.Review(title: "InvoiceChaser", survives: survives, objection: "new objection", competitors: "c",
                        verdict: "v2", pain: score, willingToPay: score, timing: score, gap: score, fit: score,
                        buildability: score, channelScore: score, evidenceNeeded: "e2")
}

private let rewriteJSON = #"{"pitch":"Chases invoices for plumbers. https://evil.example/x","buyer":"Plumbers","pricing":"$29","replaces":"Emails","channel":"Xero App Store","why_now":"w","one_week_test":"t","changes":"Narrowed."}"#
private let reviewJSON = #"{"reviews":[{"title":"InvoiceChaser","survives":true,"objection":"o2","competitors":"none found","verdict":"v2","pain":5,"willing_to_pay":5,"timing":4,"gap":4,"fit":4,"buildability":4,"channel_score":4,"evidence_needed":"e2"}]}"#

private func reply(_ json: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": json]], "stop_reason": "end_turn"])
}

struct IdeaImproverRuleTests {
    /// A rewrite adds no evidence, so pain and willingness to pay can't rise; other scores can.
    @Test func evidenceScoresCantRise() {
        let r = IdeaImprover.capped(review(5), original: version(3, pain: 2, pay: 4))
        #expect(r.pain == 2 && r.willingToPay == 4)
        #expect(r.gap == 5 && r.channelScore == 5)
        #expect(IdeaImprover.capped(review(1), original: version(3)).pain == 1, "a lower score stays lower")
    }

    @Test(arguments: [
        (version(4, survives: false), 3.0, 3.0, 1, 3.5, IdeaImprover.Stop.rejected),
        (version(4, pain: 1), 3.0, 3.0, 1, 3.5, .rejected),          // a weak spot fails like the daily scan
        (version(3), 3.0, 3.0, 1, 3.5, .noBetter),
        (version(4), 3.0, 3.0, 1, 3.5, .reachedBar),
        (version(4), 3.0, 3.0, 1, 4.5, nil),                          // better but below the bar: carry on
        (version(5), 4.0, 4.0, 1, 3.5, nil),                          // started above the bar: the bar doesn't stop it
        (version(5), 4.0, 3.0, IdeaImprover.maxRounds, 4.9, .reachedBar),
        (version(4), 3.0, 3.0, IdeaImprover.maxRounds, 4.5, .maxRounds),
    ])
    func stopRules(latest: IdeaVersion, best: Double, original: Double, round: Int, bar: Double, expected: IdeaImprover.Stop?) {
        #expect(IdeaImprover.stop(after: latest, best: best, original: original, round: round, bar: bar) == expected)
    }

    /// The original is re-scored first; rounds continue while the score rises, each starting from the last; a failing
    /// round keeps the earlier ones.
    @MainActor @Test func failedRoundKeepsEarlierRounds() async throws {
        var reviews = [review(3), review(4), review(5)]
        var rewrittenFrom: [String] = []
        var reviewed: [Int] = []
        var saved: IdeaImprover.Run?
        await #expect(throws: SummarizerError.self) {
            _ = try await IdeaImprover.run(
                from: version(3), bar: 6, beforeCall: {},   // a bar it can never reach
                rewrite: { v, _ in
                    rewrittenFrom.append(v.objection)
                    var r = v; r.pitch = "Round \(rewrittenFrom.count)"; return r
                },
                review: { _, round in
                    reviewed.append(round)
                    guard !reviews.isEmpty else { throw SummarizerError.unavailable }
                    return reviews.removeFirst()
                },
                onRound: { saved = $0 })
        }
        #expect(reviewed == [0, 1, 2, 3], "round 0 re-scores the original")
        #expect(rewrittenFrom == ["new objection", "new objection", "new objection"], "each round answers the latest objection")
        #expect(saved?.versions.map(\.pitch) == ["Chases invoices.", "Round 1", "Round 2"])
        #expect(saved?.stop == nil)
    }

    /// A round is judged against the re-scored original, not the daily scan's score: here the re-score is lower
    /// than the scan's, so a round between the two counts as better and the run carries on.
    @MainActor @Test func roundsAreComparedWithTheReScore() async throws {
        var reviews = [review(2), review(3), review(3)]
        let run = try await IdeaImprover.run(from: version(4), bar: 6, beforeCall: {},
                                             rewrite: { v, _ in v }, review: { _, _ in reviews.removeFirst() }, onRound: { _ in })
        #expect(run.scanScore == version(4).score)
        #expect(run.versions.count == 3, "round 1 beat the re-score; round 2 didn't beat round 1")
        #expect(run.stop == .noBetter)
    }

    /// "Improve again" adds rounds after the last ones, numbered on, with no second re-score, starting from the
    /// version it carries on from and comparing with that version's score.
    @MainActor @Test func improveAgainCarriesOn() async throws {
        let earlier = IdeaImprover.Run(versions: [version(3), version(4), version(2)], stop: .noBetter, scanScore: 3)
        var rounds: [Int] = [], startedFrom: [String] = []
        var reviews = [review(5), review(5)]
        let run = try await IdeaImprover.run(
            from: version(3), continuing: (run: earlier, from: 1), bar: 6, beforeCall: {},
            rewrite: { v, round in startedFrom.append(v.pitch); var r = v; r.pitch = "Round \(round)"; return r },
            review: { _, round in rounds.append(round); return reviews.removeFirst() }, onRound: { _ in })
        #expect(rounds == [3, 4], "no re-score; numbered after the earlier rounds")
        #expect(startedFrom == ["Chases invoices.", "Round 3"])
        #expect(run.versions.count == 5 && run.versions.prefix(3) == earlier.versions.prefix(3), "earlier rounds stay")
        #expect(run.stop == .noBetter && run.scanScore == 3)
    }

    /// Where "Improve again" carries on from: the kept round; else, while the original is in use, the best so far;
    /// else (a version kept from an older run) nowhere, so a new run starts.
    @Test func improveAgainStartsFromTheRightVersion() {
        let run = IdeaImprover.Run(versions: [version(3), version(4), version(4), version(2)], stop: .noBetter)
        #expect(IdeaImprover.continueIndex(run) { _, i in i == 3 } == 3)
        #expect(IdeaImprover.continueIndex(run) { _, i in i == 0 } == 2, "best so far, the later on a tie")
        #expect(IdeaImprover.continueIndex(run) { _, _ in false } == nil)
    }

    @MainActor @Test func overLimitStopsBeforeAnyCall() async {
        var calls = 0
        await #expect(throws: SummarizerError.self) {
            _ = try await IdeaImprover.run(from: version(3), bar: 4, beforeCall: { throw SummarizerError.overDailyLimit },
                                           rewrite: { v, _ in calls += 1; return v }, review: { _, _ in calls += 1; return review(4) },
                                           onRound: { _ in })
        }
        #expect(calls == 0)
    }

    @Test func rewriteIsCleanedAndChecked() throws {
        let v = try IdeaImprover.parseRewrite(reply(rewriteJSON), from: version(3))
        #expect(v.pitch == "Chases invoices for plumbers.")
        #expect(v.changes == "Narrowed." && v.objection == "o", "review fields wait for the devil's advocate")
        #expect(throws: SummarizerError.self) {
            try IdeaImprover.parseRewrite(reply(rewriteJSON.replacingOccurrences(of: #""buyer":"Plumbers""#, with: #""buyer":" ""#)),
                                          from: version(3))
        }
    }

    /// Prompts and schemas move together.
    @Test func schemaAndInstructionsAgree() throws {
        let properties = try #require(IdeaImprover.rewriteSchema["properties"] as? [String: Any])
        #expect(Set(properties.keys) == Set(IdeaImprover.rewriteFields))
        for field in IdeaImprover.rewriteFields {
            #expect(IdeaImprover.rewriteInstructions.contains(field), "instructions should describe \(field)")
        }
    }

    @Test func costCoversEveryRound() {
        #expect(abs(AppSettings.estimatedImproveCost(price: ModelPrice(input: 4, output: 20)) - 0.392) < 0.0001, "three rounds and the re-score")
    }
}

/// Improving through the service, with stand-ins for the AI and spending limit.
@MainActor
struct ImproveServiceTests {
    enum Block: CaseIterable { case noCloudAI, overLimit }

    private func setUp(llm: ScriptedLLM?, overCap: Bool = false) throws -> (DigestService, KillerIdea) {
        let container = try ModelContainer(for: Digest.self, Theme.self, Item.self, Idea.self, KillerIdea.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let service = DigestService(dependencies: .init(
            makeFetchers: { [] },
            makeSummarizer: { llm.map { LLMSummarizer(client: $0) as any Summarizer } ?? KeywordSummarizer(topics: []) },
            freeSummarizer: { KeywordSummarizer(topics: []) },
            isOverDailyCap: { overCap }, needsConsent: { false }, notify: { _, _ in }))
        service.container = container
        let idea = KillerIdea(key: "invoicechaser", title: "InvoiceChaser")
        version(3).apply(to: idea)
        idea.verdict = "v Evidence that would raise the score: invoices paid late"
        container.mainContext.insert(idea)
        return (service, idea)
    }

    /// The run is saved for the screen, but the idea's own text and scores don't change until a version is kept.
    @Test func runIsSavedButIdeaIsUnchanged() async throws {
        let (service, idea) = try setUp(llm: ScriptedLLM(replies: ["Improve idea": .success(rewriteJSON),
                                                                   "Improve idea: devil's advocate": .success(reviewJSON)]))
        try await service.improve(idea)
        let run = try #require(idea.improvement)
        #expect(run.versions.count >= 2 && run.model == "test-model")
        #expect(run.versions[0].evidenceNeeded == "e2" && run.scanScore == version(3).score, "the original was re-scored")
        #expect(run.versions[0].pain == 3 && run.versions[1].pain == 3, "pain capped at the original's")
        #expect(idea.pitch == "Chases invoices." && idea.pain == 3)
        #expect(service.improvingIdea == nil)
    }

    @Test(arguments: Block.allCases)
    func blockedBeforeAnyPaidCall(block: Block) async throws {
        let expected: Error = switch block {
        case .noCloudAI: ImproveError.needsCloudAI
        case .overLimit: SummarizerError.overDailyLimit
        }
        // The scripted AI has no replies, so reaching it would throw a different error.
        let (service, idea) = try setUp(llm: block == .noCloudAI ? nil : ScriptedLLM(replies: [:]),
                                        overCap: block == .overLimit)
        await #expect { try await service.improve(idea) } throws: { $0.localizedDescription == expected.localizedDescription }
        #expect(idea.improvement == nil && service.improvingIdea == nil)
    }

    @Test func secondRunWhileOneIsGoingIsRefused() async throws {
        let (service, idea) = try setUp(llm: ScriptedLLM(replies: [:]))
        service.improvingIdea = "another idea"
        await #expect(throws: ImproveError.busy) { try await service.improve(idea) }
    }

    /// Keeping twice and undoing once puts back the very first version.
    @Test func keepThenUndoRestoresTheOriginal() throws {
        let (service, idea) = try setUp(llm: nil)
        let original = IdeaVersion(idea)
        service.keep(version(4).reviewed(by: review(4)), for: idea)
        service.keep(version(5).reviewed(by: review(5)), for: idea)
        #expect(idea.killerScore == 5 && idea.improvedAt != nil)
        #expect(idea.verdict == "v2 Evidence that would raise the score: e2")
        service.undoImprovement(of: idea)
        #expect(IdeaVersion(idea) == original)
        #expect(idea.improvedAt == nil && idea.originalVersion == nil)
    }
}
