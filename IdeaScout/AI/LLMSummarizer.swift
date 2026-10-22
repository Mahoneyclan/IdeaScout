import Foundation

/// A cloud AI that returns structured JSON. Every client returns its reply in the same shape
/// (a Claude-style message with `content`, `stop_reason` and `usage`), so the parsers and the
/// cost tracker work the same for every provider. API keys come from the Keychain, never from source.
protocol LLMClient: Sendable {
    var provider: AIProvider { get }
    var model: String { get }
    func complete(system: String, prompt: String, schema: [String: Any], effort: String, feature: String) async throws -> Data
}

/// Trends, pain clusters, translations and variant suggestions from whichever cloud AI is chosen.
struct LLMSummarizer: Summarizer {
    let client: any LLMClient
    var name: String { client.provider.shortName }
    var maxItems: Int { AppSettings.claudeMaxItems }

    func themes(for items: [FetchedItem]) async throws -> [ThemeDraft] {
        try await analyse(items).drafts
    }

    static let translationInstruction = "\nSome projects are not in English. For every project whose title or description "
        + "is not in English, add an entry to translations with its number and an English title and description. "
        + "Leave English projects out of translations."

    static let clusterInstruction = """

    Items are tagged Demand (complaints, requests, spending), Supply (things being built) or Timing (new startups \
    and capabilities). Build the themes above from Supply and Timing items. Separately, group Demand items into 3 to 6 \
    pain_clusters: each is one problem felt by one type of buyer. Give: title (the problem in the buyer's words), \
    buyer (a specific role and type of business), workaround (what they do today), pay_signals (any sign they pay or \
    would pay, e.g. prices mentioned, paid tools they're leaving, or "none seen"), summary (one sentence), and item \
    numbers. A cluster needs at least 2 items unless one item is from "My business challenges". Those are the user's own \
    observations from work: treat them as strong evidence. List in noise_numbers any items that are spam, \
    off-topic or useless as product evidence.
    """

    func analyse(_ items: [FetchedItem]) async throws -> Analysis {
        let prompt = "Window: the last \(AppSettings.trendWindowDays) days (pain points: \(AppSettings.painWindowDays) days).\n\n"
            + "Projects:\n" + Prompts.itemList(items, detailLimit: 200)
        let data = try await client.complete(system: Prompts.themeInstructions + Self.translationInstruction + Self.clusterInstruction,
                                             prompt: prompt, schema: Self.themeSchema, effort: "medium", feature: "Trends")
        return Analysis(drafts: try Self.parseThemes(data) + (try Self.parseClusters(data)),
                        translations: try Self.parseTranslations(data), noise: try Self.parseNoise(data))
    }

    func extensions(for idea: IdeaBrief) async throws -> [String] {
        let data = try await client.complete(system: Prompts.extensionInstructions, prompt: Prompts.ideaText(idea),
                                             schema: Self.extensionSchema, effort: "medium", feature: "Variant suggestions")
        struct Out: Decodable { let suggestions: [String] }
        return try JSONDecoder().decode(Out.self, from: try Self.extractJSON(data)).suggestions
    }

    // MARK: - Schemas and parsing (static so they can be unit tested)

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
            "pain_clusters": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"], "buyer": ["type": "string"], "workaround": ["type": "string"],
                        "pay_signals": ["type": "string"], "summary": ["type": "string"],
                        "item_numbers": ["type": "array", "items": ["type": "integer"]],
                    ],
                    "required": ["title", "buyer", "workaround", "pay_signals", "summary", "item_numbers"],
                    "additionalProperties": false,
                ],
            ],
            "noise_numbers": ["type": "array", "items": ["type": "integer"]],
        ],
        "required": ["themes", "translations", "pain_clusters", "noise_numbers"],
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

    static func parseClusters(_ data: Data) throws -> [ThemeDraft] {
        struct Out: Decodable {
            struct C: Decodable {
                let title, buyer, workaround, pay_signals, summary: String
                let item_numbers: [Int]
            }
            let pain_clusters: [C]?
        }
        return (try JSONDecoder().decode(Out.self, from: try extractJSON(data)).pain_clusters ?? []).map {
            ThemeDraft(title: $0.title, summary: $0.summary, opportunities: [], itemNumbers: $0.item_numbers,
                       isPainCluster: true, buyer: $0.buyer, workaround: $0.workaround, paySignals: $0.pay_signals)
        }
    }

    static func parseNoise(_ data: Data) throws -> Set<Int> {
        struct Out: Decodable { let noise_numbers: [Int]? }
        return Set(try JSONDecoder().decode(Out.self, from: try extractJSON(data)).noise_numbers ?? [])
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


// MARK: - Claude

/// Calls the Claude Messages API directly with URLSession (there is no official Swift SDK).
/// The reply is streamed, so long requests are less likely to time out.
struct ClaudeClient: LLMClient {
    let provider = AIProvider.claude
    let apiKey: String
    var model = AIProvider.claude.recommendedModel
    var price = AIProvider.claude.models[0].price

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func complete(system: String, prompt: String, schema: [String: Any], effort: String, feature: String) async throws -> Data {
        var body = Self.requestBody(system: system, prompt: prompt, schema: schema, effort: effort, model: model)
        body["stream"] = true
        let payload = try JSONSerialization.data(withJSONObject: body)
        return try await LLMRetry.run { try await sendOnce(payload, feature: feature) }
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
            throw LLMHTTPError(provider: provider.shortName, status: http.statusCode,
                               retryAfter: http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init),
                               detail: String(decoding: body.prefix(300), as: UTF8.self))
        }
        var stream = StreamAssembler()
        do {
            for try await line in bytes.lines { try stream.consume(line) }
        } catch {
            // Input tokens are billed even if the reply is lost part-way, so record what we know.
            if let partial = stream.usageOnlyResponse() { UsageTracker.record(response: partial, feature: feature, price: price) }
            throw error
        }
        let data = try stream.response()
        UsageTracker.record(response: data, feature: feature, price: price)
        return data
    }

    static func requestBody(system: String, prompt: String, schema: [String: Any], effort: String = "medium",
                            model: String = AIProvider.claude.recommendedModel) -> [String: Any] {
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
}

// MARK: - Retries (shared by every provider)

enum LLMRetry {
    static let delays: [Double] = [3, 15]

    /// Runs `operation`, retrying temporary failures up to twice. Cancellation is passed straight through.
    static func run(_ operation: () async throws -> Data) async throws -> Data {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                guard attempt < delays.count, isRetryable(error) else { throw error }
                let wait = retryDelay(attempt: attempt, retryAfter: (error as? LLMHTTPError)?.retryAfter)
                attempt += 1
                try await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// Only temporary problems are retried; a bad key or a malformed request fails straight away.
    static func isRetryable(_ error: Error) -> Bool {
        if let http = error as? LLMHTTPError { return [408, 429, 529].contains(http.status) || (500...599).contains(http.status) }
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
        return delays[min(attempt, delays.count - 1)] + jitter
    }
}

struct LLMHTTPError: LocalizedError, Equatable {
    var provider = "Claude"
    let status: Int
    let retryAfter: Double?
    let detail: String

    var errorDescription: String? {
        switch status {
        case 401, 403: "\(provider) rejected the API key (HTTP \(status)). Check it in Settings."
        case 404: "\(provider) doesn't recognise the model (HTTP 404). Check the model name in Settings."
        case 429: "\(provider) is rate-limiting requests (HTTP 429)."
        case 529: "\(provider) is overloaded right now (HTTP 529)."
        default: "\(provider) returned HTTP \(status) \(detail)"
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
