import Foundation
import SwiftData
import BackgroundTasks

/// Fetches sources, asks the AI for themes and saves the day's digest.
@MainActor
final class DigestService: ObservableObject {
    static let shared = DigestService()
    static let backgroundTaskID = "com.mahoney.IdeaScout.refresh"
    static let windowDays = 7.0

    @Published private(set) var isRefreshing = false
    @Published var lastError: String?

    var container: ModelContainer?
    private var refreshTask: Task<Void, Never>?

    // MARK: - Refresh

    /// Builds today's digest. Without `force`, does nothing if one already exists.
    /// The work runs in its own task, so it isn't cancelled if the screen that
    /// started it goes away (previously that cut the AI summary off half-way).
    func refresh(force: Bool, notify: Bool = false) async {
        if let running = refreshTask {
            await running.value
            return
        }
        let task = Task { await performRefresh(force: force, notify: notify) }
        refreshTask = task
        await task.value
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
        lastError = nil
        defer { isRefreshing = false }

        // Trends are built from the past week so a theme reflects several projects over several days;
        // items posted in the last 24 hours are flagged as new.
        let since = Date.now.addingTimeInterval(-Self.windowDays * 24 * 60 * 60)
        let topics = AppSettings.topics
        let (fetched, warnings) = await fetchAll(since: since, topics: topics)

        let items = Self.select(fetched.filter(ProductFilter.isProductShaped), perSource: 25)
        guard !items.isEmpty else {
            lastError = warnings.isEmpty ? "No new projects found. Try again later." : warnings.joined(separator: "\n")
            return
        }

        var summarizer = AppSettings.makeSummarizer()
        var drafts: [ThemeDraft]
        var allWarnings = warnings
        // Claude translates non-English items; without it, leave out items that clearly aren't English.
        let candidates = summarizer is ClaudeSummarizer ? items : items.filter(LanguageFilter.isEnglishOrUnclear)
        var batch = Array(candidates.prefix(summarizer.maxItems))
        do {
            let (themeDrafts, translations) = try await summarizer.themesWithTranslations(for: batch)
            drafts = themeDrafts
            batch = Translations.apply(translations, to: batch)
        } catch is CancellationError {
            return  // don't save a half-finished digest
        } catch {
            allWarnings.append("\(summarizer.name) summary failed (\(error.localizedDescription)); grouped by keyword instead.")
            summarizer = KeywordSummarizer(topics: topics)
            batch = batch.filter(LanguageFilter.isEnglishOrUnclear)
            drafts = (try? await summarizer.themes(for: batch)) ?? []
        }

        let builtThemes = ThemeBuilder.assemble(drafts, items: batch)

        // Killer ideas: Claude only. A failure here doesn't stop the digest being saved.
        if let claude = summarizer as? ClaudeSummarizer {
            do {
                let leaderboard = topKillerIdeas(context: context, limit: 10).map { "\($0.title): \($0.pitch)" }
                let results = try await KillerEngine(claude: claude).run(
                    .init(themes: builtThemes, items: batch, aboutMe: AppSettings.aboutMe, leaderboard: leaderboard))
                mergeKillerIdeas(results, items: batch, context: context)
                if results.isEmpty { allWarnings.append("No idea survived the devil's-advocate check today.") }
            } catch is CancellationError {
                return
            } catch {
                allWarnings.append("Killer ideas failed: \(error.localizedDescription)")
            }
        } else {
            allWarnings.append("Killer ideas need Claude: add an API key in Settings.")
        }

        existing.forEach(context.delete)
        let digest = Digest(day: today, summarizer: summarizer.name, warnings: allWarnings)
        context.insert(digest)
        for (order, built) in builtThemes.enumerated() {
            let theme = Theme(title: built.title, summary: built.summary, order: order, opportunities: built.opportunities)
            theme.apply(built.scores, built.reasons)
            theme.isCatchAll = built.isCatchAll
            context.insert(theme)
            theme.digest = digest
            for fetchedItem in built.items {
                let item = Item(fetchedItem)
                context.insert(item)
                item.theme = theme
            }
        }
        try? context.save()

        if notify {
            await Notifier.digestReady(themes: digest.themes.count, items: digest.itemCount)
        }
    }

    private func fetchAll(since: Date, topics: [String]) async -> ([FetchedItem], [String]) {
        // Vibe-code and games first so an item they share with Show HN keeps the more specific label.
        var fetchers: [any ItemFetcher] = []
        if AppSettings.isEnabled(.vibeCode) { fetchers.append(VibeCodeFetcher()) }
        if AppSettings.isEnabled(.games) { fetchers.append(GamesFetcher()) }
        if AppSettings.isEnabled(.painPoints) { fetchers.append(PainPointsFetcher()) }
        if AppSettings.isEnabled(.hackerNews) { fetchers.append(HackerNewsFetcher()) }
        if AppSettings.isEnabled(.github) { fetchers.append(GitHubFetcher()) }
        if AppSettings.isEnabled(.huggingFace) { fetchers.append(HuggingFaceFetcher()) }
        if AppSettings.isEnabled(.devTo) { fetchers.append(DevToFetcher()) }
        if AppSettings.isEnabled(.productHunt) { fetchers.append(ProductHuntFetcher(token: Keychain.get(.productHuntToken))) }

        let results = await withTaskGroup(of: (Int, Result<[FetchedItem], Error>).self) { group in
            for (index, fetcher) in fetchers.enumerated() {
                group.addTask {
                    do { return (index, .success(try await fetcher.fetch(since: since, topics: topics))) }
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
            idea.oneWeekTest = c.oneWeekTest
            idea.objection = r.objection; idea.competitors = r.competitors; idea.verdict = r.verdict
            idea.pain = r.pain; idea.willingToPay = r.willingToPay; idea.timing = r.timing; idea.gap = r.gap; idea.fit = r.fit
            let evidence = c.evidenceNumbers.map { $0 - 1 }.filter { items.indices.contains($0) }.map { items[$0] }
            if !evidence.isEmpty {
                idea.evidenceTitles = evidence.map(\.title)
                idea.evidenceURLs = evidence.map(\.url.absoluteString)
            }
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
        await refresh(force: false, notify: true)
    }

    nonisolated static func nextOccurrence(ofHour hour: Int, after date: Date) -> Date {
        Calendar.current.nextDate(after: date, matching: DateComponents(hour: hour, minute: 0), matchingPolicy: .nextTime) ?? date
    }
}
