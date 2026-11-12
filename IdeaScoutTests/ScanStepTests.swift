// ScanStepTests.swift
// Claude's "Mixed" choice (owner, 13 Nov 2026): the model for each scan step, Haiku's long-prompt price, its
// request without server-side fallback, and the refresh estimate priced step by step.

import Foundation
import Testing
@testable import IdeaScout

struct ScanStepTests {
    @Test(arguments: [
        (ScanStep.reading, ScanStep.mixedModel, "claude-haiku-5-5"),
        (.writing, ScanStep.mixedModel, "claude-sonnet-5-5"),
        (.judging, ScanStep.mixedModel, "claude-opus-5-5"),
        (.reading, "claude-opus-5-5", "claude-opus-5-5"),   // a chosen model is used for every step
        (.judging, "claude-sonnet-5-5", "claude-sonnet-5-5"),
    ])
    func eachStepGetsItsModel(step: ScanStep, chosen: String, model: String) {
        #expect(step.model(chosen: chosen) == model)
    }

    /// Anthropic's price: $0.10 / $0.50 per million tokens up to 100,000 prompt tokens, 5× above.
    @Test func haikuCostsFiveTimesMoreForLongPrompts() throws {
        let haiku = try #require(AIProvider.claude.models.first { $0.id == "claude-haiku-5-5" }?.price)
        #expect(abs(haiku.cost(input: 100_000, output: 0) - 0.01) < 1e-9)
        #expect(abs(haiku.cost(input: 90_000, output: 1_000, cacheRead: 10_001) - (0.009 + 0.0005 + 0.00010001) * 5) < 1e-9,
                "cache reads count toward the prompt length")
        #expect(abs(AppSettings.price(for: .claude, model: "claude-sonnet-5-5").cost(input: 200_000, output: 0) - 0.4) < 1e-9,
                "other models have one price")
    }

    @Test func haikuRequestsDontAskForServerSideFallback() {
        let haiku = ClaudeClient.requestBody(system: "s", prompt: "p", schema: [:], model: "claude-haiku-5-5")
        #expect(haiku["fallbacks"] == nil)
        let opus = ClaudeClient.requestBody(system: "s", prompt: "p", schema: [:], model: "claude-opus-5-5")
        #expect(opus["fallbacks"] as? String == "default")
    }

    /// 300 items: reading at Haiku's price, the fixed share split between Sonnet and Opus. High end shown.
    @Test func mixedRefreshEstimateIsPricedStepByStep() {
        let sonnet = AppSettings.price(for: .claude, model: "claude-sonnet-5-5")
        let mixed = AppSettings.estimatedRefreshCost(items: 300, price: sonnet, mixed: true).upperBound
        #expect(abs(mixed - (300 * 0.00064 * 0.025 + 0.055 * 1.5) * 1.5) < 0.0001)
        #expect(mixed < AppSettings.estimatedRefreshCost(items: 300, price: sonnet).upperBound)
    }
}
