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
}
