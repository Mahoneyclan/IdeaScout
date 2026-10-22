// AIProviders.swift
// The catalogue of AI providers and models the user can choose from (Settings → Advanced → AI & costs):
// names, countries, key pages, models with list prices, and how each provider's API must be called.
// This list is maintained by hand; prices and model names change, so check them before each release
// (an automatic update routine is planned).

import Foundation

// MARK: - Prices and capabilities

/// Price per million tokens, in US dollars.
struct ModelPrice: Equatable, Sendable {
    /// Uncached input tokens.
    var input: Double
    /// Output tokens (including any reasoning tokens).
    var output: Double
    /// Input tokens read from the provider's cache.
    var cachedInput: Double

    /// Creates a price. If no cache price is given, assumes the common 10% of the input price.
    init(input: Double, output: Double, cachedInput: Double? = nil) {
        self.input = input
        self.output = output
        self.cachedInput = cachedInput ?? input / 10
    }

    /// Dollar cost of one call.
    /// - Parameters:
    ///   - inTokens: Uncached input tokens.
    ///   - outTokens: Output tokens.
    ///   - cacheWrite: Tokens written to the cache, charged at 1.25× input (Anthropic's rate; others rarely report it).
    ///   - cacheRead: Tokens read from the cache.
    /// - Returns: US dollars.
    func cost(input inTokens: Int, output outTokens: Int, cacheWrite: Int = 0, cacheRead: Int = 0) -> Double {
        (Double(inTokens) * input + Double(outTokens) * output
         + Double(cacheWrite) * input * 1.25 + Double(cacheRead) * cachedInput) / 1_000_000
    }
}

/// How a model can be asked for structured JSON.
enum JSONMode: Sendable {
    case schema     // the reply is forced to match the schema
    case object     // valid JSON is promised; the schema goes in the instructions
    case prompt     // no JSON setting at all; the schema goes in the instructions
}

/// What a model accepts, beyond the basics.
struct ModelCapabilities: Equatable, Sendable {
    /// How to ask for JSON.
    var json: JSONMode
    /// Whether the `reasoning_effort` setting may be sent.
    var reasoningEffort: Bool
    /// Whether a separate system (instructions) message is accepted; if not, instructions go in the user message.
    var systemMessage = true
}

/// One model offered in Settings.
struct ModelOption: Equatable, Sendable, Identifiable {
    /// The API model ID, sent in requests.
    var id: String
    /// Name shown in the model picker.
    var label: String
    /// List price, used by the cost tracker.
    var price: ModelPrice
    /// nil = the provider's usual capabilities.
    var capabilities: ModelCapabilities? = nil
}

// MARK: - Providers

/// The AI services IdeaScout can use. Only one is active at a time. Apple runs on the iPhone;
/// the others are cloud services that need the user's own API key (kept in the Keychain).
enum AIProvider: String, CaseIterable, Identifiable, Sendable {
    /// Raw values are stored in settings and Keychain names; don't rename. Removed providers fall back to Claude.
    case claude, openai, gemini, grok, deepseek, qwen, glm, kimi, mimo, apple

    /// Identity for SwiftUI pickers.
    var id: String { rawValue }

    /// Full name shown in pickers, e.g. "Claude (Anthropic)".
    var label: String {
        switch self {
        case .claude: "Claude (Anthropic)"
        case .openai: "ChatGPT (OpenAI)"
        case .gemini: "Gemini (Google)"
        case .grok: "Grok (xAI)"
        case .deepseek: "DeepSeek"
        case .qwen: "Qwen (Alibaba)"
        case .glm: "GLM (Z.ai)"
        case .kimi: "Kimi (Moonshot AI)"
        case .mimo: "MiMo (Xiaomi)"
        case .apple: "Apple (on-device)"
        }
    }

    /// Short name used in digests, warnings and the cost tracker.
    var shortName: String {
        switch self {
        case .claude: "Claude"
        case .openai: "ChatGPT"
        case .gemini: "Gemini"
        case .grok: "Grok"
        case .deepseek: "DeepSeek"
        case .qwen: "Qwen"
        case .glm: "GLM"
        case .kimi: "Kimi"
        case .mimo: "MiMo"
        case .apple: "Apple on-device"
        }
    }

    /// Where the company that runs the service is based (shown so users know where their data goes).
    var country: String {
        switch self {
        case .deepseek, .qwen, .glm, .kimi, .mimo: "China"
        default: "USA"
        }
    }

    /// Extra note shown in Settings about where data is processed.
    var dataNote: String? {
        switch self {
        case .qwen: "Uses Alibaba's US (Virginia) service address."
        case .deepseek, .glm, .kimi, .mimo: "Your About me and business challenges are sent to servers run by a company in China."
        case .apple: "Runs entirely on this iPhone."
        default: nil
        }
    }

    /// Whether it needs an API key and sends data off the phone (everything except Apple).
    var isCloud: Bool { self != .apple }

    /// Where this provider's API key is stored; `nil` for Apple.
    var keychainKey: Keychain.Key? {
        switch self {
        case .claude: .claudeAPIKey
        case .openai: .openaiAPIKey
        case .gemini: .geminiAPIKey
        case .grok: .grokAPIKey
        case .deepseek: .deepseekAPIKey
        case .qwen: .qwenAPIKey
        case .glm: .glmAPIKey
        case .kimi: .kimiAPIKey
        case .mimo: .mimoAPIKey
        case .apple: nil
        }
    }

    /// Where to create an API key.
    var keyURL: String {
        switch self {
        case .claude: "console.anthropic.com"
        case .openai: "platform.openai.com/api-keys"
        case .gemini: "aistudio.google.com/apikey"
        case .grok: "console.x.ai"
        case .deepseek: "platform.deepseek.com"
        case .qwen: "modelstudio.console.alibabacloud.com (US region)"
        case .glm: "z.ai/manage-apikey"
        case .kimi: "platform.moonshot.ai"
        case .mimo: "platform.xiaomimimo.com"
        case .apple: ""
        }
    }

    /// Models offered in Settings. The first is the recommended default. Prices are list prices
    /// as checked in October 2026 (Claude's from Anthropic's pricing page); any other model can be typed in with its own price.
    var models: [ModelOption] {
        switch self {
        case .claude:
            [ModelOption(id: "claude-sonnet-5-5", label: "Claude Sonnet 5.5", price: ModelPrice(input: 2, output: 10, cachedInput: 0.1)),
             ModelOption(id: "claude-opus-5-5", label: "Claude Opus 5.5 (sharper, 2× cost)", price: ModelPrice(input: 4, output: 20, cachedInput: 0.2)),
             ModelOption(id: "claude-fable-5-1", label: "Claude Fable 5.1 (most capable, ~2.5× cost)",
                         price: ModelPrice(input: 10, output: 50, cachedInput: 0.25))]
        case .openai:
            [ModelOption(id: "gpt-6.1-sol", label: "GPT-6.1 Sol", price: ModelPrice(input: 2, output: 10)),
             ModelOption(id: "gpt-6-astra", label: "GPT-6 Astra (most capable)", price: ModelPrice(input: 10, output: 50, cachedInput: 1))]
        case .gemini:
            [ModelOption(id: "gemini-4-argon", label: "Gemini 4 Argon", price: Self.geminiArgonPrice()),
             // Gemma runs on the same Google service and key. It doesn't take system instructions or a JSON setting.
             ModelOption(id: "gemma-4-31b-it", label: "Gemma 4 31B (open, free within limits)", price: ModelPrice(input: 0, output: 0),
                         capabilities: ModelCapabilities(json: .prompt, reasoningEffort: false, systemMessage: false))]
        case .grok:
            [ModelOption(id: "grok-4.3", label: "Grok 4.3", price: ModelPrice(input: 1.25, output: 2.5))]
        case .deepseek:
            [ModelOption(id: "deepseek-flash", label: "DeepSeek V4.1", price: ModelPrice(input: 0.3, output: 1.2))]
        case .qwen:
            [ModelOption(id: "qwen3.8-max", label: "Qwen 3.8 Max", price: ModelPrice(input: 2, output: 6))]
        case .glm:
            [ModelOption(id: "glm-5.3", label: "GLM-5.3", price: ModelPrice(input: 1.4, output: 4.4, cachedInput: 0.26))]
        case .kimi:
            [ModelOption(id: "kimi-k3", label: "Kimi K3 (always reasons, slower)", price: ModelPrice(input: 3, output: 15, cachedInput: 0.3))]
        case .mimo:
            [ModelOption(id: "mimo-v2.6-pro", label: "MiMo-V2.6-Pro", price: ModelPrice(input: 0.435, output: 0.87))]
        case .apple:
            []
        }
    }

    /// The default model: the first in `models`.
    var recommendedModel: String { models.first?.id ?? "" }

    /// Gemini 4 Argon's price: introductory until 1 December 2026 (UTC), then doubled. Evaluated when the model
    /// list is read, so a running app picks up the new price after a relaunch.
    static func geminiArgonPrice(on date: Date = .now) -> ModelPrice {
        let end = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
                                 year: 2026, month: 12, day: 1).date!
        return date < end ? ModelPrice(input: 2, output: 10, cachedInput: 0.1) : ModelPrice(input: 4, output: 20, cachedInput: 0.2)
    }

    // MARK: - How to call the OpenAI-compatible providers

    /// The chat-completions address for OpenAI-compatible providers; `nil` for Claude (own client) and Apple.
    /// Qwen uses Alibaba's US (Virginia) region so data stays outside China.
    var chatURL: URL? {
        switch self {
        case .openai: URL(string: "https://api.openai.com/v1/chat/completions")
        case .gemini: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        case .grok: URL(string: "https://api.x.ai/v1/chat/completions")
        case .deepseek: URL(string: "https://api.deepseek.com/chat/completions")
        case .qwen: URL(string: "https://dashscope-us.aliyuncs.com/compatible-mode/v1/chat/completions")
        case .glm: URL(string: "https://api.z.ai/api/paas/v4/chat/completions")
        case .kimi: URL(string: "https://api.moonshot.ai/v1/chat/completions")
        case .mimo: URL(string: "https://api.xiaomimimo.com/v1/chat/completions")
        case .claude, .apple: nil
        }
    }

    /// The provider's usual capabilities. Strict schemas only where the provider documents them;
    /// elsewhere JSON mode with the schema written into the instructions.
    var defaultCapabilities: ModelCapabilities {
        switch self {
        case .openai, .gemini: ModelCapabilities(json: .schema, reasoningEffort: true)
        case .grok, .qwen: ModelCapabilities(json: .schema, reasoningEffort: false)
        case .deepseek: ModelCapabilities(json: .object, reasoningEffort: true)
        case .glm, .kimi, .mimo: ModelCapabilities(json: .object, reasoningEffort: false)
        case .claude, .apple: ModelCapabilities(json: .schema, reasoningEffort: true)
        }
    }

    /// Capabilities for a model: its own if listed with special needs (e.g. Gemma), otherwise the provider's.
    func capabilities(for model: String) -> ModelCapabilities {
        models.first { $0.id == model }?.capabilities ?? defaultCapabilities
    }

    /// Name of the reply-length setting (OpenAI's newer models renamed it).
    var maxTokensField: String { self == .openai ? "max_completion_tokens" : "max_tokens" }

    /// Reply length limit. Large enough for a 300-item trend reply; DeepSeek gets less because its documented
    /// maximum is lower.
    var maxTokens: Int { self == .deepseek ? 16_000 : 32_000 }
}
