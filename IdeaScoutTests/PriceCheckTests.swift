// PriceCheckTests.swift
// The web price check's rules: a price counts as confirmed only with a link the search returned; checked prices
// replace remembered ones; the search request and reply handling; and the refresh estimate. No network.

import Foundation
import Testing
@testable import IdeaScout

struct PriceCheckTests {
    private func formatted(_ competitors: String) -> Data {
        // Safe in a test: a fixed, valid object.
        try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": #"{"competitors":["# + competitors + "]}"]],
                                                     "stop_reason": "end_turn"])
    }

    /// Security and honesty: invented links, non-web links and unpriced paid plans are dropped.
    @Test func onlyPricesWithAReturnedLinkCount() throws {
        let data = formatted("""
        {"name":"Real","cheapest_plan":"Solo","price_per_month_usd":12,"is_free":false,"url":"https://real.example/pricing/"},
        {"name":"Invented","cheapest_plan":"Pro","price_per_month_usd":9,"is_free":false,"url":"https://made-up.example"},
        {"name":"Script","cheapest_plan":"x","price_per_month_usd":5,"is_free":false,"url":"javascript:alert(1)"},
        {"name":"Unpriced","cheapest_plan":"?","price_per_month_usd":0,"is_free":false,"url":"https://real.example/other"},
        {"name":"Freebie","cheapest_plan":"Free","price_per_month_usd":0,"is_free":true,"url":"https://free.example"}
        """)
        let sources: Set<String> = ["https://real.example/pricing", "https://real.example/other", "https://free.example/", "javascript:alert(1)"]
        let kept = try PriceCheck.parse(data, sources: sources)
        #expect(kept.map(\.name) == ["Real", "Freebie"])
        #expect(kept.allSatisfy(\.confirmed) && kept.first?.monthlyPrice == 12)
    }

    @Test func checkedPricesReplaceRememberedOnes() {
        let remembered = [Competitor(name: "Chaser", plan: "", monthlyPrice: 30), Competitor(name: "Other", plan: "", monthlyPrice: 8)]
        let checked = [Competitor(name: "chaser", plan: "Starter", monthlyPrice: 40, url: "https://c.example", confirmed: true)]
        let merged = PriceCheck.merge(existing: remembered, checked: checked)
        #expect(merged.map(\.name) == ["chaser", "Other"] && merged.first?.confirmed == true)
    }

    /// The request uses the basic web search tool, capped, with no structured output or fallback.
    @Test func searchRequestShape() throws {
        let body = ClaudeClient.searchBody(system: "s", messages: [["role": "user", "content": "p"]], maxSearches: 3,
                                           model: ScanStep.reading.mixedModelID)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.first?["type"] as? String == "web_search_20250305" && tools.first?["max_uses"] as? Int == 3)
        #expect(body["output_config"] == nil && body["fallbacks"] == nil && body["model"] as? String == "claude-haiku-5-5")
    }

    /// Reply shape from Anthropic's web search docs: text with citations, a result list, an error result, usage.
    @Test func searchReplyCollectsSourcesAndSearches() throws {
        let reply = """
        {"content":[{"type":"text","text":"I'll search."},
          {"type":"server_tool_use","id":"s1","name":"web_search","input":{"query":"invoice app price"}},
          {"type":"web_search_tool_result","tool_use_id":"s1","content":[{"type":"web_search_result","url":"https://a.example/pricing","title":"A","encrypted_content":"x"}]},
          {"type":"web_search_tool_result","tool_use_id":"s2","content":{"type":"web_search_tool_result_error","error_code":"max_uses_exceeded"}},
          {"type":"text","text":"A costs $9.","citations":[{"type":"web_search_result_location","url":"https://b.example","title":"B","cited_text":"$9"}]}],
         "stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":20,"server_tool_use":{"web_search_requests":2}}}
        """
        let parsed = try ClaudeClient.parseSearchReply(Data(reply.utf8))
        #expect(parsed.text == "I'll search.A costs $9." && !parsed.paused && parsed.searches == 2)
        #expect(parsed.sources == ["https://a.example/pricing", "https://b.example"])
        #expect(try ClaudeClient.parseSearchReply(Data(#"{"content":[],"stop_reason":"pause_turn"}"#.utf8)).paused)
        #expect(throws: SummarizerError.self) { try ClaudeClient.parseSearchReply(Data(#"{"content":[],"stop_reason":"refusal"}"#.utf8)) }
    }

    /// Money: the refresh estimate includes the price check when it runs.
    @Test func refreshEstimateIncludesThePriceCheck() {
        let price = ModelPrice(input: 2, output: 10)
        let without = AppSettings.estimatedRefreshCost(items: 300, price: price)
        let with = AppSettings.estimatedRefreshCost(items: 300, price: price, priceCheck: true)
        #expect(abs(with.upperBound - without.upperBound - PriceCheck.estimatedCostPerScan) < 0.0001)
    }
}
