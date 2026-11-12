// DigestService.swift
// Runs a refresh and saves the result. The steps, in order:
//  1. Check the trial/unlock (StoreManager); stop with a message if refreshes aren't allowed.
//  2. Fetch every enabled source in parallel (the files in Sources/); remove duplicates and noise.
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
@Observable
final class DigestService {
    /// The single shared instance, injected into SwiftUI by IdeaScoutApp.
    static let shared = DigestService(dependencies: TestMode.isUITesting ? TestMode.dependencies : .live)

    /// Everything a refresh depends on outside this class. The app uses `.live`; tests pass stand-ins
    /// (fake sources, a scripted AI, a fixed trial state) so every refresh rule can be tested offline.
    struct Dependencies {
        /// The sources to fetch, in priority order (earlier sources keep their label on duplicates).
        var makeFetchers: @MainActor () -> [any ItemFetcher]
        /// The AI to use (respecting provider choice, keys and consent).
        var makeSummarizer: @MainActor () -> any Summarizer
        /// The free AI to switch to when the daily spending limit is reached.
        var freeSummarizer: @MainActor () -> any Summarizer
        /// The current trial/unlock state.
        var access: @MainActor () async -> StoreManager.Access
        /// Whether today's AI spending has reached the limit.
        var isOverDailyCap: @MainActor () -> Bool
        /// Whether a cloud provider is chosen with a key but no consent.
        var needsConsent: @MainActor () -> Bool
        /// Posts the "ideas are ready" notification.
        var notify: @MainActor (_ themes: Int, _ items: Int) async -> Void
        /// A client for one scan step when Claude's "Mixed" is chosen; `nil` uses the summariser's own client.
        var stepClient: @MainActor (ScanStep) -> (any LLMClient)? = { _ in nil }
        /// The client for the web price check (Claude Haiku 5.5 with web search); `nil` skips it.
        var priceChecker: @MainActor () -> (any WebSearchClient & LLMClient)? = { nil }

        /// The real app: settings, Keychain, StoreKit and notifications.
        static let live = Dependencies(
            makeFetchers: { DigestService.enabledFetchers() },
            makeSummarizer: { AppSettings.makeSummarizer() },
            freeSummarizer: {
                AppleSummarizer.isAvailable ? AppleSummarizer() as any Summarizer : KeywordSummarizer(topics: AppSettings.topics)
            },
            access: {
                await StoreManager.shared.ensureLoaded()
                return StoreManager.shared.access
            },
            isOverDailyCap: { AppSettings.isOverDailyCap },
            needsConsent: { AppSettings.needsConsent },
            notify: { themes, items in await Notifier.digestReady(themes: themes, items: items) },
            stepClient: { AppSettings.stepClient($0) },
            priceChecker: { AppSettings.priceCheckClient() })
    }

    /// What this instance uses for sources, AI, trial state and notifications.
    @ObservationIgnored let dependencies: Dependencies

    /// Creates the service. The app uses one shared instance; tests create their own.
    /// - Parameter dependencies: `.live` in the app; stand-ins in tests.
    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }
    /// Must match BGTaskSchedulerPermittedIdentifiers in project.yml.
    static let backgroundTaskID = "com.mahoney.IdeaScout.refresh"

    /// True while a refresh runs (drives the progress row and disables the refresh button).
    private(set) var isRefreshing = false
    /// Which step a running refresh is on, for the progress shown on screen.
    private(set) var stage: Stage?

    /// Refresh steps shown as "Step n of 4". Raw values are the step numbers.
    enum Stage: Int, CaseIterable {
        /// Steps 1–5: fetch sources, trend step, idea step (pass 1), devil's advocate (pass 2), web price check.
        case fetching = 1, trends, ideas, critique, priceCheck
        /// Plain-English step name.
        var label: String {
            switch self {
            case .fetching: "Fetching sources"
            case .trends: "Reading items and finding trends"
            case .ideas: "Generating ideas"
            case .critique: "Devil's advocate"
            case .priceCheck: "Checking competitor prices on the web"
            }
        }
    }
    /// Why the last refresh didn't produce a new digest (trial ended, nothing found, kept an earlier
    /// digest…), shown on the Ideas tab. Cleared when a refresh starts.
    var lastError: String?
    /// The key of the idea whose starter kit is being made, or `nil`. Only one kit is made at a time.
    var makingStarterKitFor: String?
    /// The key of the idea being improved, or `nil`. Only one improvement runs at a time.
    var improvingIdea: String?
    /// What the running improvement is doing, for the screen ("Round 2 of 3: rewriting…").
    var improveStep = ""

    /// The database, set by IdeaScoutApp at launch. Refreshes do nothing until it's set.
    @ObservationIgnored var container: ModelContainer?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

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
        guard force || Self.needsRebuild(existing: existing.map(\.summarizer),
                                         aiAvailable: !(dependencies.makeSummarizer() is KeywordSummarizer)) else { return }
        // iCloud sync: an automatic scan waits when the user's other device has just started today's, so it isn't paid
        // for twice; its results arrive through iCloud. Tapping refresh still runs one here.
        if !force && CloudSync.otherDeviceIsScanning(CloudSync.scanNote()) {
            lastError = "Your other device is finding today's ideas. They'll appear here when it's done."
            return
        }

        // After the free trial, new refreshes need the one-off unlock. Saved history stays readable.
        let access = await dependencies.access()
        guard access.canRefresh else {
            lastError = access == .notStarted
                ? "Start your free 7-day trial to find new ideas."
                : "Your free trial has ended. Unlock IdeaScout to keep finding new ideas."
            return
        }

        isRefreshing = true
        stage = .fetching
        lastError = nil
        CloudSync.noteScanStarted()
        defer { isRefreshing = false; stage = nil }

        let (items, fetchWarnings) = await collectItems()
        if Task.isCancelled { return }
        guard !items.isEmpty else {
            lastError = fetchWarnings.isEmpty ? "No new projects found. Try again later." : fetchWarnings.joined(separator: "\n")
            return
        }

        stage = .trends
        guard let trends = await findTrends(in: items, warnings: fetchWarnings) else { return }   // cancelled

        // Never replace a better digest from earlier today (e.g. cloud AI) with a weaker one (e.g. keywords).
        if let kept = existing.max(by: { Self.quality($0.summarizer) < Self.quality($1.summarizer) }),
           !Self.shouldReplace(existing: kept.summarizer, with: trends.summarizer.name) {
            let time = Date.now.formatted(date: .omitted, time: .shortened)
            let reason = trends.warnings.last.map { DigestWarning.parts($0).message } ?? "unknown error"
            let note = "Refresh at \(time) didn't work (\(reason)). Kept the earlier \(kept.summarizer) digest."
            kept.warnings.append(note)
            context.saveOrReport("the refresh note")
            lastError = note
            return
        }

        // Save the trends straight away, so a later failure (or iOS stopping the app) can't lose them.
        let builtThemes = ThemeBuilder.assemble(trends.drafts, items: trends.batch, noise: trends.noise)
        existing.forEach(context.delete)
        let digest = saveDigest(builtThemes, day: today, summarizer: trends.summarizer.name, warnings: trends.warnings, in: context)

        await addIdeas(to: digest, trends: trends, themes: builtThemes, context: context)
        if let message = context.saveOrReport("today's ideas") { lastError = message }

        if notify && !Task.isCancelled {
            await dependencies.notify(digest.themeList.count, digest.itemCount)
        }
    }

    /// Whether today's digest should be (re)built without `force`: none exists yet, or it fell back to
    /// keywords and an AI is now available.
    /// - Parameters:
    ///   - summarizers: The summariser names of today's existing digests (empty if none).
    ///   - aiAvailable: Whether an AI other than keywords can run now.
    /// - Returns: `true` if an automatic refresh should build today's digest.
    nonisolated static func needsRebuild(existing summarizers: [String], aiAvailable: Bool) -> Bool {
        summarizers.isEmpty || (summarizers.contains(KeywordSummarizer(topics: []).name) && aiAvailable)
    }

    // MARK: - Refresh steps

    /// Step 2–3: fetch every enabled source and choose the items the AI will read.
    /// - Returns: The chosen items, and one warning per failed source.
    private func collectItems() async -> (items: [FetchedItem], warnings: [String]) {
        // Trends are built from the chosen window (default a week) so a theme reflects several projects over
        // several days; pain points, which are rarer, use their own longer window. Items from the last 24 hours are "new".
        let since = Self.windowStart(days: AppSettings.trendWindowDays)
        let painSince = Self.windowStart(days: AppSettings.painWindowDays)
        let (fetched, warnings) = await fetchAll(since: since, painSince: painSince, topics: AppSettings.topics)
        let useful = fetched.filter { $0.source == .fieldNotes || ProductFilter.isProductShaped($0) }
        return (Self.selectBySignal(useful, maxItems: AppSettings.claudeMaxItems,
                                    areaWords: AreaFocus.words(in: AppSettings.interestArea)), warnings)
    }

    /// What the trend step produced, carried through to saving and the idea step.
    struct TrendResult {
        /// The summariser that produced the drafts (keywords if the AI failed).
        var summarizer: any Summarizer
        /// Trends and pain clusters.
        var drafts: [ThemeDraft]
        /// 1-based item numbers judged noise (never the user's own pain points).
        var noise: Set<Int>
        /// The items the summariser saw (translated where needed), in prompt order.
        var batch: [FetchedItem]
        /// Warnings so far: failed sources, consent, spending limit, AI failure.
        var warnings: [String]
        /// Why the idea step won't run, if it won't (limit reached, or the AI failed).
        var killerNote: String?
        /// Whether a cloud AI was available before any limit or failure.
        var hadCloudAI: Bool
    }

    /// Steps 4–5: choose the AI (consent, spending limit) and build trends and pain clusters, falling back
    /// to keyword grouping if the AI fails.
    /// - Returns: The result, or `nil` if the refresh was cancelled (nothing should be saved).
    private func findTrends(in items: [FetchedItem], warnings fetchWarnings: [String]) async -> TrendResult? {
        var summarizer = dependencies.makeSummarizer()
        if summarizer is LLMSummarizer, let reader = dependencies.stepClient(.reading) { summarizer = LLMSummarizer(client: reader) }
        let hadCloudAI = summarizer is LLMSummarizer
        var warnings = fetchWarnings
        var killerNote: String?
        if dependencies.needsConsent() {
            warnings.append("\(AppSettings.provider.shortName) wasn't used because you haven't agreed to share data with it. Agree in Settings → Advanced → AI & costs.")
        }
        if hadCloudAI && dependencies.isOverDailyCap() {
            warnings.append("Today's AI spending limit (\(Self.capText)) is reached, so \(summarizer.name) was skipped. Change it in Settings → AI & costs.")
            killerNote = "Killer ideas skipped: daily spending limit reached."
            summarizer = dependencies.freeSummarizer()
        }

        // A cloud AI translates non-English items; without one, leave out items that clearly aren't English.
        let candidates = summarizer is LLMSummarizer ? items : items.filter(LanguageFilter.isEnglishOrUnclear)
        var batch = Array(candidates.prefix(summarizer.maxItems))
        do {
            let analysis = try await summarizer.analyse(batch)
            // Never treat the owner's own field notes as noise.
            let noise = analysis.noise.filter { batch.indices.contains($0 - 1) && batch[$0 - 1].source != .fieldNotes }
            batch = Translations.apply(analysis.translations, to: batch)
            return TrendResult(summarizer: summarizer, drafts: analysis.drafts, noise: noise, batch: batch,
                               warnings: warnings, killerNote: killerNote, hadCloudAI: hadCloudAI)
        } catch {
            if Self.isCancellation(error) || Task.isCancelled { return nil }  // don't save a half-finished digest
            let failure = DigestWarning.describe(error)
            warnings.append(DigestWarning.make("\(summarizer.name) summary failed: \(failure.message) Grouped by keyword instead.",
                                               details: failure.details))
            if summarizer is LLMSummarizer { killerNote = "Killer ideas skipped because the \(summarizer.name) summary failed." }
            let keywords = KeywordSummarizer(topics: AppSettings.topics)
            batch = batch.filter(LanguageFilter.isEnglishOrUnclear)
            let drafts = (try? await keywords.themes(for: batch)) ?? []
            return TrendResult(summarizer: keywords, drafts: drafts, noise: [], batch: batch,
                               warnings: warnings, killerNote: killerNote, hadCloudAI: hadCloudAI)
        }
    }

    /// Step 7: stores the digest with its themes and items.
    /// - Returns: The saved digest.
    private func saveDigest(_ builtThemes: [ThemeBuilder.Built], day: Date, summarizer: String, warnings: [String],
                            in context: ModelContext) -> Digest {
        let digest = Digest(day: day, summarizer: summarizer, warnings: warnings)
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
        if let message = context.saveOrReport("today's digest") { lastError = message }
        return digest
    }

    /// Step 8: the idea step (cloud AI only). Adds a warning to the digest when it can't run or fails;
    /// a failure here keeps the saved digest.
    private func addIdeas(to digest: Digest, trends: TrendResult, themes builtThemes: [ThemeBuilder.Built],
                          context: ModelContext) async {
        guard let llm = trends.summarizer as? LLMSummarizer else {
            if let note = trends.killerNote {
                digest.warnings.append(note)
            } else if !trends.hadCloudAI {
                digest.warnings.append("Killer ideas need a cloud AI (e.g. Claude or ChatGPT): choose one and add its API key in Settings → AI & costs.")
            }
            return
        }
        if dependencies.isOverDailyCap() {
            digest.warnings.append("Killer ideas skipped: today's AI spending limit (\(Self.capText)) was reached during the trend step.")
            return
        }
        do {
            let leaderboard = topKillerIdeas(context: context, limit: 10).map(Self.leaderboardLine)
            stage = .ideas
            // `onCritique` is called from the engine off the main actor; it hops back to update `stage`,
            // which drives the progress row ("Step … · Devil's advocate").
            let service = self
            let writer = dependencies.stepClient(.writing).map { LLMSummarizer(client: $0) } ?? llm
            let results = try await KillerEngine(llm: writer, judge: dependencies.stepClient(.judging), onCritique: {
                await MainActor.run { service.stage = .critique }
            }).run(
                .init(themes: builtThemes, items: trends.batch, aboutMe: AppSettings.aboutMe, leaderboard: leaderboard,
                      interestArea: AppSettings.interestArea, tool: AppSettings.builderTool, appType: AppSettings.appType,
                      painClusters: builtThemes.filter(\.isPainCluster).map {
                          "\($0.title) (buyer: \($0.buyer); today: \($0.workaround); pays: \($0.paySignals); \($0.items.count) items)"
                      }))
            let checked = await checkPrices(results, onStart: { service.stage = .priceCheck })
            if let warning = checked.warning { digest.warnings.append(warning) }
            mergeKillerIdeas(checked.results, items: trends.batch, context: context)
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

    /// The daily spending limit as currency text, for warnings.
    private static var capText: String { AppSettings.dailyCap.formatted(.currency(code: "USD")) }

    /// Whether an error means "stopped on purpose" (task cancelled or request cancelled), which isn't reported.
    /// - Parameter error: Any error from a refresh step.
    /// - Returns: `true` for `CancellationError` or a cancelled `URLError`.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// Cloud AI digests beat Apple's, which beat keyword grouping.
    /// - Parameter summarizer: A digest's summariser name.
    /// - Returns: 1 (keywords), 2 (Apple) or 3 (any cloud AI).
    nonisolated static func quality(_ summarizer: String) -> Int {
        switch summarizer {
        case KeywordSummarizer(topics: []).name: 1
        case AIProvider.apple.shortName: 2
        default: 3
        }
    }

    /// Decides whether a new digest replaces today's existing one.
    /// - Parameters:
    ///   - existing: The existing digest's summariser name.
    ///   - new: The new digest's summariser name.
    /// - Returns: `true` if a digest from `new` is at least as good as the existing one.
    nonisolated static func shouldReplace(existing: String, with new: String) -> Bool {
        quality(new) >= quality(existing)
    }

    /// The start of a look-back window of `days` days before `now`.
    /// - Parameters:
    ///   - days: Window length in days.
    ///   - now: The end of the window; tests pass a fixed date.
    /// - Returns: `now` minus `days` × 24 hours.
    nonisolated static func windowStart(days: Int, now: Date = .now) -> Date {
        now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
    }

    /// Fetches every source from `dependencies.makeFetchers` at the same time. A failing source becomes a warning; the others continue.
    /// - Parameters:
    ///   - since: Start of the trend window.
    ///   - painSince: Start of the (longer) window for Pain points and App Store complaints.
    ///   - topics: The user's topics (used by GitHub).
    /// - Returns: De-duplicated items in source order, and one warning per failed source.
    private func fetchAll(since: Date, painSince: Date, topics: [String]) async -> ([FetchedItem], [String]) {
        let fetchers = dependencies.makeFetchers()

        let results = await withTaskGroup(of: (Int, Result<[FetchedItem], Error>).self) { group in
            for (index, fetcher) in fetchers.enumerated() {
                group.addTask {
                    let start = [.painPoints, .appReviews, .consumerReviews, .areaDiscussion].contains(fetcher.kind) ? painSince : since
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
}
