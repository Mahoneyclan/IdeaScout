// DigestService+Selection.swift
// Which sources are fetched, and how their items are de-duplicated and chosen for the AI (the 40/40/20
// signal shares). Pure functions, so they're unit tested directly.

import Foundation

extension DigestService {
    /// The enabled sources, in priority order. Business challenges and other demand sources come first, then
    /// vibe-code and games, so an item they share with Show HN keeps the more specific label.
    static func enabledFetchers() -> [any ItemFetcher] {
        var fetchers: [any ItemFetcher] = []
        if AppSettings.isEnabled(.fieldNotes) { fetchers.append(FieldNotesFetcher(notes: AppSettings.fieldNotes)) }
        if AppSettings.isEnabled(.appReviews) { fetchers.append(AppReviewsFetcher()) }
        if AppSettings.isEnabled(.ausTender) { fetchers.append(AusTenderFetcher()) }
        if AppSettings.isEnabled(.atlassian) { fetchers.append(AtlassianFetcher()) }
        if AppSettings.isEnabled(.vibeCode) { fetchers.append(VibeCodeFetcher()) }
        if AppSettings.isEnabled(.games) { fetchers.append(GamesFetcher()) }
        if AppSettings.isEnabled(.painPoints) { fetchers.append(PainPointsFetcher()) }
        if AppSettings.isEnabled(.ycombinator) { fetchers.append(YCombinatorFetcher()) }
        if AppSettings.isEnabled(.appStore) { fetchers.append(AppStoreFetcher()) }
        if AppSettings.isEnabled(.research) { fetchers.append(ResearchFetcher()) }
        if AppSettings.isEnabled(.lobsters) { fetchers.append(LobstersFetcher()) }
        if AppSettings.isEnabled(.hackerNews) { fetchers.append(HackerNewsFetcher()) }
        if AppSettings.isEnabled(.github) { fetchers.append(GitHubFetcher()) }
        if AppSettings.isEnabled(.huggingFace) { fetchers.append(HuggingFaceFetcher()) }
        if AppSettings.isEnabled(.devTo) { fetchers.append(DevToFetcher()) }
        return fetchers
    }

    /// Removes duplicates by id and by link, keeping the first occurrence.
    nonisolated static func dedupe(_ items: [FetchedItem]) -> [FetchedItem] {
        var seenKeys = Set<String>(), seenURLs = Set<String>()
        return items.filter { seenKeys.insert($0.key).inserted && seenURLs.insert($0.url.absoluteString.lowercased()).inserted }
    }

    /// Fills the AI's quota by signal: business challenges first, then 40% demand, 40% supply and 20% timing,
    /// each shared fairly between its sources. Unused share rolls over. The result interleaves the
    /// signals so a summariser that reads only the first few items still sees each kind.
    /// - Parameters:
    ///   - items: Candidates from every source.
    ///   - maxItems: The AI's item limit.
    /// - Returns: At most `maxItems` items (plus all business challenges).
    nonisolated static func selectBySignal(_ items: [FetchedItem], maxItems: Int) -> [FetchedItem] {
        let notes = items.filter { $0.source == .fieldNotes }
        let rest = items.filter { $0.source != .fieldNotes }
        let budget = max(maxItems - notes.count, 0)
        // Each signal's items in fair per-source order (best of each source first).
        let ordered = Dictionary(uniqueKeysWithValues: Signal.allCases.map { signal in
            (signal, select(rest.filter { $0.source.signal == signal }, perSource: budget))
        })
        var taken: [Signal: Int] = [:]
        for signal in Signal.allCases {
            taken[signal] = min(ordered[signal]!.count, Int((Double(budget) * signal.share).rounded()))
        }
        var spare = budget - taken.values.reduce(0, +)
        for signal in Signal.allCases where spare > 0 {
            let extra = min(spare, ordered[signal]!.count - taken[signal]!)
            taken[signal]! += extra
            spare -= extra
        }
        let lists = Signal.allCases.map { Array(ordered[$0]!.prefix(taken[$0]!)) }
        var result = notes
        for i in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where i < list.count { result.append(list[i]) }
        }
        return result
    }

    /// Takes the highest-scoring items from each source so no single source dominates.
    /// - Parameters:
    ///   - items: Candidates.
    ///   - perSource: Most items to take from any one source.
    /// - Returns: The best of each source, interleaved (1st of each source, then 2nd of each, …).
    nonisolated static func select(_ items: [FetchedItem], perSource: Int) -> [FetchedItem] {
        let bySource = Dictionary(grouping: items, by: \.source)
        let tops = SourceKind.allCases.map { (bySource[$0] ?? []).sorted { $0.score > $1.score }.prefix(perSource) }
        // Interleave so that if a summariser can only take N items, each source is represented.
        var result: [FetchedItem] = []
        for i in 0..<perSource {
            for top in tops where i < top.count { result.append(top[top.startIndex + i]) }
        }
        return result
    }
}
