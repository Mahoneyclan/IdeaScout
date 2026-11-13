// Values.swift
// Plain value types used while a refresh runs and across the app: sources and their signal (demand,
// supply, timing), fetched items, theme scores and weights, stored-warning format, and the safe-link rule.
// The saved SwiftData models are in StoredModels.swift.

import Foundation

// MARK: - Sources and signals

/// Where an item came from. The raw value is stored in the database (`Item.sourceRaw`), so cases
/// must not be renamed; a removed case makes old items fall back to `.github` for display.
enum SourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The first eleven sources. Each one's display name and signal are in `label` and `signal`.
    case github, hackerNews, vibeCode, huggingFace, devTo, games, painPoints, ycombinator, appStore, research, lobsters
    /// Business sources added later: My pain points (first called My Business Challenges), App Store complaints, Atlassian Marketplace and AusTender.
    case fieldNotes, appReviews, atlassian, ausTender
    /// Consumer source (10 Nov 2026): 1–2 star reviews of top-grossing consumer apps.
    case consumerReviews
    /// Hacker News stories and comments found by searching the user's interest area (13 Nov 2026).
    case areaDiscussion
    /// Evidence found by "Undercut an app"'s web research (13 Nov 2026), never by a scan: complaints about the app
    /// and its rivals, and the paid plans people buy.
    case webComplaints, webPaying

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
        case .fieldNotes: "My pain points"
        case .appReviews: "App Store complaints"
        case .consumerReviews: "Consumer app complaints"
        case .areaDiscussion: "Hacker News on your area"
        case .webComplaints: "Complaints on the web"
        case .webPaying: "Paid plans on the web"
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
        case .consumerReviews: "hand.thumbsdown"
        case .areaDiscussion: "text.magnifyingglass"
        case .webComplaints: "exclamationmark.bubble.fill"
        case .webPaying: "creditcard"
        case .atlassian: "puzzlepiece.extension"
        case .ausTender: "building.2"
        }
    }

    /// What kind of evidence the source gives. Each kind gets a share of the items the AI reads,
    /// so builder-heavy sources can't crowd out evidence of demand.
    var signal: Signal {
        switch self {
        case .painPoints, .fieldNotes, .appReviews, .consumerReviews, .ausTender, .areaDiscussion, .webComplaints, .webPaying: .demand
        case .ycombinator, .research: .timing
        default: .supply
        }
    }

    /// Whether a daily scan reads it (and Settings lists it); the web research kinds come only from "Undercut an app".
    var isScanSource: Bool { self != .webComplaints && self != .webPaying }

    /// Developer- and game-focused sources start switched off, so ideas lean towards people who pay.
    /// GitHub, Show HN and AI research show what builders make rather than what buyers need, and AusTender's
    /// government contracts are out of reach for a solo builder, so they start off too.
    /// A toggle the user has set in Settings always wins.
    var enabledByDefault: Bool {
        switch self {
        case .games, .devTo, .lobsters, .huggingFace, .github, .hackerNews, .research, .ausTender: false
        default: true
        }
    }
}

/// The three kinds of evidence. Demand is what buyers need or pay for (complaints, the user's own
/// challenges, government spending); supply is what's being built; timing is what's newly possible.
enum Signal: String, CaseIterable, Sendable {
    /// The three kinds, as described above.
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
    /// Stable id, e.g. "hn-123", "gh-456"; used to remove duplicates and match starred projects.
    var key: String
    /// The source it came from.
    var source: SourceKind
    /// Headline. For comments and reviews, the most relevant snippet of the text.
    var title: String
    /// Supporting text (description, thread title, review body), already cleaned of HTML.
    var detail: String
    /// Link to the original.
    var url: URL
    /// Stars / points / votes (or rank, value in $k): higher = more traction; compared only within a source.
    var score: Int
    /// When it was posted. Sources with no dates at all (charts, Y Combinator, Atlassian, the user's pain points)
    /// use the start of the window, so they never look "new". Steam games, and items whose date is missing
    /// from itch.io, Hugging Face papers or AusTender, are dated at fetch time instead.
    var postedAt: Date

    /// Whether it was posted in the last 24 hours (shown as NEW, and boosts momentum).
    /// - Parameter now: The reference time; tests pass a fixed date.
    /// - Returns: `true` if posted less than 24 hours before `now`.
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
    /// Reason for the novelty score.
    var novelty = ""
    /// How momentum was measured.
    var momentum = ""
    /// Reason for the viability score.
    var viability = ""
    /// Reason for the opportunity gap score.
    var gap = ""
}

/// How much each score counts towards the overall rank (set in Settings).
struct RankWeights: Equatable, Sendable {
    /// Weight for novelty (0–2; 0 ignores it).
    var novelty = 1.0
    /// Weight for momentum.
    var momentum = 1.0
    /// Weight for viability.
    var viability = 1.0
    /// Weight for opportunity gap.
    var gap = 1.0
}

// MARK: - Warnings

/// A digest warning is stored as one string: a plain message, optionally followed by technical details
/// that the screen shows only behind a "Details" disclosure. Kept as a single string so the stored
/// `Digest.warnings` format doesn't change.
enum DigestWarning {
    /// Separates the message from the details inside the stored string.
    static let marker = "\n[details] "

    /// Builds a stored warning.
    /// - Parameters:
    ///   - message: Plain text for the user.
    ///   - details: Technical detail for diagnosis, or `nil`.
    /// - Returns: The message, followed by `marker` and the details when there are any.
    static func make(_ message: String, details: String? = nil) -> String {
        guard let details, !details.isEmpty else { return message }
        return message + marker + details
    }

    /// Splits a stored warning into its message and (if any) details.
    /// - Parameter warning: A string built by `make`, or a plain message.
    /// - Returns: The message, and the details or `nil`.
    static func parts(_ warning: String) -> (message: String, details: String?) {
        guard let range = warning.range(of: marker) else { return (warning, nil) }
        return (String(warning[..<range.lowerBound]), String(warning[range.upperBound...]))
    }

    /// A plain message for an error, plus its technical detail when it has one.
    /// - Parameter error: Any error from a refresh step.
    /// - Returns: The user-facing message, and the provider's raw status and reply start for HTTP errors.
    static func describe(_ error: Error) -> (message: String, details: String?) {
        if let http = error as? LLMHTTPError { return (http.errorDescription ?? "", http.technicalDetail) }
        return (error.localizedDescription, nil)
    }
}

// MARK: - Safe links

extension URL {
    /// Security: links shown in the app come from public posts and APIs, so anyone could plant a
    /// `tel:`, `sms:`, `facetime:` or another app's custom link. Only plain web links may be opened;
    /// anything else is shown as text.
    /// - Returns: `true` for `http` and `https` links that have a host.
    var isWebLink: Bool {
        guard let scheme = scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return host?.isEmpty == false
    }
}
