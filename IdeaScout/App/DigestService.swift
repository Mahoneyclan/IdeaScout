import Foundation
import SwiftData
import BackgroundTasks

/// Fetches sources, asks the AI for themes and saves the day's digest.
@MainActor
final class DigestService: ObservableObject {
    static let shared = DigestService()
    static let backgroundTaskID = "com.mahoney.IdeaScout.refresh"

    @Published private(set) var isRefreshing = false
    /// Which step a running refresh is on, for the progress shown on screen.
    @Published private(set) var stage: Stage?

    enum Stage: Int, CaseIterable {
        case fetching = 1, trends, ideas, critique
        var label: String {
            switch self {
            case .fetching: "Fetching sources"
            case .trends: "Reading items and finding trends"
            case .ideas: "Generating ideas"
            case .critique: "Devil's advocate"
            }
        }
    }
    @Published var lastError: String?

    var container: ModelContainer?
    private var refreshTask: Task<Void, Never>?

    // MARK: - Refresh

    /// Builds today's digest. Without `force`, does nothing if one already exists.
    /// The work runs in its own task, so it isn't cancelled if the screen that started it goes away
    /// (previously that cut the AI summary off half-way). A background refresh passes
    /// `cancelWithCaller` so that when iOS ends the background time, the work stops cleanly.
    func refresh(force: Bool, notify: Bool = false, cancelWithCaller: Bool = false) async {
        if let running = refreshTask {
            await running.value
            return
        }
        let task = Task { await performRefresh(force: force, notify: notify) }
        refreshTask = task
        if cancelWithCaller {
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        } else {
            await task.value
        }
        refreshTask = nil
    }

    private func performRefresh(force: Bool, notify: Bool) async {
        guard let context = container?.mainContext else { return }
        let today = Calendar.current.startOfDay(for: .now)
        let existing = (try? context.fetch(FetchDescriptor<Digest>(predicate: #Predicate { $0.day == today }))) ?? []
        // Rebuild automatically if today's digest fell back to keywords but an AI is now available.
        let fellBack = existing.contains { $0.summarizer == KeywordSummarizer(topics: []).name }
            && !(AppSettings.makeSummarizer() is KeywordSummarizer)
        if !force && !existing.isEmpty && !fellBack { return }

        isRefreshing = true
        stage = .fetching
        lastError = nil
        defer { isRefreshing = false; stage = nil }

        // Trends are built from the chosen window (default a week) so a theme reflects several projects over
        // several days; pain points, which are rarer, use their own longer window. Items from the last 24 hours are "new".
        let since = Self.windowStart(days: AppSettings.trendWindowDays)
        let painSince = Self.windowStart(days: AppSettings.painWindowDays)
        let topics = AppSettings.topics
        let (fetched, warnings) = await fetchAll(since: since, painSince: painSince, topics: topics)
        if Task.isCancelled { return }

        let useful = fetched.filter { $0.source == .fieldNotes || ProductFilter.isProductShaped($0) }
        let items = Self.selectBySignal(useful, maxItems: AppSettings.claudeMaxItems)
        guard !items.isEmpty else {
            lastError = warnings.isEmpty ? "No new projects found. Try again later." : warnings.joined(separator: "\n")
            return
        }

        var summarizer = AppSettings.makeSummarizer()
        let hasClaudeKey = summarizer is ClaudeSummarizer
        var allWarnings = warnings
        var killerNote: String?
        let capText = AppSettings.dailyCap.formatted(.currency(code: "USD"))
        if hasClaudeKey && AppSettings.isOverDailyCap {
            allWarnings.append("Today's Claude spending limit (\(capText)) is reached, so Claude was skipped. Change it in Settings → AI costs.")
            killerNote = "Killer ideas skipped: daily spending limit reached."
            summarizer = AppleSummarizer.isAvailable ? AppleSummarizer() : KeywordSummarizer(topics: topics)
        }

        var drafts: [ThemeDraft]
        var noise = Set<Int>()
        // Claude translates non-English items; without it, leave out items that clearly aren't English.
        let candidates = summarizer is ClaudeSummarizer ? items : items.filter(LanguageFilter.isEnglishOrUnclear)
        var batch = Array(candidates.prefix(summarizer.maxItems))
        stage = .trends
        do {
            let analysis = try await summarizer.analyse(batch)
            drafts = analysis.drafts
            // Never treat the owner's own field notes as noise.
            noise = analysis.noise.filter { batch.indices.contains($0 - 1) && batch[$0 - 1].source != .fieldNotes }
            batch = Translations.apply(analysis.translations, to: batch)
        } catch {
            if Self.isCancellation(error) || Task.isCancelled { return }  // don't save a half-finished digest
            allWarnings.append("\(summarizer.name) summary failed (\(error.localizedDescription)); grouped by keyword instead.")
            if summarizer is ClaudeSummarizer { killerNote = "Killer ideas skipped because the Claude summary failed." }
            summarizer = KeywordSummarizer(topics: topics)
            batch = batch.filter(LanguageFilter.isEnglishOrUnclear)
            drafts = (try? await summarizer.themes(for: batch)) ?? []
        }

        // Never replace a better digest from earlier today (e.g. Claude) with a weaker one (e.g. keywords).
        if let kept = existing.max(by: { Self.quality($0.summarizer) < Self.quality($1.summarizer) }),
           !Self.shouldReplace(existing: kept.summarizer, with: summarizer.name) {
            let time = Date.now.formatted(date: .omitted, time: .shortened)
            let note = "Refresh at \(time) didn't work (\(allWarnings.last ?? "unknown error")). Kept the earlier \(kept.summarizer) digest."
            kept.warnings.append(note)
            try? context.save()
            lastError = note
            return
        }

        // Save the trends straight away, so a later failure (or iOS stopping the app) can't lose them.
        let builtThemes = ThemeBuilder.assemble(drafts, items: batch, noise: noise)
        existing.forEach(context.delete)
        let digest = Digest(day: today, summarizer: summarizer.name, warnings: allWarnings)
        context.insert(digest)
        for (order, built) in builtThemes.enumerated() {
            let theme = Theme(title: built.title, summary: built.summary, order: order, opportunities: built.opportunities)
            theme.apply(built.scores, built.reasons)
            theme.isCatchAll = built.isCatchAll
            theme.isPainCluster = built.isPainCluster
            theme.buyer = built.buyer; theme.workaround = built.workaround; theme.paySignals = built.paySignals
            context.insert(theme)
            theme.digest = digest
            for fetchedItem in built.items {
                let item = Item(fetchedItem)
                context.insert(item)
                item.theme = theme
            }
        }
        try? context.save()

        // Killer ideas: Claude only. A failure here keeps the saved digest.
        if let claude = summarizer as? ClaudeSummarizer {
            if AppSettings.isOverDailyCap {
                digest.warnings.append("Killer ideas skipped: today's Claude spending limit (\(capText)) was reached during the trend step.")
            } else {
                do {
                    let leaderboard = topKillerIdeas(context: context, limit: 10).map { "\($0.title): \($0.pitch)" }
                    stage = .ideas
                    let results = try await KillerEngine(claude: claude, onCritique: { [weak self] in
                        await MainActor.run { self?.stage = .critique }
                    }).run(
                        .init(themes: builtThemes, items: batch, aboutMe: AppSettings.aboutMe, leaderboard: leaderboard,
                              focusIndustry: AppSettings.focusIndustry,
                              painClusters: builtThemes.filter(\.isPainCluster).map {
                                  "\($0.title) (buyer: \($0.buyer); today: \($0.workaround); pays: \($0.paySignals); \($0.items.count) items)"
                              }))
                    mergeKillerIdeas(results, items: batch, context: context)
                    if results.isEmpty {
                        digest.warnings.append("The devil's advocate rejected every idea today.")
                    } else if !results.contains(where: { $0.score >= AppSettings.qualityBar }) {
                        digest.warnings.append("No idea cleared the quality bar (\(AppSettings.qualityBar.formatted()) / 5) today; the best are shown as near-misses.")
                    }
                } catch {
                    if !(Self.isCancellation(error) || Task.isCancelled) {
                        digest.warnings.append("Killer ideas failed: \(error.localizedDescription)")
                    }
                }
            }
        } else if let killerNote {
            digest.warnings.append(killerNote)
        } else if !hasClaudeKey {
            digest.warnings.append("Killer ideas need Claude: add an API key in Settings.")
        }
        try? context.save()

        if notify && !Task.isCancelled {
            await Notifier.digestReady(themes: digest.themes.count, items: digest.itemCount)
        }
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// Claude digests beat Apple's, which beat keyword grouping.
    nonisolated static func quality(_ summarizer: String) -> Int {
        switch summarizer {
        case "Claude": 3
        case "Apple on-device": 2
        default: 1
        }
    }

    nonisolated static func shouldReplace(existing: String, with new: String) -> Bool {
        quality(new) >= quality(existing)
    }

    nonisolated static func windowStart(days: Int, now: Date = .now) -> Date {
        now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
    }

    private func fetchAll(since: Date, painSince: Date, topics: [String]) async -> ([FetchedItem], [String]) {
        // Vibe-code and games first so an item they share with Show HN keeps the more specific label.
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
        if AppSettings.isEnabled(.productHunt) { fetchers.append(ProductHuntFetcher(token: Keychain.get(.productHuntToken))) }

        let results = await withTaskGroup(of: (Int, Result<[FetchedItem], Error>).self) { group in
            for (index, fetcher) in fetchers.enumerated() {
                group.addTask {
                    let start = [.painPoints, .appReviews].contains(fetcher.kind) ? painSince : since
                    do { return (index, .success(try await fetcher.fetch(since: start, topics: topics))) }
                    catch { return (index, .failure(error)) }
                }
            }
            var collected: [(Int, Result<[FetchedItem], Error>)] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }
        }

        var items: [FetchedItem] = []
        var warnings: [String] = []
        for (index, result) in results {
            switch result {
            case .success(let found): items += found
            case .failure(let error): warnings.append("\(fetchers[index].kind.label): \(error.localizedDescription)")
            }
        }
        return (Self.dedupe(items), warnings)
    }

    /// Removes duplicates by id and by link, keeping the first occurrence.
    nonisolated static func dedupe(_ items: [FetchedItem]) -> [FetchedItem] {
        var seenKeys = Set<String>(), seenURLs = Set<String>()
        return items.filter { seenKeys.insert($0.key).inserted && seenURLs.insert($0.url.absoluteString.lowercased()).inserted }
    }

    /// Fills Claude's quota by signal: field notes first, then 40% demand, 40% supply and 20% timing,
    /// each shared fairly between its sources. Unused share rolls over. The result interleaves the
    /// signals so a summariser that reads only the first few items still sees each kind.
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

    // MARK: - Killer ideas

    func topKillerIdeas(context: ModelContext, limit: Int) -> [KillerIdea] {
        let all = (try? context.fetch(FetchDescriptor<KillerIdea>())) ?? []
        return Array(all.sorted { $0.leaderboardScore > $1.leaderboardScore }.prefix(limit))
    }

    /// Adds new killer ideas, or updates ones that came back (they climb the leaderboard).
    private func mergeKillerIdeas(_ results: [KillerEngine.Result], items: [FetchedItem], context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<KillerIdea>())) ?? []
        for result in results {
            let c = result.candidate, r = result.review
            let matchKey = KillerIdea.key(for: c.sameAs.isEmpty ? c.title : c.sameAs)
            let idea: KillerIdea
            if let existing = all.first(where: { $0.key == matchKey || $0.key == KillerIdea.key(for: c.title) }) {
                idea = existing
                if !Calendar.current.isDateInToday(existing.lastSeen) { idea.timesSeen += 1 }
            } else {
                idea = KillerIdea(key: KillerIdea.key(for: c.title), title: c.title)
                context.insert(idea)
            }
            idea.pitch = c.pitch; idea.buyer = c.buyer; idea.pricing = c.pricing; idea.whyNow = c.whyNow
            idea.oneWeekTest = c.oneWeekTest; idea.replaces = c.replaces
            idea.objection = r.objection; idea.competitors = r.competitors
            idea.verdict = r.evidenceNeeded.isEmpty ? r.verdict : "\(r.verdict) Evidence that would raise the score: \(r.evidenceNeeded)"
            idea.pain = r.pain; idea.willingToPay = r.willingToPay; idea.timing = r.timing; idea.gap = r.gap; idea.fit = r.fit
            let evidence = c.evidenceNumbers.map { $0 - 1 }.filter { items.indices.contains($0) }.map { items[$0] }
            if !evidence.isEmpty {
                idea.evidenceTitles = evidence.map(\.title)
                idea.evidenceURLs = evidence.map(\.url.absoluteString)
            }
            idea.recordSeen(on: .now)
            idea.lastSeen = .now
            idea.scoreHistory.append(idea.killerScore)
        }
    }

    // MARK: - Saved ideas

    func toggleStar(_ item: Item, ideas: [Idea], context: ModelContext) {
        if let idea = ideas.first(where: { $0.key == item.key }) {
            context.delete(idea)
        } else {
            context.insert(Idea(from: item))
        }
        try? context.save()
    }

    func suggestExtensions(for idea: Idea) async throws {
        let summarizer = AppSettings.makeSummarizer()
        idea.extensions = try await summarizer.extensions(for: IdeaBrief(title: idea.title, detail: idea.detail, note: idea.note))
        try? container?.mainContext.save()
    }

    // MARK: - Background refresh

    /// Asks iOS to wake the app around the chosen hour. iOS decides the actual time, and may skip days.
    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskID)
        request.earliestBeginDate = Self.nextOccurrence(ofHour: AppSettings.notifyHour, after: .now)
        try? BGTaskScheduler.shared.submit(request)
    }

    func runBackgroundRefresh() async {
        scheduleBackgroundRefresh()
        await refresh(force: false, notify: true, cancelWithCaller: true)
    }

    nonisolated static func nextOccurrence(ofHour hour: Int, after date: Date) -> Date {
        Calendar.current.nextDate(after: date, matching: DateComponents(hour: hour, minute: 0), matchingPolicy: .nextTime) ?? date
    }
}
