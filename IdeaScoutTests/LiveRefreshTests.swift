// LiveRefreshTests.swift
// The step-by-step refresh results (owner, 16 Nov 2026): per-source counts and how each draft idea is marked once
// the devil's advocate has judged it.

import Foundation
import Testing
@testable import IdeaScout

struct LiveRefreshTests {
    private func item(_ key: String, _ source: SourceKind) -> FetchedItem {
        FetchedItem(key: key, source: source, title: key, detail: "", url: URL(string: "https://example.com/\(key)")!,
                    score: 0, postedAt: .now)
    }

    @Test func countsItemsPerSourceMostFirst() {
        let counts = LiveRefresh.counts([item("a", .appReviews), item("b", .painPoints), item("c", .appReviews)])
        #expect(counts == [.init(label: SourceKind.appReviews.label, count: 2), .init(label: SourceKind.painPoints.label, count: 1)])
    }

    @Test func draftsAreMarkedBackedRejectedOrDropped() {
        let drafts = ["Kept", "Rejected", "Dropped"].map { LiveRefresh.Draft(title: $0, pitch: "p", buyer: "b") }
        func result(_ title: String, survives: Bool) -> KillerEngine.Result {
            let candidate = KillerEngine.Candidate(title: title, pitch: "p", buyer: "b", pricing: "", whyNow: "", oneWeekTest: "",
                                                   evidenceNumbers: [], sameAs: "")
            let review = KillerEngine.Review(title: title, survives: survives, objection: "Too small a market.", competitors: "",
                                             verdict: "", pain: 3, willingToPay: 3, timing: 3, gap: 3, fit: 3,
                                             buildability: 4, channelScore: 4)
            return KillerEngine.Result(candidate: candidate, review: review)
        }
        let judged = LiveRefresh.judged(drafts, results: [result("kept", survives: true), result("Rejected", survives: false)])
        #expect(judged.map(\.status) == [.backed, .rejected("Too small a market."), .dropped])
    }

    /// Step lines in plain words, and a refresh that stops part-way says where.
    @Test func checklistLinesAndStops() {
        #expect(LiveRefresh.sourcesLine([.init(label: "A", count: 40), .init(label: "B", count: 2)]) == "42 items from 2 sources")
        #expect(LiveRefresh.trendsLine(complaints: 1, trends: 3, byKeyword: true).hasPrefix("1 complaint, 3 trends, grouped by keyword"))
        let drafts = ["A", "B", "C", "D"].map { LiveRefresh.Draft(title: $0, pitch: "", buyer: "") }
        #expect(LiveRefresh.ideasLine(drafts) == "4 ideas: A, B, C…" && LiveRefresh.ideasLine([]) == "No ideas came back")
        var judged = drafts
        judged[0].status = .backed; judged[1].status = .rejected("r"); judged[2].status = .dropped; judged[3].status = .backed
        #expect(LiveRefresh.verdictLine(judged) == "2 kept, 1 rejected, 1 dropped")

        var live = LiveRefresh(startedAt: .now)
        live.set(1, .done("x"))
        live.set(2, .running)
        live.finish()
        #expect(live.state(2) == .failed("stopped before it finished") && live.state(5) == .skipped("the refresh stopped early"))
        #expect(live.summary() == "Stopped at step 2: stopped before it finished")
        #expect(LiveRefresh.StepState.skipped("no ideas to check").line(running: "") == "Skipped: no ideas to check")
        #expect(DigestService.plainReason("Killer ideas skipped: daily spending limit reached.") == "daily spending limit reached")
    }
}
