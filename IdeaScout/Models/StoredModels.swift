// StoredModels.swift
// The SwiftData models saved on the iPhone and shown on screen.
//
// Ownership and deletion:
// - A Digest owns its Themes, and each Theme owns its Items (cascade delete): replacing or deleting a
//   day's digest removes its themes and items too.
// - Idea (a starred project) and KillerIdea are independent copies, so they survive when the digest
//   they came from is replaced or deleted.

import Foundation
import SwiftData

// MARK: - Stored models (SwiftData)

/// One day's results: the themes and pain clusters built by one refresh. At most one per day; a
/// later refresh replaces it (unless the new one is weaker, see DigestService.shouldReplace).
/// Deleting a digest deletes its themes and their items.
@Model final class Digest {
    /// Start of the day the digest is for (used to find "today's" digest and to match ideas to days).
    var day: Date
    /// When the refresh finished saving it (shown as "Updated 7:02 am").
    var createdAt: Date
    /// Which AI built it ("Claude", "Apple on-device", "Keywords"…), used to rank digests.
    var summarizer: String
    /// Notes about the refresh, shown to the user (source failures, limit reached, no ideas…).
    var warnings: [String] = []
    /// The day's themes, pain clusters and "Other projects". Deleted with the digest.
    @Relationship(deleteRule: .cascade, inverse: \Theme.digest) var themes: [Theme] = []

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
    var sortedThemes: [Theme] { themes.sorted { $0.order < $1.order } }
    /// Total items across all themes.
    var itemCount: Int { themes.reduce(0) { $0 + $1.items.count } }
}

/// A group of items in one digest: a trend (things being built), a pain cluster (complaints from one
/// type of buyer), or the "Other projects" catch-all. Belongs to one Digest; owns its Items.
@Model final class Theme {
    /// Short name, from the AI.
    var title: String
    /// One or two sentences, from the AI.
    var summary: String
    /// Position in the AI's reply, used as a tie-breaker when ranking.
    var order: Int
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
    /// The items in this theme. Deleted with the theme.
    @Relationship(deleteRule: .cascade, inverse: \Item.theme) var items: [Item] = []

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
    var sortedItems: [Item] { items.sorted { $0.score > $1.score } }

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
    var key: String
    /// Headline (see FetchedItem.title).
    var title: String
    /// Supporting text.
    var detail: String
    /// The original link, stored as text.
    var urlString: String
    /// SourceKind raw value; read through `source`.
    var sourceRaw: String
    /// Traction within its source (see FetchedItem.score).
    var score: Int
    /// When it was posted.
    var postedAt: Date
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
    /// The starred item's key; unique, so starring twice can't create duplicates.
    @Attribute(.unique) var key: String
    /// The project's title.
    var title: String
    /// Its description.
    var detail: String
    /// Link to the original.
    var urlString: String
    /// SourceKind raw value; read through `source`.
    var sourceRaw: String
    /// The user's own notes, included in variant suggestions and the "flesh out" prompt.
    var note: String = ""
    /// When it was starred (default sort order).
    var starredAt: Date
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

/// A business product idea proposed by the AI that survived the devil's-advocate check (shown as Killer or
/// Near-miss). Independent of digests.
/// Kept across days: when the same idea comes back, it's updated and climbs the leaderboard.
@Model final class KillerIdea {
    /// Normalised title (see `key(for:)`), so the same idea on another day updates this record.
    @Attribute(.unique) var key: String
    /// Short, memorable name, as the AI wrote it.
    var title: String
    /// One-sentence pitch.
    var pitch: String
    /// Who pays: a role in a type of business.
    var buyer: String
    /// Pricing model and monthly price per customer.
    var pricing: String
    /// What recently made it possible.
    var whyNow: String
    /// The cheapest way to test demand in a week, with a pass mark.
    var oneWeekTest: String
    /// The manual task or costly workaround the product replaces.
    var replaces: String = ""
    /// Where a solo builder would find the first buyers (a marketplace, community or search phrase); empty
    /// for ideas found before sales channels were asked for.
    var channel: String = ""
    /// The devil's advocate's strongest objection.
    var objection: String
    /// Competitors named by the devil's advocate, or "none found".
    var competitors: String
    /// One-sentence verdict, plus "Evidence that would raise the score" when given.
    var verdict: String
    /// Titles and links of the items cited as evidence (parallel arrays; SwiftData stores arrays of plain values).
    var evidenceTitles: [String] = []
    /// Links matching `evidenceTitles`, by position.
    var evidenceURLs: [String] = []
    // Scores 1–5 after the devil's-advocate review
    /// How badly the buyer needs it.
    var pain = 0
    /// How likely the buyer is to pay the stated price.
    var willingToPay = 0
    /// How strongly "why now" holds.
    var timing = 0
    /// How open the market is after competitors.
    var gap = 0
    /// How well it suits the user (from About me).
    var fit = 0
    /// Whether one person with AI coding tools could build a first version in about 4 weeks.
    /// 0 means not scored (ideas found before this score existed).
    var buildability = 0
    /// How reachable the buyers are through the sales channel without a sales team. 0 means not scored.
    var channelScore = 0
    /// The killer score each time the idea was proposed.
    var scoreHistory: [Double] = []
    /// When it was first proposed.
    var firstSeen: Date
    /// When it was last proposed.
    var lastSeen: Date
    /// On how many different days it was proposed; adds a leaderboard bonus.
    var timesSeen = 1
    /// Start of each day the idea was proposed.
    var daysSeen: [Date] = []
    /// Bookmarked by the user: listed in the Saved tab, and kept even if dismissed from the leaderboard.
    var isSaved = false
    /// When it was saved (Saved tab order), or `nil`.
    var savedAt: Date?
    /// Hidden from the leaderboard by the user. Cleared if the idea is proposed again.
    var isDismissed = false

    /// Saves or unsaves the idea. The caller saves the database.
    func toggleSaved() {
        isSaved.toggle()
        savedAt = isSaved ? .now : nil
    }

    /// Creates an empty idea; DigestService fills in the rest from the AI's reply.
    /// - Parameters:
    ///   - key: `KillerIdea.key(for: title)`; unique, so the same idea matches across days.
    ///   - title: The AI's title.
    init(key: String, title: String) {
        self.key = key
        self.title = title
        pitch = ""; buyer = ""; pricing = ""; whyNow = ""; oneWeekTest = ""
        objection = ""; competitors = ""; verdict = ""
        firstSeen = .now
        lastSeen = .now
    }

    /// The weighted killer score of the review scores.
    var killerScore: Double {
        Self.killerScore(pain: pain, willingToPay: willingToPay, timing: timing, gap: gap, fit: fit,
                         buildability: buildability, channel: channelScore)
    }

    /// "Why now" counts half as much as the other scores: for a solo builder using AI tools, "AI makes it
    /// cheap to build" is true of almost every idea, so timing separates ideas less than buildability or a sales channel.
    static let timingWeight = 0.5

    /// The killer score: the single source of the weighting, used by `KillerEngine` and on screen.
    /// - Parameters:
    ///   - pain: 0–5. Each other parameter is a 0–5 review score with the same name.
    ///   - buildability: 0–5; 0 together with `channel` 0 means an older idea scored before these existed.
    ///   - channel: 0–5, the sales-channel score.
    /// - Returns: 0–5. Older ideas keep their original score (the plain average of the first five), so they
    ///   aren't marked down for scores they were never given.
    static func killerScore(pain: Int, willingToPay: Int, timing: Int, gap: Int, fit: Int,
                            buildability: Int, channel: Int) -> Double {
        guard buildability > 0 || channel > 0 else { return Double(pain + willingToPay + timing + gap + fit) / 5 }
        let total = Double(pain + willingToPay + gap + fit + buildability + channel) + Double(timing) * timingWeight
        return total / (6 + timingWeight)
    }

    /// Killer score plus a bonus for coming back on several days (up to +0.6).
    var leaderboardScore: Double { Self.leaderboardScore(killer: killerScore, timesSeen: timesSeen) }

    /// +0.15 for each extra day it was proposed, up to 4 extra days (+0.6), so ideas that keep coming
    /// back rise without outranking a clearly stronger idea.
    /// - Parameters:
    ///   - killer: The killer score (0–5).
    ///   - timesSeen: Days it has been proposed (1 or more).
    /// - Returns: The leaderboard score (0–5.6).
    static func leaderboardScore(killer: Double, timesSeen: Int) -> Double {
        killer + Double(min(max(timesSeen - 1, 0), 4)) * 0.15
    }

    /// Whether the idea was proposed on the given day. Ideas saved before days were recorded
    /// fall back to their first and last day.
    /// - Parameter day: Any moment in the day to check, in the phone's calendar.
    /// - Returns: `true` if it was proposed that day.
    func wasSeen(on day: Date) -> Bool {
        let calendar = Calendar.current
        if !daysSeen.isEmpty { return daysSeen.contains { calendar.isDate($0, inSameDayAs: day) } }
        return calendar.isDate(firstSeen, inSameDayAs: day) || calendar.isDate(lastSeen, inSameDayAs: day)
    }

    /// Adds the day (once) to the days this idea was seen.
    func recordSeen(on date: Date = .now) {
        let day = Calendar.current.startOfDay(for: date)
        if daysSeen.isEmpty {
            // Carry over what's known from before days were recorded (call before updating lastSeen).
            daysSeen = Array(Set([firstSeen, lastSeen].map { Calendar.current.startOfDay(for: $0) })).sorted()
        }
        if !daysSeen.contains(day) { daysSeen.append(day) }
    }

    /// Ideas proposed on a given day, best first.
    /// - Parameters:
    ///   - day: Any moment in the day.
    ///   - ideas: The ideas to filter.
    /// - Returns: The matching ideas, highest killer score first.
    static func seen(on day: Date, in ideas: [KillerIdea]) -> [KillerIdea] {
        ideas.filter { $0.wasSeen(on: day) }.sorted { $0.killerScore > $1.killerScore }
    }

    /// The evidence as title and link pairs.
    var evidence: [(title: String, url: URL?)] {
        zip(evidenceTitles, evidenceURLs).map { ($0, URL(string: $1)) }
    }

    /// Normalised key so the same idea matches across days: lowercase letters and digits only.
    /// - Parameter title: The AI's title.
    /// - Returns: The key; empty if the title has no letters or digits.
    static func key(for title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
