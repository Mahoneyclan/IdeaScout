// TestSupport.swift
// Stand-ins shared by the unit tests: a minimal FetchedItem, a source that returns fixed items and an AI
// that replies from a script. None of them touch the network.

import Foundation
@testable import IdeaScout

/// Builds a minimal FetchedItem for tests.
func item(_ key: String, _ source: SourceKind = .github, score: Int = 0, url: String? = nil, title: String = "Title") -> FetchedItem {
    FetchedItem(key: key, source: source, title: title, detail: "", url: URL(string: url ?? "https://example.com/\(key)")!,
                score: score, postedAt: .now)
}

/// A source that returns fixed items.
struct StubFetcher: ItemFetcher {
    let kind: SourceKind
    let items: [FetchedItem]
    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] { items }
}

/// An AI that replies from a script, keyed by cost-tracker feature ("Trends", "Killer ideas", "Devil's advocate").
struct ScriptedLLM: LLMClient {
    let provider = AIProvider.claude
    let model = "test-model"
    var replies: [String: Result<String, LLMHTTPError>]

    func complete(system: String, prompt: String, schema: [String: Any], effort: String, feature: String) async throws -> Data {
        switch replies[feature] {
        case .success(let json)?:
            return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": json]], "stop_reason": "end_turn"])
        case .failure(let error)?: throw error
        case nil: throw SummarizerError.unavailable
        }
    }
}

/// A price checker that replies from a script: one search reply and one formatted reply for every idea.
struct ScriptedPriceChecker: WebSearchClient, LLMClient {
    let provider = AIProvider.claude
    let model = "test-haiku"
    var search: Result<WebSearchReply, LLMHTTPError>
    var formatted: String

    func searchWeb(system: String, prompt: String, maxSearches: Int, blockedDomains: [String],
                   feature: String) async throws -> WebSearchReply {
        try search.get()
    }

    func complete(system: String, prompt: String, schema: [String: Any], effort: String, feature: String) async throws -> Data {
        try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": formatted]], "stop_reason": "end_turn"])
    }
}
