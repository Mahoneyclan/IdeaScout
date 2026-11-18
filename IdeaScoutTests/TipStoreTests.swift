// TipStoreTests.swift
// "Shout me a coffee" (owner, 17 Nov 2026): tips show smallest first with our names, the Support section hides
// when Apple supplies none, and each purchase outcome gets a plain message (a failure says nothing was charged).

import Foundation
import Testing
@testable import IdeaScout

/// A stand-in App Store.
private struct FakeShop: TipShop {
    var found: [Tip] = []
    var failLoad = false
    var outcome: Result<TipOutcome, URLError> = .success(.thanked)

    func tips(_ ids: [String]) async throws -> [Tip] {
        if failLoad { throw URLError(.notConnectedToInternet) }
        return found
    }
    func buy(_ id: String) async throws -> TipOutcome { try outcome.get() }
}

@MainActor
struct TipStoreTests {
    private static let apple = [Tip(id: "com.mahoney.IdeaScout.tip.large", name: "Big", price: "A$9.99"),
                                Tip(id: "com.mahoney.IdeaScout.tip.small", name: "Small", price: "A$1.99"),
                                Tip(id: "com.other.unknown", name: "?", price: "A$1")]

    @Test func tipsAreOrderedAndNamedAndUnknownOnesDropped() async {
        let store = TipStore(shop: FakeShop(found: Self.apple))
        await store.load()
        #expect(store.tips.map(\.name) == ["Small coffee", "Coffee and cake"])
        #expect(store.tips.map(\.price) == ["A$1.99", "A$9.99"], "Apple's localised prices are kept")
    }

    @Test func noTipsWhenTheStoreFails() async {
        let store = TipStore(shop: FakeShop(failLoad: true))
        await store.load()
        #expect(store.tips.isEmpty, "the Support section hides itself")
    }

    @Test(arguments: [(TipOutcome.thanked, "Thank you"), (.pending, "waiting for approval"), (.unverified, "couldn't confirm")])
    func eachOutcomeSaysWhatHappened(outcome: TipOutcome, words: String) async {
        let store = TipStore(shop: FakeShop(found: Self.apple, outcome: .success(outcome)))
        await store.load()
        await store.buy(store.tips[0])
        #expect(store.message?.contains(words) == true && store.details == nil && store.buying == nil)
    }

    @Test func cancellingSaysNothingAndAFailureSaysNotCharged() async {
        let cancelled = TipStore(shop: FakeShop(found: Self.apple, outcome: .success(.cancelled)))
        await cancelled.load()
        await cancelled.buy(cancelled.tips[0])
        #expect(cancelled.message == nil)
        let failed = TipStore(shop: FakeShop(found: Self.apple, outcome: .failure(URLError(.timedOut))))
        await failed.load()
        await failed.buy(failed.tips[0])
        #expect(failed.message?.contains("haven't been charged") == true && failed.details != nil)
    }
}
