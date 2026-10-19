import Foundation
import SwiftData

/// Where an item came from.
enum SourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case github, hackerNews, productHunt, vibeCode, huggingFace, devTo, games

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
