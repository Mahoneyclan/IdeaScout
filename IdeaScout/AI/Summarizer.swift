import Foundation
import NaturalLanguage

/// A theme as proposed by a summariser, before it is matched to stored items.
struct ThemeDraft: Equatable, Sendable {
    var title: String
    var summary: String
    var opportunities: [String]
    var itemNumbers: [Int]   // 1-based positions in the prompt's item list
    // AI ranking scores, 1–5 (0 = not scored). Momentum is calculated from real numbers instead.
    var novelty = 0
    var viability = 0
    var gap = 0
    var reasons = ScoreReasons()
    // Pain clusters (Claude only): one problem, one buyer, built from demand items.
    var isPainCluster = false
    var buyer = ""
    var workaround = ""
    var paySignals = ""
}

/// Everything a summariser returns for one refresh.
struct Analysis: Sendable {
    var drafts: [ThemeDraft]
    var translations: [Int: Translation] = [:]
    /// 1-based numbers of items the AI judged to be noise; they're left out of "Other projects".
    var noise: Set<Int> = []
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
    /// Themes plus, where supported, pain clusters, English translations and noise.
    func analyse(_ items: [FetchedItem]) async throws -> Analysis
    func extensions(for idea: IdeaBrief) async throws -> [String]
}

struct Translation: Equatable, Sendable {
    var title: String
    var detail: String
}

extension Summarizer {
    /// Summarisers that can't translate or cluster return themes only.
    func analyse(_ items: [FetchedItem]) async throws -> Analysis {
        Analysis(drafts: try await themes(for: items))
    }
}

enum Translations {
    /// Replaces non-English titles and descriptions with their translations.
    static func apply(_ translations: [Int: Translation], to items: [FetchedItem]) -> [FetchedItem] {
        var items = items
        for (number, t) in translations where items.indices.contains(number - 1) && !t.title.isEmpty {
            items[number - 1].title = t.title
            if !t.detail.isEmpty { items[number - 1].detail = t.detail }
        }
        return items
    }
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

/// Shared prompt text so both AI providers behave the same way.
enum Prompts {
    static let themeInstructions = """
    You are an analyst who spots new business software opportunities in recent launches, startups and complaints.
    The numbered projects were launched or gained traction recently; "new" marks the last 24 hours. \
    Items tagged "Pain points" are people complaining or asking for tools that don't exist, "App Store complaints" \
    are 1-2 star reviews of business apps people pay for, "AusTender" is Australian government IT spending and \
    "My business challenges" are the user's own observations from work: use them as evidence of demand \
    inside related themes rather than as themes of their own. Items tagged "Y Combinator" are business startups investors \
    just funded and "App Store top paid" are apps people pay for: treat both as evidence that a market pays. \
    Favour trends that businesses would pay for over developer tools and consumer novelties. \
    Items tagged "AI research" are new capabilities: use them to explain why an idea is possible now.
    First ignore projects that could never become a product people pay for (libraries with no product angle, \
    lists, coursework, personal sites, jokes). Then group the rest into 4 to 6 themes. A theme is a trend: \
    several projects attacking the same problem or using the same new capability. Aim for at least 3 projects \
    per theme; don't create a theme for a single project. Avoid generic names like "AI-powered tools".
    Group games by shared genre, mechanic or audience (e.g. "cosy restoration sims"), not just "games"; \
    their monetisable variants can include premium, free-to-play, ports, sequels, or tools for game makers.
    For each theme give:
    - title: a short, specific name (max 6 words)
    - summary: two sentences on what people are building and why it matters
    - opportunities: 2 or 3 monetisable extensions or variants of these ideas. Each is one or two sentences \
    saying what the product is, who pays for it, how it makes money (e.g. subscription, usage-based, \
    one-off purchase, marketplace fee, B2B licence) and why it is different from what exists
    - item numbers: the numbers of the projects in the theme
    - novelty (1-5): 1 = many existing products already do this, 5 = a genuinely new approach
    - viability (1-5): could a small team build it and get paying business customers? 1 = unrealistic, 5 = clearly buildable and sellable
    - opportunity gap (1-5): room for a differentiated version? 1 = crowded or solved, 5 = obvious unmet need
    - a one-sentence reason for each of the three scores
    Be critical and use the full range of scores; most themes should land between 2 and 4.
    Put each project in at most one theme. Leave out projects that are noise or spam.
    Write everything in English.
    """

    static let extensionInstructions = """
    You help a product owner turn a project they spotted into their own idea.
    Suggest 4 to 6 monetisable extensions or variants of it. Each suggestion is one or two sentences \
    and says: what the product is, who pays, how it makes money (e.g. subscription, usage-based, \
    one-off purchase, marketplace fee, B2B licence) and what makes it different. Only suggest ideas \
    someone would realistically pay for. Be concrete and practical. Write in English.
    """

    /// A ready-to-paste prompt for Claude, ChatGPT, Lovable, Bolt etc. to turn a saved idea into a product brief.
    static func fleshOut(_ idea: Idea) -> String {
        var lines = ["Act as an experienced product strategist. Flesh out this product idea.", ""]
        lines.append("Idea: \(idea.title)")
        if !idea.detail.isEmpty { lines.append("Description: \(idea.detail)") }
        var origin = "Inspired by: \(idea.title) (\(idea.source.label))"
        if !idea.urlString.isEmpty { origin += " \(idea.urlString)" }
        lines.append(origin)
        if !idea.themeTitle.isEmpty { lines.append("Trend it belongs to: \(idea.themeTitle)") }
        if !idea.note.isEmpty { lines.append("My angle / notes: \(idea.note)") }
        let s = idea.scores
        let scored = [("Novelty", s.novelty), ("Momentum", s.momentum), ("Viability", s.viability), ("Opportunity gap", s.gap)]
            .filter { $0.1 > 0 }.map { "\($0.0) \($0.1)/5" }
        if !scored.isEmpty { lines.append("Scores: " + scored.joined(separator: ", ")) }
        if !idea.extensions.isEmpty {
            lines.append("Possible extensions and differentiators:")
            lines += idea.extensions.map { "- \($0)" }
        }
        lines += [
            "",
            "Please produce:",
            "1. The problem, in one paragraph",
            "2. Target users, and the single best first audience",
            "3. Core features for a minimum viable product (MVP), and what to leave out",
            "4. How it differs from what already exists, including the original project",
            "5. Business model and pricing",
            "6. Main risks and how to test them cheaply",
            "7. The next three concrete steps",
            "",
            "Be specific and practical. Ask me up to three questions first if anything important is unclear.",
        ]
        return lines.joined(separator: "\n")
    }

    /// One line per item, tagged with its signal and source. Demand items (complaints) keep more text,
    /// since the useful part is often deep in the comment; supply items keep less.
    static func itemList(_ items: [FetchedItem], detailLimit: Int, now: Date = .now) -> String {
        items.enumerated().map { index, item in
            let limit = switch item.source.signal {
            case .demand: max(detailLimit, 300)
            case .supply: min(detailLimit, 140)
            case .timing: detailLimit
            }
            let detail = item.detail.isEmpty ? "" : " — " + String(item.detail.prefix(limit))
            var tags = ["\(item.source.signal.label) · \(item.source.label)"]
            if item.score > 0 { tags.append("score \(item.score)") }
            if item.isNew(now: now) { tags.append("new") }
            return "\(index + 1). [\(tags.joined(separator: ", "))] \(item.title)\(detail)"
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
        var scores = ThemeScores()
        var reasons = ScoreReasons()
        var isCatchAll = false
        var isPainCluster = false
        var buyer = ""
        var workaround = ""
        var paySignals = ""
    }

    /// `noise`: 1-based item numbers to leave out of "Other projects" (they can still be in a theme).
    static func assemble(_ drafts: [ThemeDraft], items: [FetchedItem], noise: Set<Int> = []) -> [Built] {
        var used = Set<Int>()
        var built: [Built] = []
        for draft in drafts {
            let indices = draft.itemNumbers.map { $0 - 1 }.filter { items.indices.contains($0) && used.insert($0).inserted }
            guard !indices.isEmpty else { continue }
            let members = indices.map { items[$0] }
            if draft.isPainCluster {
                built.append(Built(title: draft.title, summary: draft.summary, opportunities: [], items: members,
                                   isPainCluster: true, buyer: draft.buyer, workaround: draft.workaround,
                                   paySignals: draft.paySignals))
                continue
            }
            let momentum = Ranking.momentum(of: members, among: items)
            var reasons = draft.reasons
            reasons.momentum = momentum.reason
            built.append(Built(title: draft.title, summary: draft.summary, opportunities: draft.opportunities,
                               items: members,
                               scores: ThemeScores(novelty: Ranking.clamp(draft.novelty), momentum: momentum.score,
                                                   viability: Ranking.clamp(draft.viability), gap: Ranking.clamp(draft.gap)),
                               reasons: reasons))
        }
        let leftovers = items.indices.filter { !used.contains($0) && !noise.contains($0 + 1) }.map { items[$0] }
        if !leftovers.isEmpty {
            built.append(Built(title: "Other projects", summary: "Projects that didn't fit a trend this week.",
                               opportunities: [], items: leftovers, isCatchAll: true))
        }
        return built
    }
}

/// Momentum is measured from real traction numbers, not judged by the AI,
/// so the ranking isn't driven purely by what sounds exciting.
enum Ranking {
    static func clamp(_ score: Int) -> Int { score <= 0 ? 0 : min(score, 5) }

    /// 1–5 from how highly the theme's projects rank within their own source
    /// (stars, points and votes aren't comparable across sources) and how many projects share the theme.
    static func momentum(of members: [FetchedItem], among all: [FetchedItem], now: Date = .now) -> (score: Int, reason: String) {
        guard !members.isEmpty else { return (0, "") }
        let rank = members.map { percentile(of: $0, among: all) }.reduce(0, +) / Double(members.count)
        let size = min(1, Double(members.count) / 8)
        let fresh = Double(members.filter { $0.postedAt > now.addingTimeInterval(-48 * 60 * 60) }.count) / Double(members.count)
        let score = 1 + Int((4 * (0.5 * rank + 0.3 * size + 0.2 * fresh)).rounded())
        let top = max(1, Int(((1 - rank) * 100).rounded()))
        let projects = members.count == 1 ? "1 project" : "\(members.count) projects"
        let recent = Int((fresh * 100).rounded())
        return (score, "\(projects) this week, on average in the top \(top)% of their source; \(recent)% appeared in the last 2 days.")
    }

    /// 0 (lowest score in its source) to 1 (highest).
    static func percentile(of item: FetchedItem, among all: [FetchedItem]) -> Double {
        let peers = all.filter { $0.source == item.source }
        guard peers.count > 1 else { return 0.5 }
        return Double(peers.filter { $0.score < item.score }.count) / Double(peers.count - 1)
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

/// Used when no AI can translate: drops items that are clearly not in English.
/// Short or ambiguous text (e.g. a product name) is kept.
enum LanguageFilter {
    static func isEnglishOrUnclear(_ item: FetchedItem) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString("\(item.title) \(item.detail)")
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first else { return true }
        return language == .english || confidence < 0.8
    }
}
