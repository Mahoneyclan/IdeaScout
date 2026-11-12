// LLMSummarizer.swift
// Cloud AI support. Defines LLMClient (one request → structured JSON reply) and LLMSummarizer (trends,
// pain clusters, translations and variant suggestions using any LLMClient), plus the Claude client
// (streaming), the retry rules shared by every provider, and the stream decoder.
// OpenAICompatibleClient.swift holds the client for every other provider.

import Foundation

// MARK: - Client protocol and summariser

/// A cloud AI that returns structured JSON. Every client returns its reply in the same shape
/// (a Claude-style message with `content`, `stop_reason` and `usage`), so the parsers and the
/// cost tracker work the same for every provider. API keys come from the Keychain, never from source.
/// Threading: clients are `Sendable` value types and are called from the refresh task, off the main actor;
/// `complete` suspends while the network call runs.
protocol LLMClient: Sendable {
    /// Which provider this client talks to.
    var provider: AIProvider { get }
    /// The API model ID used for requests.
    var model: String { get }
    /// Sends one request and returns the reply. Records the call's cost in UsageTracker. Retries temporary failures
    /// (see `LLMRetry`); `OpenAICompatibleClient` also re-sends once without optional settings after an HTTP 400.
    /// Each attempt that reaches the provider may be billed.
    /// - Parameters:
    ///   - system: Instructions.
    ///   - prompt: The user message (usually the numbered item list).
    ///   - schema: JSON Schema the reply must follow.
    ///   - effort: "medium" or "high": how hard the model should think, where supported.
    ///   - feature: Cost-tracker label, e.g. "Trends".
    /// - Returns: The reply in Claude's message format (`content`, `stop_reason`, `usage`).
    /// - Throws: `LLMHTTPError`, network errors, `StreamAssembler.StreamError`, `SummarizerError` (`.unavailable`
    ///   when the provider has no chat address, `.badResponse` for an empty reply), `DecodingError`, or `CancellationError`.
    func complete(system: String, prompt: String, schema: [String: Any], effort: String, feature: String) async throws -> Data
}

/// Trends, pain clusters, translations and variant suggestions from whichever cloud AI is chosen.
struct LLMSummarizer: Summarizer {
    /// The chosen provider's client (from AppSettings.makeClient).
    let client: any LLMClient
    /// Stored on the digest, e.g. "Claude" or "Gemini".
    var name: String { client.provider.shortName }
    /// The user's "Items the AI reads" setting (the key name predates other providers).
    var maxItems: Int { AppSettings.claudeMaxItems }

    /// Trends and clusters only (drops translations and noise).
    /// - Parameter items: The items to group, in prompt order.
    /// - Returns: Trend and pain-cluster drafts with 1-based item numbers.
    /// - Throws: Errors from `complete` or the parsers.
    func themes(for items: [FetchedItem]) async throws -> [ThemeDraft] {
        try await analyse(items).drafts
    }

    /// Asks for English translations of non-English items in the same call, so no separate request is needed.
    static let translationInstruction = "\nSome projects are not in English. For every project whose title or description "
        + "is not in English, add an entry to translations with its number and an English title and description. "
        + "Leave English projects out of translations."

    /// Asks for pain clusters from Demand items and a list of noise items, alongside the trends.
    static let clusterInstruction = """

    Items are tagged Demand (complaints, requests, spending), Supply (things being built) or Timing (new startups \
    and capabilities). Build the themes above from Supply and Timing items. Separately, group Demand items into 3 to 6 \
    pain_clusters: each is one problem felt by one type of buyer. Give: title (the problem in the buyer's words), \
    buyer (a specific role and type of business, or a specific type of consumer), workaround (what they do today), pay_signals (any sign they pay or \
    would pay, e.g. prices mentioned, paid tools they're leaving, or "none seen"), summary (one sentence), and item \
    numbers. A cluster needs at least 2 items unless one item is from "My pain points". Those are the user's own \
    problems: treat them as strong evidence. List in noise_numbers any items that are spam, \
    off-topic or useless as product evidence.
    """

    /// One call that returns trends, pain clusters, translations and noise (feature "Trends").
    /// - Parameter items: The items to analyse; numbered from 1 in this order in the prompt.
    /// - Returns: Drafts (trends then pain clusters), translations and noise, all keyed by item number.
    /// - Throws: Errors from `complete` or the parsers.
    func analyse(_ items: [FetchedItem]) async throws -> Analysis {
        let prompt = "Window: the last \(AppSettings.trendWindowDays) days (pain points: \(AppSettings.painWindowDays) days).\n\n"
            + "Projects:\n" + Prompts.itemList(items, detailLimit: 200)
        let data = try await client.complete(system: Prompts.themeInstructions + Self.translationInstruction + Self.clusterInstruction,
                                             prompt: prompt, schema: Self.themeSchema, effort: "medium", feature: "Trends")
        return Analysis(drafts: try Self.parseThemes(data) + (try Self.parseClusters(data)),
                        translations: try Self.parseTranslations(data), noise: try Self.parseNoise(data))
    }

    /// Money-making variants for a saved project (feature "Variant suggestions"). One paid call.
    /// - Parameter idea: The saved project, including the user's notes.
    /// - Returns: The suggestions as plain sentences.
    /// - Throws: Errors from `complete` or the parser.
    func extensions(for idea: IdeaBrief) async throws -> [String] {
        let data = try await client.complete(system: Prompts.extensionInstructions, prompt: Prompts.ideaText(idea),
                                             schema: Self.extensionSchema, effort: "medium", feature: "Variant suggestions")
        /// The reply's JSON shape (field names match the schema).
        struct Out: Decodable { let suggestions: [String] }
        return try JSONDecoder().decode(Out.self, from: try Self.extractJSON(data)).suggestions
    }

    // MARK: - Schemas and parsing (static so they can be unit tested)

    /// JSON Schema for the trend step. Every property is required and extra properties are forbidden, as
    /// strict structured outputs require. Keep in sync with the parsers below and the prompt wording.
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

    /// JSON Schema for "Suggest variants".
    static let extensionSchema: [String: Any] = [
        "type": "object",
        "properties": ["suggestions": ["type": "array", "items": ["type": "string"]]],
        "required": ["suggestions"],
        "additionalProperties": false,
    ]

    /// Returns the JSON text the AI produced, after checking it wasn't refused or cut off.
    /// - Parameter data: A reply in Claude's message format.
    /// - Returns: The text of the first text block, as UTF-8 data.
    /// - Throws: `SummarizerError.refused`, or `.badResponse` if cut off at the length limit or empty.
    static func extractJSON(_ data: Data) throws -> Data {
        /// The parts of a Claude-format reply needed here.
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

    /// Reads one part of the trend-step reply.
    /// - Parameter data: The raw reply body.
    /// - Returns: English title and description by 1-based item number (first entry wins on duplicates).
    /// - Throws: `DecodingError` or `SummarizerError` if the reply is refused, cut off or malformed.
    static func parseTranslations(_ data: Data) throws -> [Int: Translation] {
        /// The reply's JSON shape (field names match the schema).
        struct Out: Decodable {
            struct T: Decodable { let number: Int; let title: String; let description: String }
            let translations: [T]?
        }
        let out = try JSONDecoder().decode(Out.self, from: try extractJSON(data))
        return Dictionary((out.translations ?? []).map { ($0.number, Translation(title: $0.title, detail: $0.description)) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// Reads one part of the trend-step reply.
    /// - Parameter data: The raw reply body.
    /// - Returns: Pain clusters as drafts with `isPainCluster` set (empty if the reply has none).
    /// - Throws: `DecodingError` or `SummarizerError` if the reply is refused, cut off or malformed.
    static func parseClusters(_ data: Data) throws -> [ThemeDraft] {
        /// The reply's JSON shape (field names match the schema).
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

    /// Reads one part of the trend-step reply.
    /// - Parameter data: The raw reply body.
    /// - Returns: 1-based numbers of items the AI marked as noise.
    /// - Throws: `DecodingError` or `SummarizerError` if the reply is refused, cut off or malformed.
    static func parseNoise(_ data: Data) throws -> Set<Int> {
        /// The reply's JSON shape (field names match the schema).
        struct Out: Decodable { let noise_numbers: [Int]? }
        return Set(try JSONDecoder().decode(Out.self, from: try extractJSON(data)).noise_numbers ?? [])
    }

    /// Reads one part of the trend-step reply.
    /// - Parameter data: The raw reply body.
    /// - Returns: Trend drafts with the AI's scores (clamped later by ThemeBuilder).
    /// - Throws: `DecodingError` or `SummarizerError` if the reply is refused, cut off or malformed.
    static func parseThemes(_ data: Data) throws -> [ThemeDraft] {
        /// The reply's JSON shape (field names match the schema).
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
    /// Fixed: this client only talks to Anthropic.
    let provider = AIProvider.claude
    /// The user's Anthropic key, from the Keychain. Only ever sent to Anthropic in the `x-api-key` header.
    let apiKey: String
    /// Model ID (Sonnet by default).
    var model = ScanStep.writing.mixedModelID
    /// Price used for cost tracking.
    var price = AIProvider.claude.models[0].price

    // Safe to unwrap: a constant, valid URL.
    /// Anthropic's Messages API.
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Streams one request, with retries. See LLMClient.complete.
    /// - Parameters:
    ///   - system: Instructions.
    ///   - prompt: The user message.
    ///   - schema: JSON Schema the reply must follow.
    ///   - effort: "medium" or "high".
    ///   - feature: Cost-tracker label.
    /// - Returns: The rebuilt reply in Messages API shape.
    /// - Throws: `LLMHTTPError`, `StreamAssembler.StreamError`, network errors or `CancellationError`.
    func complete(system: String, prompt: String, schema: [String: Any], effort: String, feature: String) async throws -> Data {
        var body = Self.requestBody(system: system, prompt: prompt, schema: schema, effort: effort, model: model)
        body["stream"] = true
        let payload = try JSONSerialization.data(withJSONObject: body)
        return try await LLMRetry.run { try await sendOnce(payload, feature: feature) }
    }

    /// One attempt: sends the request, reads the event stream and rebuilds a normal reply.
    /// - Throws: `LLMHTTPError` for non-2xx replies (with up to 300 characters of the body), stream or network errors.
    private func sendOnce(_ payload: Data, feature: String) async throws -> Data {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // Lets the API retry a declined request on a suitable fallback model.
        if Self.usesServerFallback(model) {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
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
            if let partial = stream.usageOnlyResponse() {
                UsageTracker.record(response: partial, feature: feature,
                                    price: Self.price(servedBy: stream.model, chosen: model, chosenPrice: price))
            }
            throw error
        }
        let data = try stream.response()
        UsageTracker.record(response: data, feature: feature, price: Self.price(servedBy: stream.model, chosen: model, chosenPrice: price))
        return data
    }

    /// Prices of the models Anthropic's server-side fallback can answer with, beyond those in
    /// `AIProvider.claude.models`. Input and output from Anthropic's price table (6 Oct 2026); the table gives
    /// no cache-read price for these, so `ModelPrice`'s usual 10% of input is assumed (no caching is requested).
    static let fallbackPrices: [String: ModelPrice] = [
        "claude-opus-4-8": ModelPrice(input: 5, output: 25),
        "claude-opus-5": ModelPrice(input: 5, output: 25),
    ]

    /// Money: the price to record a call at, for the model that actually answered (a server-side fallback can
    /// answer with another Claude model).
    /// - Parameters:
    ///   - served: The model named in the reply, or `nil` if the stream didn't say.
    ///   - chosen: The model that was requested.
    ///   - chosenPrice: The requested model's price, which may be a typed-in custom price.
    /// - Returns: The served model's list price when it differs from the requested one and is known,
    ///   otherwise `chosenPrice`.
    static func price(servedBy served: String?, chosen: String, chosenPrice: ModelPrice) -> ModelPrice {
        guard let served, served != chosen else { return chosenPrice }
        return AIProvider.claude.models.first { $0.id == served }?.price ?? fallbackPrices[served] ?? chosenPrice
    }

    /// The Messages API request: structured output via `output_config.format`, effort level, a 32,000-token
    /// reply limit (enough for 300-item trend replies), and `fallbacks: "default"` (server-side model fallback:
    /// Anthropic may answer a declined request with another Claude model; never a different provider).
    /// - Parameters:
    ///   - system: Instructions.
    ///   - prompt: The user message.
    ///   - schema: JSON Schema the reply must follow.
    ///   - effort: "medium" or "high".
    ///   - model: API model ID.
    /// - Returns: The JSON body, without `stream` (the caller adds it).
    static func requestBody(system: String, prompt: String, schema: [String: Any], effort: String = "medium",
                            model: String = ScanStep.writing.mixedModelID) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 32000,
            "system": system,
            "output_config": [
                "effort": effort,
                "format": ["type": "json_schema", "schema": schema],
            ],
            "messages": [["role": "user", "content": prompt]],
        ]
        if usesServerFallback(model) { body["fallbacks"] = "default" }
        return body
    }

    /// Whether a model can use server-side fallback. Anthropic's refusals page (checked 13 Nov 2026) says Claude
    /// Haiku 5.5 has no server-side fallback, so Haiku requests don't ask for it.
    /// - Parameter model: API model ID.
    /// - Returns: `false` for Haiku models.
    static func usesServerFallback(_ model: String) -> Bool { !model.hasPrefix("claude-haiku") }
}

// MARK: - Retries (shared by every provider)

/// Retry rules shared by every provider.
enum LLMRetry {
    /// Waits before the first and second retry.
    static let delays: [Double] = [3, 15]

    /// Runs `operation`, retrying temporary failures up to twice. Cancellation is passed straight through.
    /// - Parameter operation: One attempt; it must be safe to repeat (each repeat is another, billed request).
    /// - Returns: The first successful result.
    /// - Throws: `CancellationError` if cancelled, otherwise the last attempt's error once retries run out
    ///   or the error isn't temporary.
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
    /// - Parameter error: The failed attempt's error.
    /// - Returns: `true` for timeouts, rate limits (429), overload (529), server errors, stream errors and dropped connections.
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
    /// - Parameters:
    ///   - attempt: 0 for the first retry.
    ///   - retryAfter: Seconds from the server's `retry-after` header, if any.
    ///   - jitter: Up to 1 s added so many clients don't retry in step; tests pass 0.
    /// - Returns: Seconds to wait.
    static func retryDelay(attempt: Int, retryAfter: Double?, jitter: Double = Double.random(in: 0...1)) -> Double {
        if let retryAfter { return min(max(retryAfter, 1), 30) }
        return delays[min(attempt, delays.count - 1)] + jitter
    }
}

/// A non-success HTTP reply from any provider, with a plain-English description.
struct LLMHTTPError: LocalizedError, Equatable {
    /// Provider name used in the message.
    var provider = "Claude"
    /// HTTP status code.
    let status: Int
    /// Seconds the server asked us to wait, if it said.
    let retryAfter: Double?
    /// Start of the reply body, for diagnosis.
    let detail: String

    /// A plain message for the user. Security/UX: never includes the provider's raw reply, which can
    /// contain internal details (request IDs, organisation names); that goes in `technicalDetail`.
    var errorDescription: String? {
        if needsCredit {
            return "Your \(provider) account is out of credit. Add credit on the provider's billing page, then try again."
        }
        return switch status {
        case 401, 403: "\(provider) rejected the API key (error \(status)). Check it in Settings."
        case 404: "\(provider) doesn't recognise the model (error 404). Check the model name in Settings."
        case 400: "\(provider) couldn't accept the request (error 400). Details below say why; try again later."
        case 402: "\(provider) says the account needs credit or billing set up (error 402)."
        case 429: "\(provider) is limiting requests right now (error 429). Try again in a few minutes."
        case 500...599: "\(provider) is busy or having problems right now (error \(status)). Try again later."
        default: "\(provider) couldn't complete the request (error \(status)). Try again later."
        }
    }

    /// Whether the reply says the account has run out of credit. Anthropic sends this as a plain 400
    /// `invalid_request_error`, so only its message tells it apart (recorded reply, 13 Nov 2026).
    var needsCredit: Bool { detail.lowercased().contains("credit balance is too low") }

    /// The raw status and start of the reply, shown only behind "Details" for diagnosis. This text is
    /// stored with the day's digest, so anything that looks like a key or token is hidden first.
    var technicalDetail: String { "HTTP \(status): \(Self.redacted(detail))" }

    /// Security: some providers echo part of the API key, a bearer token or other secrets in error replies.
    /// Hides `Bearer …`, `sk-…` and `AIza…` keys and any run of 24+ letters, digits, `_` or `-` (which also
    /// hides long request IDs, an acceptable loss for diagnosis).
    /// - Parameter text: The start of a provider's error reply.
    /// - Returns: The text with each such run replaced by "[hidden]".
    static func redacted(_ text: String) -> String {
        [#"(?i)bearer\s+[A-Za-z0-9._~+/=-]+"#, #"sk-[A-Za-z0-9_-]{8,}"#, #"AIza[A-Za-z0-9_-]{10,}"#, #"[A-Za-z0-9_-]{24,}"#]
            .reduce(text) { $0.replacingOccurrences(of: $1, with: "[hidden]", options: .regularExpression) }
    }
}

/// Rebuilds a normal (non-streamed) Messages API reply from server-sent events, so the existing
/// parsers and the cost tracker work unchanged. Text from every text block is joined (a mid-stream
/// model fallback can split the reply into several blocks); thinking and other blocks are skipped.
struct StreamAssembler {
    /// An error event in the stream, or a stream that ended before `message_stop`. Treated as retryable.
    struct StreamError: LocalizedError {
        /// The provider's error message or type, or a description of how the stream ended early.
        let message: String
        /// A plain message for the user.
        var errorDescription: String? { "Claude stream error: \(message)" }
    }

    /// Content block type by index ("text", "thinking", "fallback"…).
    private var blockTypes: [Int: String] = [:]
    /// Text collected per block index.
    private var texts: [Int: String] = [:]
    /// Why the reply ended (e.g. "end_turn", "max_tokens", "refusal").
    private(set) var stopReason: String?
    /// Token counts, largest value seen per field.
    private var usage: [String: Int] = [:]
    /// Set by `message_start`; usage is only known after it.
    private(set) var started = false
    /// The model that answered: named by `message_start`, and replaced by a `fallback` block's target
    /// when Anthropic switches models part-way.
    private(set) var model: String?
    /// Set by `message_stop`; a reply without it is incomplete.
    private(set) var finished = false

    /// Processes one line of the event stream. Non-data lines and unknown events are ignored.
    /// - Throws: `StreamError` if the stream reports an error.
    mutating func consume(_ line: String) throws {
        guard line.hasPrefix("data:") else { return }
        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = json.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        switch type {
        case "message_start":
            started = true
            let message = event["message"] as? [String: Any]
            if let name = message?["model"] as? String { model = name }
            mergeUsage(message?["usage"])
        case "content_block_start":
            if let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any] {
                blockTypes[index] = block["type"] as? String
                if block["type"] as? String == "fallback", let to = (block["to"] as? [String: Any])?["model"] as? String {
                    model = to
                }
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

    /// The finished reply in normal Messages API shape.
    /// - Returns: JSON with `content` (one text block), `usage` and, when known, `stop_reason`.
    /// - Throws: `StreamError` if the stream didn't start and finish.
    func response() throws -> Data {
        guard started, finished else { throw StreamError(message: "the reply ended early") }
        let text = blockTypes.keys.sorted().filter { blockTypes[$0] == "text" }.compactMap { texts[$0] }.joined()
        var object: [String: Any] = ["content": [["type": "text", "text": text]], "usage": usage]
        if let stopReason { object["stop_reason"] = stopReason }
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// Just the usage seen so far, so a failed stream's input tokens can still be recorded.
    /// - Returns: JSON with only `usage`, or `nil` if the stream never started.
    func usageOnlyResponse() -> Data? {
        guard started else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["usage": usage])
    }
}
