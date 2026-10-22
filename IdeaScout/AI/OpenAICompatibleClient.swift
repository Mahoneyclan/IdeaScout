// OpenAICompatibleClient.swift
// The client for every cloud provider except Claude: ChatGPT, Gemini (including Gemma), Grok, DeepSeek,
// Qwen, GLM, Kimi and MiMo all accept OpenAI-style chat requests. Per-model differences (JSON mode,
// system messages, reasoning effort, reply-length field) come from AIProviders.swift.

import Foundation

/// One client for every provider that accepts OpenAI-style chat requests: ChatGPT, Gemini, Grok,
/// DeepSeek, Qwen, GLM, Kimi and MiMo. The reply is converted to the same shape as Claude's, so parsing and
/// cost tracking are shared.
struct OpenAICompatibleClient: LLMClient {
    /// Which provider (decides the address and request details).
    let provider: AIProvider
    /// The user's key for this provider, from the Keychain. Sent only to `provider.chatURL` as a Bearer token.
    let apiKey: String
    /// API model ID.
    let model: String
    /// Price used for cost tracking.
    let price: ModelPrice

    /// Sends one request (see LLMClient.complete). On HTTP 400 it tries once more without the optional
    /// settings, because some models reject `reasoning_effort` or the reply-length field rather than ignoring them.
    func complete(system: String, prompt: String, schema: [String: Any], effort: String, feature: String) async throws -> Data {
        guard let url = provider.chatURL else { throw SummarizerError.unavailable }
        let full = Self.requestBody(provider: provider, model: model, system: system, prompt: prompt, schema: schema, effort: effort)
        do {
            return try await send(full, to: url, feature: feature)
        } catch let error as LLMHTTPError where error.status == 400 {
            // Some models reject optional settings (reasoning effort, reply length). Try once without them.
            let minimal = Self.requestBody(provider: provider, model: model, system: system, prompt: prompt, schema: schema,
                                           effort: effort, optionalSettings: false)
            return try await send(minimal, to: url, feature: feature)
        }
    }

    /// Sends with retries, converts the reply and records its cost.
    /// - Throws: `LLMHTTPError`, network errors, or decoding errors.
    private func send(_ body: [String: Any], to url: URL, feature: String) async throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: body)
        return try await LLMRetry.run {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 300
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = payload
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw LLMHTTPError(provider: provider.shortName, status: http.statusCode,
                                   retryAfter: http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init),
                                   detail: String(decoding: data.prefix(300), as: UTF8.self))
            }
            let converted = try Self.convert(data)
            UsageTracker.record(response: converted, feature: feature, price: price)
            return converted
        }
    }

    // MARK: - Request / response shapes (static so they can be unit tested)

    /// The chat request for a provider and model.
    /// - Parameters:
    ///   - provider: Decides JSON mode, message layout and setting names (with `model`).
    ///   - model: API model ID.
    ///   - system: Instructions.
    ///   - prompt: The user message.
    ///   - schema: JSON Schema the reply must follow.
    ///   - effort: Reasoning effort, sent only where the model accepts it.
    ///   - optionalSettings: `false` leaves out `reasoning_effort` and the reply-length field (used for the retry).
    /// - Returns: The JSON body. With JSON mode `.object` or `.prompt`, the schema is written into the instructions.
    static func requestBody(provider: AIProvider, model: String, system: String, prompt: String, schema: [String: Any],
                            effort: String, optionalSettings: Bool = true) -> [String: Any] {
        let caps = provider.capabilities(for: model)
        var systemText = system
        var body: [String: Any] = ["model": model]
        switch caps.json {
        case .schema:
            body["response_format"] = ["type": "json_schema",
                                       "json_schema": ["name": "result", "strict": true, "schema": schema]]
        case .object, .prompt:
            // The word "JSON" and the expected shape must be in the instructions.
            let schemaText = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            systemText += "\n\nReply with a single JSON object only, matching this JSON schema exactly:\n" + schemaText
            if caps.json == .object { body["response_format"] = ["type": "json_object"] }
        }
        body["messages"] = caps.systemMessage
            ? [["role": "system", "content": systemText], ["role": "user", "content": prompt]]
            : [["role": "user", "content": systemText + "\n\n" + prompt]]
        if optionalSettings {
            body[provider.maxTokensField] = provider.maxTokens
            if caps.reasoningEffort { body["reasoning_effort"] = effort }
        }
        return body
    }

    /// Turns an OpenAI-style chat reply into the Claude-style shape the parsers expect: `finish_reason` "length"
    /// becomes "max_tokens", "content_filter" or a refusal becomes "refusal"; cached prompt tokens are split
    /// out of the input count so they're priced at the cache rate.
    /// - Throws: Decoding errors, or `.badResponse` if there's no reply.
    static func convert(_ data: Data) throws -> Data {
        /// The parts of an OpenAI-style chat reply needed here.
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String?; let refusal: String? }
                let message: Message
                let finish_reason: String?
            }
            struct Usage: Decodable {
                struct Details: Decodable { let cached_tokens: Int? }
                let prompt_tokens: Int?
                let completion_tokens: Int?
                let prompt_tokens_details: Details?
            }
            let choices: [Choice]
            let usage: Usage?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let choice = response.choices.first else { throw SummarizerError.badResponse("no reply") }
        let stop: String = switch choice.finish_reason {
        case "length": "max_tokens"
        case "content_filter": "refusal"
        default: choice.message.refusal != nil ? "refusal" : "end_turn"
        }
        let cached = response.usage?.prompt_tokens_details?.cached_tokens ?? 0
        let usage: [String: Int] = [
            "input_tokens": max((response.usage?.prompt_tokens ?? 0) - cached, 0),
            "output_tokens": response.usage?.completion_tokens ?? 0,
            "cache_read_input_tokens": cached,
        ]
        let object: [String: Any] = [
            "content": [["type": "text", "text": stripFences(choice.message.content ?? "")]],
            "stop_reason": stop,
            "usage": usage,
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// Some models wrap JSON in ```json fences despite being asked not to.
    static func stripFences(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```") else { return t }
        t = String(t.drop { $0 != "\n" }.dropFirst())
        if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
