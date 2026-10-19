import Foundation

/// A theme as proposed by a summariser, before it is matched to stored items.
struct ThemeDraft: Equatable, Sendable {
    var title: String
    var summary: String
    var opportunities: [String]
    var itemNumbers: [Int]   // 1-based positions in the prompt's item list
}

/// What the summariser needs to suggest extensions for a saved idea.
struct IdeaBrief: Sendable {
    var title: String
    var detail: String
    var note: String
}

protocol Summarizer: Sendable {
    var name: String { get }
    /// How many items this summariser can handle in one go.
    var maxItems: Int { get }
    func themes(for items: [FetchedItem]) async throws -> [ThemeDraft]
    func extensions(for idea: IdeaBrief) async throws -> [String]
}

enum SummarizerError: LocalizedError {
    case unavailable
    case refused
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Suggestions need Apple Intelligence or a Claude API key (see Settings)."
        case .refused: "The AI declined to answer this request."
        case .badResponse(let detail): "Unexpected AI response: \(detail)"
        }
    }
}

enum AIProvider: String, CaseIterable, Identifiable {
    case apple, claude
    var id: String { rawValue }
    var label: String { self == .apple ? "Apple (on-device)" : "Claude" }
}

/// Shared prompt text so both AI providers behave the same way.
enum Prompts {
    static let themeInstructions = """
    You are an analyst who spots new initiatives in open-source and AI-built ("vibe-coded") projects.
    Group the numbered projects into 3 to 6 themes. For each theme give:
    - title: a short, specific name (max 6 words)
    - summary: two sentences on what people are building and why it matters
    - opportunities: 2 or 3 concrete suggestions, each one sentence, for extending these ideas or \
    building a differentiated version (a different audience, business model, platform, or missing feature)
    - item numbers: the numbers of the projects in the theme
    Put each project in at most one theme. Leave out projects that are noise or spam.
    """

    static let extensionInstructions = """
    You help a product owner turn a project they spotted into their own idea.
    Suggest 4 to 6 ways to extend it or make a differentiated version. Each suggestion is one or two \
    sentences and names who it is for and what makes it different. Be concrete and practical.
    """

    static func itemList(_ items: [FetchedItem], detailLimit: Int) -> String {
        items.enumerated().map { index, item in
            let detail = item.detail.isEmpty ? "" : " — " + String(item.detail.prefix(detailLimit))
            return "\(index + 1). [\(item.source.label)] \(item.title)\(detail)"
        }.joined(separator: "\n")
    }

    static func ideaText(_ idea: IdeaBrief) -> String {
        var text = "Project: \(idea.title)"
        if !idea.detail.isEmpty { text += "\nDescription: \(idea.detail)" }
        if !idea.note.isEmpty { text += "\nMy notes: \(idea.note)" }
        return text
    }
}

/// Turns AI drafts into clean themes: drops bad item numbers and duplicates,
/// and puts any unassigned items into a final "Other new projects" theme.
enum ThemeBuilder {
    struct Built: Equatable {
        var title: String
        var summary: String
        var opportunities: [String]
        var items: [FetchedItem]
    }

    static func assemble(_ drafts: [ThemeDraft], items: [FetchedItem]) -> [Built] {
        var used = Set<Int>()
        var built: [Built] = []
        for draft in drafts {
            let indices = draft.itemNumbers.map { $0 - 1 }.filter { items.indices.contains($0) && used.insert($0).inserted }
            guard !indices.isEmpty else { continue }
            built.append(Built(title: draft.title, summary: draft.summary,
                               opportunities: draft.opportunities, items: indices.map { items[$0] }))
        }
        let leftovers = items.indices.filter { !used.contains($0) }.map { items[$0] }
        if !leftovers.isEmpty {
            built.append(Built(title: "Other new projects", summary: "Projects that didn't fit a theme today.",
                               opportunities: [], items: leftovers))
        }
        return built
    }
}

/// Fallback when no AI is available: groups items by matching topic keyword.
struct KeywordSummarizer: Summarizer {
    let name = "Keywords"
    let maxItems = 60
    let topics: [String]

    func themes(for items: [FetchedItem]) async throws -> [ThemeDraft] {
        var drafts: [ThemeDraft] = []
        var used = Set<Int>()
        for topic in topics {
            let matches = items.indices.filter { i in
                !used.contains(i) && "\(items[i].title) \(items[i].detail)".localizedCaseInsensitiveContains(topic)
            }
            guard !matches.isEmpty else { continue }
            used.formUnion(matches)
            drafts.append(ThemeDraft(title: topic.capitalized, summary: "\(matches.count) projects mention “\(topic)”.",
                                     opportunities: [], itemNumbers: matches.map { $0 + 1 }))
        }
        return drafts
    }

    func extensions(for idea: IdeaBrief) async throws -> [String] {
        throw SummarizerError.unavailable
    }
}
