// LiveRefresh.swift
// What a running refresh has found so far, shown on the Ideas tab step by step (owner, 16 Nov 2026) instead of
// only when every step is done: the items read per source, the day's trends and pain clusters, the draft ideas, and
// the devil's advocate's verdict on each, and each step's state. Held in memory only; the saved digest and ideas are
// the lasting record.

import Foundation

/// A refresh's results so far. Filled in by `DigestService` as each step finishes; kept after it ends (shown folded
/// as "How it went") until the next refresh starts.
struct LiveRefresh: Equatable, Sendable {
    /// How many items one source gave to the AI.
    struct SourceCount: Equatable, Sendable {
        var label: String
        var count: Int
    }

    /// One idea from the idea step, before and after the devil's advocate.
    struct Draft: Equatable, Sendable {
        /// Where the idea stands.
        enum Status: Equatable, Sendable {
            /// Proposed; the devil's advocate hasn't judged it yet.
            case unjudged
            /// The devil's advocate backed it.
            case backed
            /// The devil's advocate rejected it, with its strongest objection (still saved, ranked low).
            case rejected(String)
            /// Dropped before saving: not buildable by one person, or not in today's top ideas.
            case dropped
        }

        var title: String
        var pitch: String
        var buyer: String
        var status = Status.unjudged
    }

    /// Items read per source, most first; empty until the sources are read.
    var sources: [SourceCount] = []
    /// Pain cluster titles, once the trend step is saved.
    var painClusters: [String] = []
    /// Trend titles (not the catch-all), once the trend step is saved.
    var trends: [String] = []
    /// Draft ideas, once the idea step has proposed them.
    var drafts: [Draft] = []
    /// Each step's state, steps 1–5 in order (see LiveRefresh+Steps.swift).
    var steps: [StepState] = Array(repeating: .waiting, count: 5)
    /// When the refresh started; `nil` before any refresh this session.
    var startedAt: Date?
    /// When it ended (finished or stopped); `nil` while it runs.
    var finishedAt: Date?

    /// All items read.
    var itemCount: Int { sources.reduce(0) { $0 + $1.count } }

    /// Counts the chosen items per source, most first (ties by label, so the order is stable).
    /// - Parameter items: The items the AI will read.
    /// - Returns: One count per source that gave any.
    static func counts(_ items: [FetchedItem]) -> [SourceCount] {
        var tally: [String: Int] = [:]
        for item in items { tally[item.source.label, default: 0] += 1 }
        let counts = tally.map { SourceCount(label: $0.key, count: $0.value) }
        return counts.sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
    }

    /// The idea step's proposals, not yet judged.
    static func drafts(_ candidates: [KillerEngine.Candidate]) -> [Draft] {
        candidates.map { Draft(title: $0.title, pitch: $0.pitch, buyer: $0.buyer) }
    }

    /// Marks each draft with the devil's advocate's verdict. A draft with no matching result was dropped.
    /// - Parameters:
    ///   - drafts: The drafts shown so far.
    ///   - results: What the idea step kept.
    /// - Returns: The drafts with their status.
    static func judged(_ drafts: [Draft], results: [KillerEngine.Result]) -> [Draft] {
        let byKey = Dictionary(results.map { (KillerIdea.key(for: $0.candidate.title), $0.review) },
                               uniquingKeysWith: { first, _ in first })
        return drafts.map { draft in
            var judged = draft
            if let review = byKey[KillerIdea.key(for: draft.title)] {
                judged.status = review.survives ? .backed : .rejected(review.objection)
            } else {
                judged.status = .dropped
            }
            return judged
        }
    }
}
