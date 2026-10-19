import Foundation

/// Calls the Claude Messages API directly with URLSession (there is no official Swift SDK).
/// The API key comes from the Keychain and is never stored in source.
struct ClaudeSummarizer: Summarizer {
    let name = "Claude"
    let maxItems = 60
    let apiKey: String

    static let model = "claude-opus-5-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func themes(for items: [FetchedItem]) async throws -> [ThemeDraft] {
        let prompt = "Projects:\n" + Prompts.itemList(items, detailLimit: 200)
        let data = try await send(Self.requestBody(system: Prompts.themeInstructions, prompt: prompt, schema: Self.themeSchema))
        return try Self.parseThemes(data)
    }

    func extensions(for idea: IdeaBrief) async throws -> [String] {
        let data = try await send(Self.requestBody(system: Prompts.extensionInstructions,
                                                   prompt: Prompts.ideaText(idea), schema: Self.extensionSchema))
        struct Out: Decodable { let suggestions: [String] }
        return try JSONDecoder().decode(Out.self, from: try Self.extractJSON(data)).suggestions
    }

    private func send(_ body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // Lets the API retry a declined request on a suitable fallback model.
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SummarizerError.badResponse("HTTP \(http.statusCode) \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        return data
    }

    // MARK: - Request / response shapes (static so they can be unit tested)

    static func requestBody(system: String, prompt: String, schema: [String: Any]) -> [String: Any] {
        [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            "fallbacks": "default",
            "output_config": [
                "effort": "medium",
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
                    ],
                    "required": ["title", "summary", "opportunities", "item_numbers"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["themes"],
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

    static func parseThemes(_ data: Data) throws -> [ThemeDraft] {
        struct Out: Decodable {
            struct T: Decodable { let title: String; let summary: String; let opportunities: [String]; let item_numbers: [Int] }
            let themes: [T]
        }
        return try JSONDecoder().decode(Out.self, from: try extractJSON(data)).themes.map {
            ThemeDraft(title: $0.title, summary: $0.summary, opportunities: $0.opportunities, itemNumbers: $0.item_numbers)
        }
    }
}
