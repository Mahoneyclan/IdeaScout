import Foundation
import SwiftData

/// Where an item came from.
enum SourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case github, hackerNews, productHunt, vibeCode, huggingFace, devTo, games, painPoints, ycombinator, appStore, research, lobsters

    var id: String { rawValue }

    var label: String {
        switch self {
        case .github: "GitHub"
        case .hackerNews: "Show HN"
        case .productHunt: "Product Hunt"
        case .vibeCode: "Vibe-coded"
        case .huggingFace: "Hugging Face"
        case .devTo: "DEV #showdev"
        case .games: "Games"
        case .painPoints: "Pain points"
        case .ycombinator: "Y Combinator"
        case .appStore: "App Store top paid"
        case .research: "AI research"
        case .lobsters: "Lobsters"
        }
    }

    var symbol: String {
        switch self {
        case .github: "chevron.left.forwardslash.chevron.right"
        case .hackerNews: "flame"
        case .productHunt: "cat"
        case .vibeCode: "wand.and.stars"
        case .huggingFace: "face.smiling"
        case .devTo: "text.bubble"
        case .games: "gamecontroller"
        case .painPoints: "exclamationmark.bubble"
        case .ycombinator: "building.columns"
        case .appStore: "bag"
        case .research: "doc.text.magnifyingglass"
        case .lobsters: "ladybug"
        }
    }

    /// Developer- and game-focused sources start switched off, so ideas lean towards business buyers.
    /// A toggle the user has set in Settings always wins.
    var enabledByDefault: Bool {
        switch self {
        case .games, .devTo, .lobsters, .huggingFace: false
        default: true
        }
    }
}

/// A raw item returned by a source fetcher, before it is stored.
struct FetchedItem: Equatable, Sendable {
    var key: String          // stable id, e.g. "hn-123", "gh-456"
    var source: SourceKind
    var title: String
    var detail: String
    var url: URL
    var score: Int           // stars / points / votes
    var postedAt: Date

    func isNew(now: Date = .now) -> Bool { postedAt > now.addingTimeInterval(-24 * 60 * 60) }
}

/// Ranking scores for a theme, each 1–5 (0 means not scored, e.g. keyword mode).
struct ThemeScores: Equatable, Sendable {
    var novelty = 0
    var momentum = 0
    var viability = 0
    var gap = 0

    /// Weighted average of the scores that exist and have a non-zero weight.
    func overall(_ w: RankWeights) -> Double? {
        let pairs = [(novelty, w.novelty), (momentum, w.momentum), (viability, w.viability), (gap, w.gap)]
            .filter { $0.0 > 0 && $0.1 > 0 }
        let total = pairs.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return nil }
        return pairs.reduce(0) { $0 + Double($1.0) * $1.1 } / total
    }
}

/// One-sentence explanations for each score.
struct ScoreReasons: Equatable, Sendable {
    var novelty = ""
    var momentum = ""
    var viability = ""
    var gap = ""
}

/// How much each score counts towards the overall rank (set in Settings).
struct RankWeights: Equatable, Sendable {
    var novelty = 1.0
    var momentum = 1.0
    var viability = 1.0
    var gap = 1.0
}

/// One day's digest.
@Model final class Digest {
    var day: Date
    var createdAt: Date
    var summarizer: String
    var warnings: [String] = []
    @Relationship(deleteRule: .cascade, inverse: \Theme.digest) var themes: [Theme] = []

    init(day: Date, summarizer: String, warnings: [String] = []) {
        self.day = day
        self.createdAt = .now
        self.summarizer = summarizer
        self.warnings = warnings
    }

    var sortedThemes: [Theme] { themes.sorted { $0.order < $1.order } }
    var itemCount: Int { themes.reduce(0) { $0 + $1.items.count } }
}

/// A group of related items with an AI summary and suggestions.
@Model final class Theme {
    var title: String
    var summary: String
    var order: Int
    /// Ways to extend the theme's ideas or build a differentiated version.
    var opportunities: [String] = []
    var novelty = 0
    var momentum = 0
    var viability = 0
    var opportunityGap = 0
    var noveltyReason = ""
    var momentumReason = ""
    var viabilityReason = ""
    var gapReason = ""
    /// The "Other new projects" bucket, always listed last.
    var isCatchAll = false
    var digest: Digest?
    @Relationship(deleteRule: .cascade, inverse: \Item.theme) var items: [Item] = []

    init(title: String, summary: String, order: Int, opportunities: [String]) {
        self.title = title
        self.summary = summary
        self.order = order
        self.opportunities = opportunities
    }

    var sortedItems: [Item] { items.sorted { $0.score > $1.score } }

    var scores: ThemeScores {
        ThemeScores(novelty: novelty, momentum: momentum, viability: viability, gap: opportunityGap)
    }

    var reasons: ScoreReasons {
        ScoreReasons(novelty: noveltyReason, momentum: momentumReason, viability: viabilityReason, gap: gapReason)
    }

    func apply(_ s: ThemeScores, _ r: ScoreReasons) {
        novelty = s.novelty; momentum = s.momentum; viability = s.viability; opportunityGap = s.gap
        noveltyReason = r.novelty; momentumReason = r.momentum; viabilityReason = r.viability; gapReason = r.gap
    }

    /// Whether the theme clears the quality bar. Unscored themes (keyword mode) always pass;
    /// the catch-all "Other projects" only shows when the bar is off.
    func clears(_ bar: Double, weights: RankWeights) -> Bool {
        if isCatchAll { return bar <= 0 }
        guard let overall = scores.overall(weights) else { return true }
        return overall >= bar
    }

    /// Ranked order: best overall score first, catch-all last.
    static func ranked(_ themes: [Theme], weights: RankWeights) -> [Theme] {
        themes.sorted { a, b in
            if a.isCatchAll != b.isCatchAll { return b.isCatchAll }
            let sa = a.scores.overall(weights) ?? 0, sb = b.scores.overall(weights) ?? 0
            return sa != sb ? sa > sb : a.order < b.order
        }
    }
}

/// A stored project/launch inside a theme.
@Model final class Item {
    var key: String
    var title: String
    var detail: String
    var urlString: String
    var sourceRaw: String
    var score: Int
    var postedAt: Date
    var theme: Theme?

    init(_ fetched: FetchedItem) {
        key = fetched.key
        title = fetched.title
        detail = fetched.detail
        urlString = fetched.url.absoluteString
        sourceRaw = fetched.source.rawValue
        score = fetched.score
        postedAt = fetched.postedAt
    }

    var source: SourceKind { SourceKind(rawValue: sourceRaw) ?? .github }
    var url: URL? { URL(string: urlString) }
    var isNew: Bool { postedAt > Date.now.addingTimeInterval(-24 * 60 * 60) }
}

/// A starred item, kept independently of digests so it survives refreshes.
@Model final class Idea {
    @Attribute(.unique) var key: String
    var title: String
    var detail: String
    var urlString: String
    var sourceRaw: String
    var note: String = ""
    var starredAt: Date
    /// AI-suggested extensions and differentiators.
    var extensions: [String] = []
    /// Scores of the theme the idea was saved from.
    var themeTitle = ""
    var novelty = 0
    var momentum = 0
    var viability = 0
    var opportunityGap = 0

    init(from item: Item) {
        key = item.key
        title = item.title
        detail = item.detail
        urlString = item.urlString
        sourceRaw = item.sourceRaw
        starredAt = .now
        if let theme = item.theme, !theme.isCatchAll {
            themeTitle = theme.title
            novelty = theme.novelty
            momentum = theme.momentum
            viability = theme.viability
            opportunityGap = theme.opportunityGap
        }
    }

    var scores: ThemeScores {
        ThemeScores(novelty: novelty, momentum: momentum, viability: viability, gap: opportunityGap)
    }

    var source: SourceKind { SourceKind(rawValue: sourceRaw) ?? .github }
    var url: URL? { URL(string: urlString) }
}

/// A synthesised product idea that survived the devil's-advocate check.
/// Kept across days: when the same idea comes back, it's updated and climbs the leaderboard.
@Model final class KillerIdea {
    @Attribute(.unique) var key: String
    var title: String
    var pitch: String
    var buyer: String
    var pricing: String
    var whyNow: String
    var oneWeekTest: String
    var replaces: String = ""   // the manual task or costly workaround the product replaces
    var objection: String
    var competitors: String
    var verdict: String
    var evidenceTitles: [String] = []
    var evidenceURLs: [String] = []
    // Scores 1–5 after the devil's-advocate review
    var pain = 0
    var willingToPay = 0
    var timing = 0
    var gap = 0
    var fit = 0
    var scoreHistory: [Double] = []
    var firstSeen: Date
    var lastSeen: Date
    var timesSeen = 1

    init(key: String, title: String) {
        self.key = key
        self.title = title
        pitch = ""; buyer = ""; pricing = ""; whyNow = ""; oneWeekTest = ""
        objection = ""; competitors = ""; verdict = ""
        firstSeen = .now
        lastSeen = .now
    }

    /// Average of the five review scores.
    var killerScore: Double {
        Double(pain + willingToPay + timing + gap + fit) / 5
    }

    /// Killer score plus a bonus for coming back on several days (up to +0.6).
    var leaderboardScore: Double { Self.leaderboardScore(killer: killerScore, timesSeen: timesSeen) }

    static func leaderboardScore(killer: Double, timesSeen: Int) -> Double {
        killer + Double(min(max(timesSeen - 1, 0), 4)) * 0.15
    }

    var isFromToday: Bool { Calendar.current.isDateInToday(lastSeen) }

    /// Today's ideas, best first; if there are none today, the single best idea from the last 7 days.
    static func bestToShow(_ ideas: [KillerIdea], now: Date = .now) -> [KillerIdea] {
        let byScore = ideas.sorted { $0.killerScore > $1.killerScore }
        let today = byScore.filter { Calendar.current.isDate($0.lastSeen, inSameDayAs: now) }
        if !today.isEmpty { return Array(today.prefix(KillerEngine.maxPerDay)) }
        let weekAgo = now.addingTimeInterval(-7 * 24 * 60 * 60)
        return Array(byScore.filter { $0.lastSeen >= weekAgo }.prefix(1))
    }

    var evidence: [(title: String, url: URL?)] {
        zip(evidenceTitles, evidenceURLs).map { ($0, URL(string: $1)) }
    }

    /// Normalised key so the same idea matches across days.
    static func key(for title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
