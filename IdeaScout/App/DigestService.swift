import Foundation
import SwiftData
import BackgroundTasks

/// Fetches sources, asks the AI for themes and saves the day's digest.
@MainActor
final class DigestService: ObservableObject {
    static let shared = DigestService()
    static let backgroundTaskID = "com.mahoney.IdeaScout.refresh"

    @Published private(set) var isRefreshing = false
    @Published var lastError: String?

    var container: ModelContainer?

    // MARK: - Refresh

    /// Builds today's digest. Without `force`, does nothing if one already exists.
    func refresh(force: Bool, notify: Bool = false) async {
        guard let context = container?.mainContext, !isRefreshing else { return }
        let today = Calendar.current.startOfDay(for: .now)
        let existing = (try? context.fetch(FetchDescriptor<Digest>(predicate: #Predicate { $0.day == today }))) ?? []
        if !force && !existing.isEmpty { return }

        isRefreshing = true
        lastError = nil
        defer { isRefreshing = false }

        let since = Date.now.addingTimeInterval(-24 * 60 * 60)
        let topics = AppSettings.topics
        let (fetched, warnings) = await fetchAll(since: since, topics: topics)

        let recentKeys = recentlyShownKeys(context: context, excludingDay: today)
        let items = Self.select(fetched.filter { !recentKeys.contains($0.key) }, perSource: 15)
        guard !items.isEmpty else {
            lastError = warnings.isEmpty ? "No new projects found. Try again later." : warnings.joined(separator: "\n")
            return
        }

        var summarizer = AppSettings.makeSummarizer()
        var drafts: [ThemeDraft]
        var allWarnings = warnings
        let batch = Array(items.prefix(summarizer.maxItems))
        do {
            drafts = try await summarizer.themes(for: batch)
        } catch {
            allWarnings.append("\(summarizer.name) summary failed (\(error.localizedDescription)); grouped by keyword instead.")
            summarizer = KeywordSummarizer(topics: topics)
            drafts = (try? await summarizer.themes(for: batch)) ?? []
        }

        existing.forEach(context.delete)
        let digest = Digest(day: today, summarizer: summarizer.name, warnings: allWarnings)
        context.insert(digest)
        for (order, built) in ThemeBuilder.assemble(drafts, items: batch).enumerated() {
            let theme = Theme(title: built.title, summary: built.summary, order: order, opportunities: built.opportunities)
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
        // Vibe-code first so an item found by both it and Show HN keeps the vibe-code label.
        var fetchers: [any ItemFetcher] = []
        if AppSettings.isEnabled(.vibeCode) { fetchers.append(VibeCodeFetcher()) }
        if AppSettings.isEnabled(.hackerNews) { fetchers.append(HackerNewsFetcher()) }
        if AppSettings.isEnabled(.github) { fetchers.append(GitHubFetcher()) }
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

    private func recentlyShownKeys(context: ModelContext, excludingDay today: Date) -> Set<String> {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: today) ?? today
        let descriptor = FetchDescriptor<Digest>(predicate: #Predicate { $0.day >= weekAgo && $0.day != today })
        let digests = (try? context.fetch(descriptor)) ?? []
        return Set(digests.flatMap { $0.themes.flatMap { $0.items.map(\.key) } })
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
