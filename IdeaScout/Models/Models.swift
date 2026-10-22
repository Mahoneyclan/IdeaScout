// Models.swift
// The app's data types. Plain value types (SourceKind, Signal, FetchedItem, scores) are used while a
// refresh runs; the SwiftData models (Digest → Theme → Item, plus Idea and KillerIdea) are what's saved
// on the iPhone and shown on screen.
//
// Ownership and deletion:
// - A Digest owns its Themes, and each Theme owns its Items (cascade delete): replacing or deleting a
//   day's digest removes its themes and items too.
// - Idea (a starred project) and KillerIdea are independent copies, so they survive when the digest
//   they came from is replaced or deleted.

import Foundation
import SwiftData

// MARK: - Sources and signals

/// Where an item came from. The raw value is stored in the database (`Item.sourceRaw`), so cases
/// must not be renamed; a removed case makes old items fall back to `.github` for display.
enum SourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case github, hackerNews, vibeCode, huggingFace, devTo, games, painPoints, ycombinator, appStore, research, lobsters
    case fieldNotes, appReviews, atlassian, ausTender

    /// Identity for SwiftUI lists.
    var id: String { rawValue }

    /// Name shown on screen and in the AI prompt tags (e.g. "[Demand · Pain points]"). The prompts refer
    /// to some labels by name, so change them together.
    var label: String {
        switch self {
        case .github: "GitHub"
        case .hackerNews: "Show HN"
        case .vibeCode: "Vibe-coded"
        case .huggingFace: "Hugging Face"
        case .devTo: "DEV #showdev"
        case .games: "Games"
        case .painPoints: "Pain points"
        case .ycombinator: "Y Combinator"
        case .appStore: "App Store top paid"
        case .research: "AI research"
        case .lobsters: "Lobsters"
        case .fieldNotes: "My business challenges"
        case .appReviews: "App Store complaints"
        case .atlassian: "Atlassian Marketplace"
        case .ausTender: "AusTender"
        }
    }

    /// SF Symbol shown next to the source.
    var symbol: String {
        switch self {
        case .github: "chevron.left.forwardslash.chevron.right"
        case .hackerNews: "flame"
        case .vibeCode: "wand.and.stars"
        case .huggingFace: "face.smiling"
        case .devTo: "text.bubble"
        case .games: "gamecontroller"
        case .painPoints: "exclamationmark.bubble"
        case .ycombinator: "building.columns"
        case .appStore: "bag"
        case .research: "doc.text.magnifyingglass"
        case .lobsters: "ladybug"
        case .fieldNotes: "note.text"
        case .appReviews: "star.slash"
        case .atlassian: "puzzlepiece.extension"
        case .ausTender: "building.2"
        }
    }

    /// What kind of evidence the source gives. Each kind gets a share of the items the AI reads,
    /// so builder-heavy sources can't crowd out evidence of demand.
    var signal: Signal {
        switch self {
        case .painPoints, .fieldNotes, .appReviews, .ausTender: .demand
        case .ycombinator, .research: .timing
        default: .supply
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

/// The three kinds of evidence. Demand is what buyers need or pay for (complaints, the user's own
/// challenges, government spending); supply is what's being built; timing is what's newly possible.
enum Signal: String, CaseIterable, Sendable {
    case demand, supply, timing

    /// "Demand", "Supply" or "Timing", used in prompts and Settings.
    var label: String { rawValue.capitalized }

    /// Share of the items the AI reads (40/40/20, the owner's choice to stop builder sources crowding
    /// out demand). Unused share rolls over, demand first (see DigestService.selectBySignal).
    var share: Double {
        switch self {
        case .demand: 0.4
        case .supply: 0.4
        case .timing: 0.2
        }
    }
}

// MARK: - Values used while building a digest

/// One post, listing, review or contract returned by a source fetcher, before it is stored.
/// Item numbers in AI prompts are 1-based positions in an array of these.
struct FetchedItem: Equatable, Sendable {
    var key: String          // stable id, e.g. "hn-123", "gh-456"; used to remove duplicates and match starred projects
    /// The source it came from.
    var source: SourceKind
    /// Headline. For comments and reviews, the most relevant snippet of the text.
    var title: String
    /// Supporting text (description, thread title, review body), already cleaned of HTML.
    var detail: String
    /// Link to the original.
    var url: URL
    var score: Int           // stars / points / votes (or rank, value in $k): higher = more traction; compared only within a source
    /// When it was posted. Sources without dates use the start of the window, so they never look "new".
    var postedAt: Date

    /// Whether it was posted in the last 24 hours (shown as NEW, and boosts momentum).
    func isNew(now: Date = .now) -> Bool { postedAt > now.addingTimeInterval(-24 * 60 * 60) }
}

/// Ranking scores for a theme, each 1–5 (0 means not scored, e.g. keyword mode).
struct ThemeScores: Equatable, Sendable {
    /// AI-judged: 1 = many products already do this, 5 = genuinely new.
    var novelty = 0
    /// Measured from traction and freshness, not judged by the AI (see Ranking.momentum).
    var momentum = 0
    /// AI-judged: could a small team build it and get paying customers?
    var viability = 0
    /// AI-judged: room for a differentiated product.
    var gap = 0

    /// Weighted average of the scores that exist and have a non-zero weight.
    /// - Parameter w: The user's ranking weights.
    /// - Returns: The overall score, or `nil` if nothing is scored (keyword mode) or every weight is 0.
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
    var momentum = 0
    var viability = 0
    var opportunityGap = 0
    /// One-sentence reasons for each score, shown when the user taps a trend's score.
    var noveltyReason = ""
    var momentumReason = ""
    var viabilityReason = ""
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

    /// Copies scores and reasons into the stored fields.
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

/// One stored post, listing, review or contract inside a theme. Belongs to one Theme (deleted with it).
/// Starring it copies it into an Idea so it outlives the digest. Fields mirror FetchedItem.
@Model final class Item {
    /// Stable ID from the source (see FetchedItem.key).
    var key: String
    var title: String
    var detail: String
    /// The original link, stored as text.
    var urlString: String
    /// SourceKind raw value; read through `source`.
    var sourceRaw: String
    var score: Int
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
    var title: String
    var detail: String
    var urlString: String
    var sourceRaw: String
    /// The user's own notes, included in variant suggestions and the "flesh out" prompt.
    var note: String = ""
    /// When it was starred (default sort order).
    var starredAt: Date
    /// AI-suggested extensions and differentiators.
    var extensions: [String] = []
    /// Title and scores of the trend it was starred from (empty for "Other projects"), copied at that time.
    var themeTitle = ""
    var novelty = 0
    var momentum = 0
    var viability = 0
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
    var replaces: String = ""   // the manual task or costly workaround the product replaces
    /// The devil's advocate's strongest objection.
    var objection: String
    /// Competitors named by the devil's advocate, or "none found".
    var competitors: String
    /// One-sentence verdict, plus "Evidence that would raise the score" when given.
    var verdict: String
    /// Titles and links of the items cited as evidence (parallel arrays; SwiftData stores arrays of plain values).
    var evidenceTitles: [String] = []
    var evidenceURLs: [String] = []
    // Scores 1–5 after the devil's-advocate review
    var pain = 0
    var willingToPay = 0
    var timing = 0
    var gap = 0
    var fit = 0
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

    /// +0.15 for each extra day it was proposed, up to 4 extra days (+0.6), so ideas that keep coming
    /// back rise without outranking a clearly stronger idea.
    static func leaderboardScore(killer: Double, timesSeen: Int) -> Double {
        killer + Double(min(max(timesSeen - 1, 0), 4)) * 0.15
    }

    /// Whether it was last proposed today.
    var isFromToday: Bool { Calendar.current.isDateInToday(lastSeen) }

    /// Whether the idea was proposed on the given day. Ideas saved before days were recorded
    /// fall back to their first and last day.
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
    static func seen(on day: Date, in ideas: [KillerIdea]) -> [KillerIdea] {
        ideas.filter { $0.wasSeen(on: day) }.sorted { $0.killerScore > $1.killerScore }
    }

    /// The evidence as title and link pairs.
    var evidence: [(title: String, url: URL?)] {
        zip(evidenceTitles, evidenceURLs).map { ($0, URL(string: $1)) }
    }

    /// Normalised key so the same idea matches across days: lowercase letters and digits only.
    static func key(for title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
