import Foundation

/// Calls the Claude Messages API directly with URLSession (there is no official Swift SDK).
/// The API key comes from the Keychain and is never stored in source.
struct ClaudeSummarizer: Summarizer {
    let name = "Claude"
    var maxItems: Int { AppSettings.claudeMaxItems }
    let apiKey: String

    static let model = "claude-opus-5-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func themes(for items: [FetchedItem]) async throws -> [ThemeDraft] {
        try await themesWithTranslations(for: items).0
    }

    static let translationInstruction = "\nSome projects are not in English. For every project whose title or description "
        + "is not in English, add an entry to translations with its number and an English title and description. "
        + "Leave English projects out of translations."

    func themesWithTranslations(for items: [FetchedItem]) async throws -> ([ThemeDraft], [Int: Translation]) {
        let prompt = "Window: the last \(AppSettings.trendWindowDays) days (pain points: \(AppSettings.painWindowDays) days).\n\n"
            + "Projects:\n" + Prompts.itemList(items, detailLimit: 200)
        let data = try await send(Self.requestBody(system: Prompts.themeInstructions + Self.translationInstruction,
                                                   prompt: prompt, schema: Self.themeSchema),
                                  feature: "Trends")
        return (try Self.parseThemes(data), try Self.parseTranslations(data))
    }

    func extensions(for idea: IdeaBrief) async throws -> [String] {
        let data = try await send(Self.requestBody(system: Prompts.extensionInstructions,
                                                   prompt: Prompts.ideaText(idea), schema: Self.extensionSchema),
                                  feature: "Variant suggestions")
        struct Out: Decodable { let suggestions: [String] }
        return try JSONDecoder().decode(Out.self, from: try Self.extractJSON(data)).suggestions
    }

    /// Sends a request and records its token cost under `feature` in the usage tracker.
    /// The reply is streamed (long requests are less likely to time out) and a dropped connection,
    /// timeout or busy server is retried up to twice before giving up.
    func send(_ body: [String: Any], feature: String) async throws -> Data {
        var streamed = body
        streamed["stream"] = true
        let payload = try JSONSerialization.data(withJSONObject: streamed)
        var attempt = 0
        while true {
            do {
                return try await sendOnce(payload, feature: feature)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                guard attempt < Self.retryDelays.count, Self.isRetryable(error) else { throw error }
                let wait = Self.retryDelay(attempt: attempt, retryAfter: (error as? ClaudeHTTPError)?.retryAfter)
                attempt += 1
                try await Task.sleep(for: .seconds(wait))
            }
        }
    }

    private func sendOnce(_ payload: Data, feature: String) async throws -> Data {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // Lets the API retry a declined request on a suitable fallback model.
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = payload
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var body = Data()
            for try await byte in bytes { body.append(byte); if body.count > 2000 { break } }
            throw ClaudeHTTPError(status: http.statusCode,
                                  retryAfter: http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init),
                                  detail: String(decoding: body.prefix(300), as: UTF8.self))
        }
        var stream = StreamAssembler()
        do {
            for try await line in bytes.lines { try stream.consume(line) }
        } catch {
            // Input tokens are billed even if the reply is lost part-way, so record what we know.
            if let partial = stream.usageOnlyResponse() { UsageTracker.record(response: partial, feature: feature) }
            throw error
        }
        let data = try stream.response()
        UsageTracker.record(response: data, feature: feature)
        return data
    }

    // MARK: - Retries (static so they can be unit tested)

    static let retryDelays: [Double] = [3, 15]

    /// Only temporary problems are retried; a bad key or a malformed request fails straight away.
    static func isRetryable(_ error: Error) -> Bool {
        if let http = error as? ClaudeHTTPError { return [408, 429, 529].contains(http.status) || (500...599).contains(http.status) }
        if error is StreamAssembler.StreamError { return true }
        if let url = error as? URLError {
            return [.networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed].contains(url.code)
        }
        return false
    }

    /// The server's retry-after if it gave one (capped at 30 s), otherwise 3 s then 15 s, with a little jitter.
    static func retryDelay(attempt: Int, retryAfter: Double?, jitter: Double = Double.random(in: 0...1)) -> Double {
        if let retryAfter { return min(max(retryAfter, 1), 30) }
        return retryDelays[min(attempt, retryDelays.count - 1)] + jitter
    }

    // MARK: - Request / response shapes (static so they can be unit tested)

    static func requestBody(system: String, prompt: String, schema: [String: Any], effort: String = "medium") -> [String: Any] {
        [
            "model": model,
            "max_tokens": 32000,
            "system": system,
            "fallbacks": "default",
            "output_config": [
                "effort": effort,
                "format": ["type": "json_schema", "schema": schema],
            ],
            "messages": [["role": "user", "content": prompt]],
        ]
    }

    static let themeSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "themes": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "summary": ["type": "string"],
                        "opportunities": ["type": "array", "items": ["type": "string"]],
                        "item_numbers": ["type": "array", "items": ["type": "integer"]],
                        "novelty": ["type": "integer"],
                        "novelty_reason": ["type": "string"],
                        "viability": ["type": "integer"],
                        "viability_reason": ["type": "string"],
                        "opportunity_gap": ["type": "integer"],
                        "opportunity_gap_reason": ["type": "string"],
                    ],
                    "required": ["title", "summary", "opportunities", "item_numbers", "novelty", "novelty_reason",
                                 "viability", "viability_reason", "opportunity_gap", "opportunity_gap_reason"],
                    "additionalProperties": false,
                ],
            ],
            "translations": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "number": ["type": "integer"], "title": ["type": "string"], "description": ["type": "string"],
                    ],
                    "required": ["number", "title", "description"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["themes", "translations"],
        "additionalProperties": false,
    ]

    static let extensionSchema: [String: Any] = [
        "type": "object",
        "properties": ["suggestions": ["type": "array", "items": ["type": "string"]]],
        "required": ["suggestions"],
        "additionalProperties": false,
    ]

    /// Returns the JSON text Claude produced, after checking it wasn't refused or cut off.
    static func extractJSON(_ data: Data) throws -> Data {
        struct Response: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]
            let stop_reason: String?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        if response.stop_reason == "refusal" { throw SummarizerError.refused }
        if response.stop_reason == "max_tokens" { throw SummarizerError.badResponse("reply was cut off") }
        guard let text = response.content.first(where: { $0.type == "text" })?.text else {
            throw SummarizerError.badResponse("no text in reply")
        }
        return Data(text.utf8)
    }

    static func parseTranslations(_ data: Data) throws -> [Int: Translation] {
        struct Out: Decodable {
            struct T: Decodable { let number: Int; let title: String; let description: String }
            let translations: [T]?
        }
        let out = try JSONDecoder().decode(Out.self, from: try extractJSON(data))
        return Dictionary((out.translations ?? []).map { ($0.number, Translation(title: $0.title, detail: $0.description)) },
                          uniquingKeysWith: { first, _ in first })
    }

    static func parseThemes(_ data: Data) throws -> [ThemeDraft] {
        struct Out: Decodable {
            struct T: Decodable {
                let title: String; let summary: String; let opportunities: [String]; let item_numbers: [Int]
                let novelty: Int; let novelty_reason: String
                let viability: Int; let viability_reason: String
                let opportunity_gap: Int; let opportunity_gap_reason: String
            }
            let themes: [T]
        }
        return try JSONDecoder().decode(Out.self, from: try extractJSON(data)).themes.map {
            ThemeDraft(title: $0.title, summary: $0.summary, opportunities: $0.opportunities, itemNumbers: $0.item_numbers,
                       novelty: $0.novelty, viability: $0.viability, gap: $0.opportunity_gap,
                       reasons: ScoreReasons(novelty: $0.novelty_reason, viability: $0.viability_reason, gap: $0.opportunity_gap_reason))
        }
    }
}

struct ClaudeHTTPError: LocalizedError, Equatable {
    let status: Int
    let retryAfter: Double?
    let detail: String

    var errorDescription: String? {
        switch status {
        case 401: "Claude rejected the API key (HTTP 401). Check it in Settings."
        case 429: "Claude is rate-limiting requests (HTTP 429)."
        case 529: "Claude is overloaded right now (HTTP 529)."
        default: "Claude returned HTTP \(status) \(detail)"
        }
    }
}

/// Rebuilds a normal (non-streamed) Messages API reply from server-sent events, so the existing
/// parsers and the cost tracker work unchanged. Text from every text block is joined (a mid-stream
/// model fallback can split the reply into several blocks); thinking and other blocks are skipped.
struct StreamAssembler {
    struct StreamError: LocalizedError {
        let message: String
        var errorDescription: String? { "Claude stream error: \(message)" }
    }

    private var blockTypes: [Int: String] = [:]
    private var texts: [Int: String] = [:]
    private(set) var stopReason: String?
    private var usage: [String: Int] = [:]
    private(set) var started = false
    private(set) var finished = false

    mutating func consume(_ line: String) throws {
        guard line.hasPrefix("data:") else { return }
        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = json.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        switch type {
        case "message_start":
            started = true
            mergeUsage((event["message"] as? [String: Any])?["usage"])
        case "content_block_start":
            if let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any] {
                blockTypes[index] = block["type"] as? String
                if let text = block["text"] as? String, !text.isEmpty { texts[index, default: ""] += text }
            }
        case "content_block_delta":
            if let index = event["index"] as? Int, let delta = event["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                texts[index, default: ""] += text
            }
        case "message_delta":
            if let reason = (event["delta"] as? [String: Any])?["stop_reason"] as? String { stopReason = reason }
            mergeUsage(event["usage"])
        case "message_stop":
            finished = true
        case "error":
            let error = event["error"] as? [String: Any]
            throw StreamError(message: (error?["message"] as? String) ?? (error?["type"] as? String) ?? "unknown")
        default:
            break
        }
    }

    /// Usage counts are cumulative, so keep the largest value seen for each.
    private mutating func mergeUsage(_ value: Any?) {
        guard let dict = value as? [String: Any] else { return }
        for (key, raw) in dict { if let n = raw as? Int { usage[key] = max(usage[key] ?? 0, n) } }
    }

    func response() throws -> Data {
        guard started, finished else { throw StreamError(message: "the reply ended early") }
        let text = blockTypes.keys.sorted().filter { blockTypes[$0] == "text" }.compactMap { texts[$0] }.joined()
        var object: [String: Any] = ["content": [["type": "text", "text": text]], "usage": usage]
        if let stopReason { object["stop_reason"] = stopReason }
        return try JSONSerialization.data(withJSONObject: object)
    }

    func usageOnlyResponse() -> Data? {
        guard started else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["usage": usage])
    }
}
