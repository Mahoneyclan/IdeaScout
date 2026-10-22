// DigestService.swift
// Runs a refresh and saves the result. The steps, in order:
//  1. Check the trial/unlock (StoreManager); stop with a message if refreshes aren't allowed.
//  2. Fetch every enabled source in parallel (Fetchers.swift, DemandFetchers.swift); remove duplicates and noise.
//  3. Choose up to N items by signal: 40% demand, 40% supply, 20% timing (selectBySignal).
//  4. Pick the AI (AppSettings.makeSummarizer), respecting consent and the daily spending limit.
//  5. Trend step: themes, pain clusters, translations, noise. On failure fall back to keyword grouping.
//  6. Never replace a better digest from earlier today with a weaker one.
//  7. Save the digest immediately, so a later failure can't lose it.
//  8. Idea step (cloud AI only): KillerEngine; merge survivors into the leaderboard (KillerIdea).
//  9. Notify if this was a background refresh.
// Also: starring projects, variant suggestions, background scheduling, and removing retired sources.

import Foundation
import SwiftData
import BackgroundTasks
import UserNotifications

/// Fetches sources, asks the AI for themes and ideas, and saves the day's digest. Runs on the main thread
/// (`@MainActor`) because it drives the UI and uses the main SwiftData context; network and AI calls are
/// `await`ed, so the UI stays responsive. Helpers marked `nonisolated` are pure functions that tests call directly.
@MainActor
final class DigestService: ObservableObject {
    /// The single shared instance, injected into SwiftUI by IdeaScoutApp.
    static let shared = DigestService()
    /// Must match BGTaskSchedulerPermittedIdentifiers in project.yml.
    static let backgroundTaskID = "com.mahoney.IdeaScout.refresh"

    /// True while a refresh runs (drives the progress row and disables the refresh button).
    @Published private(set) var isRefreshing = false
    /// Which step a running refresh is on, for the progress shown on screen.
    @Published private(set) var stage: Stage?

    /// Refresh steps shown as "Step n of 4". Raw values are the step numbers.
    enum Stage: Int, CaseIterable {
        case fetching = 1, trends, ideas, critique
        /// Plain-English step name.
        var label: String {
            switch self {
            case .fetching: "Fetching sources"
            case .trends: "Reading items and finding trends"
            case .ideas: "Generating ideas"
            case .critique: "Devil's advocate"
            }
        }
    }
    /// Why the last refresh didn't produce a new digest (trial ended, nothing found, kept an earlier
    /// digest…), shown on the Ideas tab. Cleared when a refresh starts.
    @Published var lastError: String?

    /// The database, set by IdeaScoutApp at launch. Refreshes do nothing until it's set.
    var container: ModelContainer?
    private var refreshTask: Task<Void, Never>?

    // MARK: - Refresh

    /// Builds today's digest. Without `force`, does nothing if one already exists.
    /// The work runs in its own task, so it isn't cancelled if the screen that started it goes away
    /// (a view's `.task` is cancelled when the view disappears, which would stop the AI call). A background refresh passes
    /// `cancelWithCaller` so that when iOS ends the background time, the work stops cleanly.
    /// If a refresh is already running, waits for it instead of starting another.
    /// - Parameters:
    ///   - force: Rebuild even if today's digest exists (the refresh button).
    ///   - notify: Post a notification when done (background refreshes).
    ///   - cancelWithCaller: Stop when the caller is cancelled (background refreshes only).
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

    /// The refresh itself (see the steps at the top of this file). Saves to the database; never throws:
    /// problems become digest warnings or `lastError`.
    private func performRefresh(force: Bool, notify: Bool) async {
        guard let context = container?.mainContext else { return }
        let today = Calendar.current.startOfDay(for: .now)
        let existing = (try? context.fetch(FetchDescriptor<Digest>(predicate: #Predicate { $0.day == today }))) ?? []
        // Rebuild automatically if today's digest fell back to keywords but an AI is now available.
        let fellBack = existing.contains { $0.summarizer == KeywordSummarizer(topics: []).name }
            && !(AppSettings.makeSummarizer() is KeywordSummarizer)
        if !force && !existing.isEmpty && !fellBack { return }

        // After the free trial, new refreshes need the one-off unlock. Saved history stays readable.
        await StoreManager.shared.ensureLoaded()
        guard StoreManager.shared.access.canRefresh else {
            lastError = StoreManager.shared.access == .notStarted
                ? "Start your free 7-day trial to find new ideas."
                : "Your free trial has ended. Unlock IdeaScout to keep finding new ideas."
            return
        }

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
        let hasCloudAI = summarizer is LLMSummarizer
        var allWarnings = warnings
        if AppSettings.needsConsent {
            allWarnings.append("\(AppSettings.provider.shortName) wasn't used because you haven't agreed to share data with it. Agree in Settings → Advanced → AI & costs.")
        }
        var killerNote: String?
        let capText = AppSettings.dailyCap.formatted(.currency(code: "USD"))
        if hasCloudAI && AppSettings.isOverDailyCap {
            allWarnings.append("Today's AI spending limit (\(capText)) is reached, so \(summarizer.name) was skipped. Change it in Settings → AI & costs.")
            killerNote = "Killer ideas skipped: daily spending limit reached."
            summarizer = AppleSummarizer.isAvailable ? AppleSummarizer() : KeywordSummarizer(topics: topics)
        }

        var drafts: [ThemeDraft]
        var noise = Set<Int>()
        // A cloud AI translates non-English items; without one, leave out items that clearly aren't English.
        let candidates = summarizer is LLMSummarizer ? items : items.filter(LanguageFilter.isEnglishOrUnclear)
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
            let failure = DigestWarning.describe(error)
            allWarnings.append(DigestWarning.make("\(summarizer.name) summary failed: \(failure.message) Grouped by keyword instead.",
                                                  details: failure.details))
            if summarizer is LLMSummarizer { killerNote = "Killer ideas skipped because the \(summarizer.name) summary failed." }
            summarizer = KeywordSummarizer(topics: topics)
            batch = batch.filter(LanguageFilter.isEnglishOrUnclear)
            drafts = (try? await summarizer.themes(for: batch)) ?? []
        }

        // Never replace a better digest from earlier today (e.g. cloud AI) with a weaker one (e.g. keywords).
        if let kept = existing.max(by: { Self.quality($0.summarizer) < Self.quality($1.summarizer) }),
           !Self.shouldReplace(existing: kept.summarizer, with: summarizer.name) {
            let time = Date.now.formatted(date: .omitted, time: .shortened)
            let reason = allWarnings.last.map { DigestWarning.parts($0).message } ?? "unknown error"
            let note = "Refresh at \(time) didn't work (\(reason)). Kept the earlier \(kept.summarizer) digest."
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

        // Killer ideas: cloud AI only. A failure here keeps the saved digest.
        if let llm = summarizer as? LLMSummarizer {
            if AppSettings.isOverDailyCap {
                digest.warnings.append("Killer ideas skipped: today's AI spending limit (\(capText)) was reached during the trend step.")
            } else {
                do {
                    let leaderboard = topKillerIdeas(context: context, limit: 10).map { "\($0.title): \($0.pitch)" }
                    stage = .ideas
                    let results = try await KillerEngine(llm: llm, onCritique: { [weak self] in
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
                        let failure = DigestWarning.describe(error)
                        digest.warnings.append(DigestWarning.make("Killer ideas failed: \(failure.message)", details: failure.details))
                    }
                }
            }
        } else if let killerNote {
            digest.warnings.append(killerNote)
        } else if !hasCloudAI {
            digest.warnings.append("Killer ideas need a cloud AI (e.g. Claude or ChatGPT): choose one and add its API key in Settings → AI & costs.")
        }
        try? context.save()

        if notify && !Task.isCancelled {
            await Notifier.digestReady(themes: digest.themes.count, items: digest.itemCount)
        }
    }

    /// Whether an error means "stopped on purpose" (task cancelled or request cancelled), which isn't reported.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// Cloud AI digests beat Apple's, which beat keyword grouping.
    nonisolated static func quality(_ summarizer: String) -> Int {
        switch summarizer {
        case KeywordSummarizer(topics: []).name: 1
        case AIProvider.apple.shortName: 2
        default: 3
        }
    }

    /// - Returns: `true` if a digest from `new` is at least as good as the existing one.
    nonisolated static func shouldReplace(existing: String, with new: String) -> Bool {
        quality(new) >= quality(existing)
    }

    /// The start of a look-back window of `days` days before `now`.
    nonisolated static func windowStart(days: Int, now: Date = .now) -> Date {
        now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
    }

    /// Fetches every enabled source at the same time. A failing source becomes a warning; the others continue.
    /// - Parameters:
    ///   - since: Start of the trend window.
    ///   - painSince: Start of the (longer) window for Pain points and App Store complaints.
    ///   - topics: The user's topics (used by GitHub).
    /// - Returns: De-duplicated items in source order, and one warning per failed source.
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

    // MARK: - Delete all my data

    /// Security/privacy: erases everything IdeaScout keeps about the user on this iPhone: history, ideas,
    /// saved projects, settings and consents, API keys, the cost ledger, cached downloads, pending
    /// notifications and the scheduled background refresh. Purchases aren't touched (Apple holds them;
    /// "Restore purchases" brings them back). The welcome screens show again afterwards.
    /// - Returns: `false` if a refresh is running (nothing is deleted).
    @discardableResult
    func deleteAllData() -> Bool {
        guard !isRefreshing, let context = container?.mainContext else { return false }
        Self.eraseAll(context: context, defaults: .standard, defaultsDomain: Bundle.main.bundleIdentifier ?? "",
                      keychainService: Keychain.service)
        URLCache.shared.removeAllCachedResponses()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        BGTaskScheduler.shared.cancelAllTaskRequests()
        lastError = nil
        return true
    }

    /// The erasing itself, with every store passed in so tests can use throwaway ones.
    /// - Parameters:
    ///   - context: Database to empty (digests, themes and items cascade; ideas and killer ideas too).
    ///   - defaults: Settings store to clear.
    ///   - defaultsDomain: Its domain name (the bundle ID for the real app).
    ///   - keychainService: Keychain service whose secrets are removed.
    nonisolated static func eraseAll(context: ModelContext, defaults: UserDefaults, defaultsDomain: String,
                                     keychainService: String) {
        try? context.delete(model: Digest.self)
        try? context.delete(model: Theme.self)
        try? context.delete(model: Item.self)
        try? context.delete(model: Idea.self)
        try? context.delete(model: KillerIdea.self)
        try? context.save()
        Keychain.removeAll(service: keychainService)
        // Remove keys one by one first so screens using @AppStorage update immediately, then the whole domain.
        for key in (defaults.persistentDomain(forName: defaultsDomain) ?? [:]).keys { defaults.removeObject(forKey: key) }
        defaults.removePersistentDomain(forName: defaultsDomain)
        defaults.set(false, forKey: AppSettings.Keys.onboarded)   // shows the welcome screens again
        // Mark the install as known, so the next launch doesn't treat it as a fresh install of a used phone.
        defaults.set(true, forKey: "keychain.installMarker")
        defaults.set(true, forKey: "keychain.thisDeviceOnly")
    }

    // MARK: - Retired sources

    /// Product Hunt was removed (its API terms don't allow this use). Deletes its stored items and the
    /// saved token, once. Starred projects are the user's own and are kept.
    func removeRetiredSources() {
        let doneKey = "retired.productHunt"
        guard !UserDefaults.standard.bool(forKey: doneKey), let context = container?.mainContext else { return }
        let retired = "productHunt"
        let items = (try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.sourceRaw == retired }))) ?? []
        items.forEach(context.delete)
        try? context.save()
        Keychain.delete(account: "productHuntToken")
        UserDefaults.standard.removeObject(forKey: "source.productHunt")
        UserDefaults.standard.set(true, forKey: doneKey)
    }

    // MARK: - Killer ideas

    /// The leaderboard's top ideas (including dismissed ones), best first. Sent to the idea step so a
    /// returning idea keeps its title.
    /// - Parameters:
    ///   - context: The database context.
    ///   - limit: How many to return.
    func topKillerIdeas(context: ModelContext, limit: Int) -> [KillerIdea] {
        let all = (try? context.fetch(FetchDescriptor<KillerIdea>())) ?? []
        return Array(all.sorted { $0.leaderboardScore > $1.leaderboardScore }.prefix(limit))
    }

    /// Adds new killer ideas, or updates ones that came back (they climb the leaderboard). An idea matches an
    /// existing one by the AI's `same_as` title or by its own title. Coming back un-dismisses it and records the day.
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
            idea.isDismissed = false   // proposed again, so it returns to the leaderboard
            idea.lastSeen = .now
            idea.scoreHistory.append(idea.killerScore)
        }
    }

    // MARK: - Saved ideas

    /// Stars a project (copies it into Saved projects) or unstars it, and saves.
    func toggleStar(_ item: Item, ideas: [Idea], context: ModelContext) {
        if let idea = ideas.first(where: { $0.key == item.key }) {
            context.delete(idea)
        } else {
            context.insert(Idea(from: item))
        }
        try? context.save()
    }

    /// Asks the current AI for money-making variants of a saved project and stores them on it.
    /// - Throws: `SummarizerError.unavailable` in keyword mode, or AI errors.
    func suggestExtensions(for idea: Idea) async throws {
        let summarizer = AppSettings.makeSummarizer()
        // Paid AI calls respect the daily spending limit, like refreshes do.
        if summarizer is LLMSummarizer && AppSettings.isOverDailyCap { throw SummarizerError.overDailyLimit }
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

    /// Called when iOS grants a background refresh: books the next one, then refreshes (only if today has
    /// no digest yet) and notifies. Stops cleanly if iOS ends the background time.
    func runBackgroundRefresh() async {
        scheduleBackgroundRefresh()
        await refresh(force: false, notify: true, cancelWithCaller: true)
    }

    /// The next time the clock shows `hour`:00 after `date` (today if still ahead, otherwise tomorrow).
    nonisolated static func nextOccurrence(ofHour hour: Int, after date: Date) -> Date {
        Calendar.current.nextDate(after: date, matching: DateComponents(hour: hour, minute: 0), matchingPolicy: .nextTime) ?? date
    }
}
