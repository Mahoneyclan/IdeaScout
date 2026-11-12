// StoredModels.swift
// The SwiftData models saved on the device, synced through the user's own iCloud between their devices, and shown on
// screen. iCloud sync needs every field to have a default, every relationship to be optional, and no unique fields.
//
// Ownership and deletion:
// - A Digest owns its Themes, and each Theme owns its Items (cascade delete): replacing or deleting a
//   day's digest removes its themes and items too.
// - Idea (a starred project) and KillerIdea (in KillerIdea.swift) are independent copies, so they survive when the digest
//   they came from is replaced or deleted.

import Foundation
import SwiftData

// MARK: - Stored models (SwiftData)

/// One day's results: the themes and pain clusters built by one refresh. At most one per day; a
/// later refresh replaces it (unless the new one is weaker, see DigestService.shouldReplace).
/// Deleting a digest deletes its themes and their items.
@Model final class Digest {
    /// Start of the day the digest is for (used to find "today's" digest and to match ideas to days).
    var day: Date = Date.now
    /// When the refresh finished saving it (shown as "Updated 7:02 am").
    var createdAt: Date = Date.now
    /// Which AI built it ("Claude", "Apple on-device", "Keywords"…), used to rank digests.
    var summarizer: String = ""
    /// Notes about the refresh, shown to the user (source failures, limit reached, no ideas…).
    var warnings: [String] = []
    /// The day's themes, pain clusters and "Other projects". Deleted with the digest. Optional because iCloud sync
    /// requires it; read through `themeList`.
    @Relationship(deleteRule: .cascade, inverse: \Theme.digest) var themes: [Theme]? = []

    /// Creates a digest stamped with the current time.
    /// - Parameters:
    ///   - day: Start of the day it belongs to.
    ///   - summarizer: Name of the AI that built it.
    ///   - warnings: Notes about the refresh, if already known.
    init(day: Date, summarizer: String, warnings: [String] = []) {
        self.day = day
        self.createdAt = .now
        self.summarizer = summarizer
        self.warnings = warnings
    }

    /// Themes in the order the AI returned them (catch-all last).
    var sortedThemes: [Theme] { themeList.sorted { $0.order < $1.order } }
    /// The themes (none until they've synced).
    var themeList: [Theme] { themes ?? [] }
    /// Total items across all themes.
    var itemCount: Int { themeList.reduce(0) { $0 + $1.itemList.count } }
}

/// A group of items in one digest: a trend (things being built), a pain cluster (complaints from one
/// type of buyer), or the "Other projects" catch-all. Belongs to one Digest; owns its Items.
@Model final class Theme {
    /// Short name, from the AI.
    var title: String = ""
    /// One or two sentences, from the AI.
    var summary: String = ""
    /// Position in the AI's reply, used as a tie-breaker when ranking.
    var order: Int = 0
    /// Ways to extend the theme's ideas or build a differentiated version.
    var opportunities: [String] = []
    /// Scores 1–5 (0 = not scored): see ThemeScores. Stored as separate fields because SwiftData stores
    /// plain values.
    var novelty = 0
    /// Measured momentum (1–5).
    var momentum = 0
    /// AI-judged viability (1–5).
    var viability = 0
    /// AI-judged opportunity gap (1–5).
    var opportunityGap = 0
    /// One-sentence reasons for each score, shown when the user taps a trend's score.
    var noveltyReason = ""
    /// How momentum was measured.
    var momentumReason = ""
    /// Reason for the viability score.
    var viabilityReason = ""
    /// Reason for the opportunity gap score.
    var gapReason = ""
    /// The "Other projects" bucket for items not in any trend or cluster, always listed last.
    var isCatchAll = false
    /// A cluster of complaints (one problem, one buyer) rather than a trend of things being built.
    var isPainCluster = false
    /// Pain clusters only: who has the problem.
    var buyer = ""
    /// Pain clusters only: what they do today instead.
    var workaround = ""
    /// Pain clusters only: any sign they pay or would pay, or "none seen".
    var paySignals = ""
    /// The digest this theme belongs to.
    var digest: Digest?
    /// The items in this theme. Deleted with the theme. Optional because iCloud sync requires it; read through `itemList`.
    @Relationship(deleteRule: .cascade, inverse: \Item.theme) var items: [Item]? = []

    /// Creates a theme; scores and cluster fields are set afterwards.
    /// - Parameters:
    ///   - title: Short name.
    ///   - summary: One or two sentences.
    ///   - order: Position in the AI's reply (catch-all last).
    ///   - opportunities: Money-making variants (empty for clusters).
    init(title: String, summary: String, order: Int, opportunities: [String]) {
        self.title = title
        self.summary = summary
        self.order = order
        self.opportunities = opportunities
    }

    /// Items with the most traction first.
    var sortedItems: [Item] { itemList.sorted { $0.score > $1.score } }
    /// The items (none until they've synced).
    var itemList: [Item] { items ?? [] }

    /// The four scores as one value.
    var scores: ThemeScores {
        ThemeScores(novelty: novelty, momentum: momentum, viability: viability, gap: opportunityGap)
    }

    /// The four reasons as one value.
    var reasons: ScoreReasons {
        ScoreReasons(novelty: noveltyReason, momentum: momentumReason, viability: viabilityReason, gap: gapReason)
    }

    /// Copies scores and reasons into the stored fields. The caller saves the database.
    /// - Parameters:
    ///   - s: The four scores.
    ///   - r: The four reasons.
    func apply(_ s: ThemeScores, _ r: ScoreReasons) {
        novelty = s.novelty; momentum = s.momentum; viability = s.viability; opportunityGap = s.gap
        noveltyReason = r.novelty; momentumReason = r.momentum; viabilityReason = r.viability; gapReason = r.gap
    }

    /// Whether the theme clears the quality bar. Unscored themes (keyword mode) always pass;
    /// the catch-all "Other projects" only shows when the bar is off.
    /// - Parameters:
    ///   - bar: The quality bar (0 = off).
    ///   - weights: The user's score weights.
    /// - Returns: `true` if the theme should be shown.
    func clears(_ bar: Double, weights: RankWeights) -> Bool {
        if isCatchAll { return bar <= 0 }
        guard let overall = scores.overall(weights) else { return true }
        return overall >= bar
    }

    /// Ranked order: best overall score first, catch-all last; ties keep the AI's order.
    /// - Parameters:
    ///   - themes: The themes to sort.
    ///   - weights: The user's score weights.
    /// - Returns: The themes in display order.
    static func ranked(_ themes: [Theme], weights: RankWeights) -> [Theme] {
        themes.sorted { a, b in
            if a.isCatchAll != b.isCatchAll { return b.isCatchAll }
            let sa = a.scores.overall(weights) ?? 0, sb = b.scores.overall(weights) ?? 0
            return sa != sb ? sa > sb : a.order < b.order
        }
    }
}

/// One stored post, listing, review or contract inside a theme. Belongs to one Theme (deleted with it).
/// Starring it copies it into an Idea so it outlives the digest. Fields mirror FetchedItem.
@Model final class Item {
    /// Stable ID from the source (see FetchedItem.key).
    var key: String = ""
    /// Headline (see FetchedItem.title).
    var title: String = ""
    /// Supporting text.
    var detail: String = ""
    /// The original link, stored as text.
    var urlString: String = ""
    /// SourceKind raw value; read through `source`.
    var sourceRaw: String = ""
    /// Traction within its source (see FetchedItem.score).
    var score: Int = 0
    /// When it was posted.
    var postedAt: Date = Date.now
    /// The theme this item belongs to.
    var theme: Theme?

    /// Stores a fetched item.
    init(_ fetched: FetchedItem) {
        key = fetched.key
        title = fetched.title
        detail = fetched.detail
        urlString = fetched.url.absoluteString
        sourceRaw = fetched.source.rawValue
        score = fetched.score
        postedAt = fetched.postedAt
    }

    /// The source; unknown values (removed sources) show as GitHub.
    var source: SourceKind { SourceKind(rawValue: sourceRaw) ?? .github }
    /// The original link, if it parses.
    var url: URL? { URL(string: urlString) }
    /// Posted in the last 24 hours.
    var isNew: Bool { postedAt > Date.now.addingTimeInterval(-24 * 60 * 60) }
}

/// A starred project ("Saved projects" in the Saved tab): a copy of an Item, independent of digests so it
/// survives refreshes. The user can add notes and ask the AI for money-making variants.
@Model final class Idea {
    /// The starred item's key. Not marked unique, because iCloud sync can't enforce that: duplicates from two devices
    /// are merged by `SyncHousekeeping`.
    var key: String = ""
    /// The project's title.
    var title: String = ""
    /// Its description.
    var detail: String = ""
    /// Link to the original.
    var urlString: String = ""
    /// SourceKind raw value; read through `source`.
    var sourceRaw: String = ""
    /// The user's own notes, included in variant suggestions and the "flesh out" prompt.
    var note: String = ""
    /// When it was starred (default sort order).
    var starredAt: Date = Date.now
    /// AI-suggested extensions and differentiators.
    var extensions: [String] = []
    /// Title and scores of the trend it was starred from (empty for "Other projects"), copied at that time.
    var themeTitle = ""
    /// Copied trend scores (see Theme).
    var novelty = 0
    /// Copied momentum.
    var momentum = 0
    /// Copied viability.
    var viability = 0
    /// Copied opportunity gap.
    var opportunityGap = 0

    /// Copies an item and, if it was in a real trend, that trend's title and scores.
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

    /// The copied trend scores as one value.
    var scores: ThemeScores {
        ThemeScores(novelty: novelty, momentum: momentum, viability: viability, gap: opportunityGap)
    }

    /// The source; unknown values (removed sources) show as GitHub.
    var source: SourceKind { SourceKind(rawValue: sourceRaw) ?? .github }
    /// The original link, if it parses.
    var url: URL? { URL(string: urlString) }
}
