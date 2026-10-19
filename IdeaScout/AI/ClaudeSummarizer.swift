import Foundation

/// Calls the Claude Messages API directly with URLSession (there is no official Swift SDK).
/// The API key comes from the Keychain and is never stored in source.
struct ClaudeSummarizer: Summarizer {
    let name = "Claude"
    let maxItems = 150
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
        let prompt = "Projects:\n" + Prompts.itemList(items, detailLimit: 200)
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
    func send(_ body: [String: Any], feature: String) async throws -> Data {
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
        UsageTracker.record(response: data, feature: feature)
        return data
    }

    // MARK: - Request / response shapes (static so they can be unit tested)

    static func requestBody(system: String, prompt: String, schema: [String: Any], effort: String = "medium") -> [String: Any] {
        [
            "model": model,
            "max_tokens": 16000,
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
