import Foundation
import FoundationModels

/// Uses Apple's on-device model (Apple Intelligence). Free and private, but the
/// model has a small context window, so it sees fewer items with shorter text.
struct AppleSummarizer: Summarizer {
    let name = "Apple on-device"

    let maxItems = 25

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static var statusText: String {
        switch SystemLanguageModel.default.availability {
        case .available: return "Ready"
        case .unavailable(.deviceNotEligible): return "This iPhone doesn't support Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in iOS Settings"
        case .unavailable(.modelNotReady): return "Apple's model is still downloading"
        case .unavailable: return "Not available"
        }
    }

    @Generable
    struct GeneratedThemes {
        @Guide(description: "3 to 6 themes")
        var themes: [GeneratedTheme]
    }

    @Generable
    struct GeneratedTheme {
        @Guide(description: "Short specific theme name, max 6 words")
        var title: String
        @Guide(description: "Two sentences on what people are building and why it matters")
        var summary: String
        @Guide(description: "2 or 3 one-sentence ways to extend these ideas or build a differentiated version")
        var opportunities: [String]
        @Guide(description: "Numbers of the projects that belong to this theme")
        var itemNumbers: [Int]
    }

    @Generable
    struct GeneratedExtensions {
        @Guide(description: "4 to 6 ways to extend or differentiate the project")
        var suggestions: [String]
    }

    func themes(for items: [FetchedItem]) async throws -> [ThemeDraft] {
        let session = LanguageModelSession(instructions: Prompts.themeInstructions)
        let prompt = "Projects:\n" + Prompts.itemList(Array(items.prefix(maxItems)), detailLimit: 80)
        let response = try await session.respond(to: prompt, generating: GeneratedThemes.self)
        return response.content.themes.map {
            ThemeDraft(title: $0.title, summary: $0.summary, opportunities: $0.opportunities, itemNumbers: $0.itemNumbers)
        }
    }

    func extensions(for idea: IdeaBrief) async throws -> [String] {
        let session = LanguageModelSession(instructions: Prompts.extensionInstructions)
        let response = try await session.respond(to: Prompts.ideaText(idea), generating: GeneratedExtensions.self)
        return response.content.suggestions
    }
}
