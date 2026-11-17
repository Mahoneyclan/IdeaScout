// DigestService+Housekeeping.swift
// DigestService work outside the refresh itself: "Delete all my data", the one-time removal of retired
// sources, starring projects and variant suggestions, and scheduling the daily background refresh.

import Foundation
import SwiftData
import BackgroundTasks
import UserNotifications

extension DigestService {
    // MARK: - Delete all my data

    /// Security/privacy: erases everything IdeaScout keeps about the user on this device and in their iCloud (so on
    /// their other devices too): history, ideas,
    /// saved projects, settings and consents, API keys, the cost ledger, cached downloads, pending
    /// notifications and the scheduled background refresh. Purchases aren't touched (Apple holds them;
    /// "Restore purchases" brings them back). The welcome screens show again afterwards.
    /// - Returns: `false` if a refresh is running (nothing is deleted).
    /// - Note: If part of the database couldn't be deleted, everything else is still erased and
    ///   `lastError` tells the user to try again (they land on the welcome screens, then the Ideas tab).
    @discardableResult
    func deleteAllData() -> Bool {
        guard !isRefreshing, let context = container?.mainContext else { return false }
        let complete = Self.eraseAll(context: context, defaults: AppSettings.defaults,
                                     defaultsDomain: TestMode.isUITesting ? TestMode.defaultsSuite : (Bundle.main.bundleIdentifier ?? ""),
                                     keychainService: Keychain.service, cloudStore: CloudSync.store)
        URLCache.shared.removeAllCachedResponses()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        BGTaskScheduler.shared.cancelAllTaskRequests()
        lastError = complete ? nil : Self.incompleteDeletionMessage
        return true
    }

    /// Shown on the Ideas tab when some stored data survived "Delete all my data".
    nonisolated static let incompleteDeletionMessage =
        "Some of your history couldn't be deleted. Open Settings → About & privacy and tap Delete all my data again."

    /// The erasing itself, with every store passed in so tests can use throwaway ones.
    /// - Parameters:
    ///   - context: Database to empty (digests, themes and items cascade; ideas and killer ideas too).
    ///   - defaults: Settings store to clear.
    ///   - defaultsDomain: Its domain name (the bundle ID for the real app).
    ///   - keychainService: Keychain service whose secrets are removed.
    ///   - cloudStore: iCloud key-value storage to empty (shared settings and spending), or `nil` in tests.
    /// - Returns: `true` if the database was fully emptied and saved; `false` if any step failed.
    @discardableResult
    nonisolated static func eraseAll(context: ModelContext, defaults: UserDefaults, defaultsDomain: String,
                                     keychainService: String, cloudStore: KeyValueStore? = nil) -> Bool {
        // Security/privacy: every step runs even if an earlier one fails, so a database error never
        // leaves API keys or settings behind, and the failure is reported instead of claiming success.
        var complete = true
        // One by one rather than in bulk: bulk deletes aren't sent to iCloud, so the copies there and on the user's
        // other devices would come back.
        func deleteEach<T: PersistentModel>(_ type: T.Type) throws { try context.fetch(FetchDescriptor<T>()).forEach(context.delete) }
        let deleteSteps: [() throws -> Void] = [
            { try deleteEach(Item.self) }, { try deleteEach(Theme.self) }, { try deleteEach(Digest.self) },
            { try deleteEach(Idea.self) }, { try deleteEach(KillerIdea.self) },
        ]
        for deleteStep in deleteSteps {
            do { try deleteStep() } catch { complete = false }
        }
        if context.saveOrReport("the deletion") != nil { complete = false }
        Keychain.removeAll(service: keychainService)
        CloudSync.eraseAll(in: cloudStore)
        ReimagineStore.deleteAll()
        // Remove keys one by one first so screens using @AppStorage update immediately, then the whole domain.
        for key in (defaults.persistentDomain(forName: defaultsDomain) ?? [:]).keys { defaults.removeObject(forKey: key) }
        defaults.removePersistentDomain(forName: defaultsDomain)
        defaults.set(false, forKey: AppSettings.Keys.onboarded)   // shows the welcome screens again
        // Mark the install as known, so the next launch doesn't treat it as a fresh install of a used phone.
        defaults.set(true, forKey: "keychain.installMarker")
        defaults.set(true, forKey: "keychain.thisDeviceOnly")
        return complete
    }

    // MARK: - Retired sources

    /// Product Hunt was removed (its API terms don't allow this use). Deletes its stored items and the
    /// saved token, once. Starred projects are the user's own and are kept. Also applies the 17 Nov 2026 source changes.
    func removeRetiredSources() {
        Self.applySourceChanges(defaults: AppSettings.defaults)
        let doneKey = "retired.productHunt"
        guard !AppSettings.defaults.bool(forKey: doneKey), let context = container?.mainContext else { return }
        let retired = "productHunt"
        let items = (try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.sourceRaw == retired }))) ?? []
        items.forEach(context.delete)
        context.saveOrReport("the removal of retired sources")
        Keychain.delete(account: "productHuntToken")
        AppSettings.defaults.removeObject(forKey: "source.productHunt")
        AppSettings.defaults.set(true, forKey: doneKey)
    }

    /// Owner's decision, 17 Nov 2026: Y Combinator is no longer read, and Atlassian Marketplace starts off for new
    /// installs only. Runs once: forgets the Y Combinator toggle and, on a phone that was already set up, keeps
    /// Atlassian on unless the user had switched it off. Y Combinator's old items are kept (unlike Product Hunt's,
    /// whose terms forbade the use), so earlier refreshes still show them.
    /// - Parameter defaults: The settings store.
    nonisolated static func applySourceChanges(defaults: UserDefaults) {
        let doneKey = "retired.ycombinator"
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.removeObject(forKey: AppSettings.Keys.sourceEnabled(.ycombinator))
        let atlassian = AppSettings.Keys.sourceEnabled(.atlassian)
        if defaults.bool(forKey: AppSettings.Keys.onboarded), defaults.object(forKey: atlassian) == nil {
            defaults.set(true, forKey: atlassian)
        }
        defaults.set(true, forKey: doneKey)
    }

    // MARK: - Saved ideas

    /// Stars a project (copies it into Saved projects) or unstars it, and saves.
    /// - Parameters:
    ///   - item: The project in a digest.
    ///   - ideas: The current saved projects, to find an existing copy by key.
    ///   - context: Where to insert or delete the saved copy.
    /// - Note: A save failure is shown through `lastError`.
    func toggleStar(_ item: Item, ideas: [Idea], context: ModelContext) {
        if let idea = ideas.first(where: { $0.key == item.key }) {
            context.delete(idea)
        } else {
            context.insert(Idea(from: item))
        }
        if let message = context.saveOrReport("your saved projects") { lastError = message }
    }

    /// Asks the current AI for money-making variants of a saved project and stores them on it.
    /// - Parameter idea: The saved project; its `extensions` are replaced on success.
    /// - Throws: `SummarizerError.unavailable` in keyword mode, or AI errors.
    func suggestExtensions(for idea: Idea) async throws {
        let summarizer = AppSettings.makeSummarizer()
        // Paid AI calls respect the daily spending limit, like refreshes do.
        if summarizer is LLMSummarizer && AppSettings.isOverDailyCap { throw SummarizerError.overDailyLimit }
        idea.extensions = try await summarizer.extensions(for: IdeaBrief(title: idea.title, detail: idea.detail, note: idea.note))
        if let message = container?.mainContext.saveOrReport("the suggestions") { lastError = message }
    }

    // MARK: - Background refresh

    /// Asks iOS to wake the app around the chosen hour. iOS decides the actual time, and may skip days.
    /// If iOS refuses the request (for example, Background App Refresh is off), the failure is ignored and
    /// refreshing by hand still works.
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
    /// - Parameters:
    ///   - hour: 0–23 in the phone's calendar and time zone.
    ///   - date: The starting point.
    /// - Returns: That moment, or `date` itself if the calendar can't find one.
    nonisolated static func nextOccurrence(ofHour hour: Int, after date: Date) -> Date {
        Calendar.current.nextDate(after: date, matching: DateComponents(hour: hour, minute: 0), matchingPolicy: .nextTime) ?? date
    }
}
