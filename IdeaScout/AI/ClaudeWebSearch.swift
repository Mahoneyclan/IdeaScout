// ClaudeWebSearch.swift
// Claude's web search tool, for the web price check: one non-streamed request with the basic web search tool
// (`web_search_20250305`: no code execution, simplest reply), continued if the API pauses a long turn. Records each
// reply's tokens and searches ($10 per 1,000) in the cost tracker. Split from LLMSummarizer.swift for size.

import Foundation

extension ClaudeClient: WebSearchClient {
    /// Most times a paused search turn is continued.
    static let maxContinuations = 3
    /// Room for the reply. Haiku thinks by default and its thinking counts towards this; at 4,000 a search with
    /// several pages of results could use it all before writing the answer (seen 13 Nov 2026: "gave no answer").
    static let searchMaxTokens = 16_000

    /// See `WebSearchClient.searchWeb`.
    /// - Throws: `LLMHTTPError`, `SummarizerError.refused` or `.badResponse`, network errors or `CancellationError`.
    func searchWeb(system: String, prompt: String, maxSearches: Int, blockedDomains: [String],
                   feature: String) async throws -> WebSearchReply {
        var messages: [[String: Any]] = [["role": "user", "content": prompt]]
        var found = WebSearchReply(text: "", sources: [])
        var lastStop: String?
        for _ in 0...Self.maxContinuations {
            let payload = try JSONSerialization.data(withJSONObject: Self.searchBody(
                system: system, messages: messages, maxSearches: maxSearches, blockedDomains: blockedDomains, model: model))
            let data = try await LLMRetry.run { try await sendSearch(payload, feature: feature) }
            let reply = try Self.parseSearchReply(data)
            found.text += reply.text
            found.sources.formUnion(reply.sources)
            lastStop = reply.stopReason
            guard reply.paused, let content = reply.content else { break }
            // Security: the paused reply is sent back unchanged, as the API requires; nothing in it is run here.
            messages.append(["role": "assistant", "content": content])
        }
        guard !found.text.isEmpty else { throw SummarizerError.badResponse(Self.noAnswerReason(lastStop)) }
        return found
    }

    /// Why a search ended without an answer, for the error's wording.
    static func noAnswerReason(_ stop: String?) -> String {
        switch stop {
        case "max_tokens": "the web search ran out of room before answering"
        case "pause_turn": "the web search took too many steps and stopped before answering"
        default: "the web search gave no answer (it stopped with \"\(stop ?? "no reason")\")"
        }
    }

    /// The request: the web search tool limited to `maxSearches` and kept off `blockedDomains`, low effort (finding
    /// and reporting pages needs little thinking, and thinking uses the reply's room), no structured output (the
    /// formatting is a separate call), no server-side fallback (Haiku has none).
    static func searchBody(system: String, messages: [[String: Any]], maxSearches: Int, blockedDomains: [String] = [],
                           model: String) -> [String: Any] {
        var tool: [String: Any] = ["type": "web_search_20250305", "name": "web_search", "max_uses": maxSearches]
        if !blockedDomains.isEmpty { tool["blocked_domains"] = blockedDomains }
        return [
            "model": model,
            "max_tokens": searchMaxTokens,
            "output_config": ["effort": "low"],
            "system": system,
            "messages": messages,
            "tools": [tool],
        ]
    }

    /// What one reply holds.
    struct SearchReply {
        /// The answer's text blocks, joined.
        var text: String
        /// Links of returned pages and citations.
        var sources: Set<String>
        /// The API paused the turn; send `content` back to continue.
        var paused: Bool
        /// The reply's content blocks, for continuing a paused turn.
        var content: [Any]?
        /// Searches billed for this reply.
        var searches: Int
        /// Why the reply ended ("end_turn", "max_tokens", "pause_turn"…).
        var stopReason: String?
    }

    /// Reads a web search reply: text, every returned or cited link, whether it paused, and the searches billed.
    /// - Parameter data: The reply.
    /// - Throws: `SummarizerError.refused` if Claude declined; `.badResponse` if it isn't a reply.
    static func parseSearchReply(_ data: Data) throws -> SearchReply {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw SummarizerError.badResponse("the web search reply couldn't be read")
        }
        let stop = json["stop_reason"] as? String
        if stop == "refusal" { throw SummarizerError.refused }
        var text = "", sources = Set<String>()
        for block in content {
            switch block["type"] as? String {
            case "text":
                text += block["text"] as? String ?? ""
                for citation in block["citations"] as? [[String: Any]] ?? [] {
                    if let url = citation["url"] as? String { sources.insert(url) }
                }
            case "web_search_tool_result":
                // On an error the content is one error object, not a list; it then adds no sources.
                for result in block["content"] as? [[String: Any]] ?? [] {
                    if let url = result["url"] as? String { sources.insert(url) }
                }
            default: break
            }
        }
        let usage = json["usage"] as? [String: Any]
        let searches = (usage?["server_tool_use"] as? [String: Any])?["web_search_requests"] as? Int ?? 0
        return SearchReply(text: text, sources: sources, paused: stop == "pause_turn", content: content, searches: searches,
                           stopReason: stop)
    }

    /// One attempt; records tokens and searches.
    private func sendSearch(_ payload: Data, feature: String) async throws -> Data {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = payload
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LLMHTTPError(provider: provider.shortName, status: http.statusCode,
                               retryAfter: http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init),
                               detail: String(decoding: data.prefix(300), as: UTF8.self))
        }
        let searches = (try? Self.parseSearchReply(data).searches) ?? 0
        UsageTracker.record(response: data, feature: feature, price: price,
                            extraDollars: Double(searches) * PriceCheck.pricePerSearch)
        return data
    }
}
