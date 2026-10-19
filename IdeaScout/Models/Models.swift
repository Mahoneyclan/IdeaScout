import Foundation
import SwiftData

/// Where an item came from.
enum SourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case github, hackerNews, productHunt, vibeCode

    var id: String { rawValue }

    var label: String {
        switch self {
        case .github: "GitHub"
        case .hackerNews: "Show HN"
        case .productHunt: "Product Hunt"
        case .vibeCode: "Vibe-coded"
        }
    }

    var symbol: String {
        switch self {
        case .github: "chevron.left.forwardslash.chevron.right"
        case .hackerNews: "flame"
        case .productHunt: "cat"
        case .vibeCode: "wand.and.stars"
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
    var digest: Digest?
    @Relationship(deleteRule: .cascade, inverse: \Item.theme) var items: [Item] = []

    init(title: String, summary: String, order: Int, opportunities: [String]) {
        self.title = title
        self.summary = summary
        self.order = order
        self.opportunities = opportunities
    }

    var sortedItems: [Item] { items.sorted { $0.score > $1.score } }
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

    init(from item: Item) {
        key = item.key
        title = item.title
        detail = item.detail
        urlString = item.urlString
        sourceRaw = item.sourceRaw
        starredAt = .now
    }

    var source: SourceKind { SourceKind(rawValue: sourceRaw) ?? .github }
    var url: URL? { URL(string: urlString) }
}
