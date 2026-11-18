// IdeaScoutApp.swift
// App entry point. Opens the SwiftData database, hands it to DigestService, injects the shared
// services into SwiftUI, and wires up the daily background refresh.

import SwiftUI
import SwiftData

/// The app itself. Owns the database container for its whole lifetime.
@main
struct IdeaScoutApp: App {
    /// The database holding digests, themes, items, saved projects and killer ideas, synced through iCloud.
    let container: ModelContainer
    @Environment(\.scenePhase) private var scenePhase

    /// Opens the database before any view appears, because DigestService needs it for the first refresh.
    /// A database that can't be opened is unrecoverable, so the app stops with a clear message.
    /// Also runs the one-time clean-up of removed sources (Product Hunt).
    init() {
        TestMode.prepare()
        AppSettings.moveDailyCapToCurrentChoices()
        container = Self.openDatabase()
        CloudSync.start()
        SyncHousekeeping.mergeDuplicates(in: container.mainContext)
        // Security: clear keys left by a previous install and upgrade older keys to "this device only".
        if !TestMode.isUITesting { Keychain.prepareOnLaunch() }
        DigestService.shared.container = container
        if !TestMode.isUITesting { DigestService.shared.removeRetiredSources() }
        SyncHousekeeping.watchForRemoteChanges(container)
    }

    /// The database, synced through the user's private iCloud database (owner's decision, 12 Nov 2026). If iCloud
    /// can't be used (for example a setup problem), it opens on this device only rather than not at all, and says so
    /// in About & privacy. UI tests use a throwaway in-memory database and unit tests never sync, so the owner's real
    /// data is never touched.
    private static func openDatabase() -> ModelContainer {
        let models: [any PersistentModel.Type] = [Digest.self, Theme.self, Item.self, Idea.self, KillerIdea.self]
        let local = ModelConfiguration(isStoredInMemoryOnly: TestMode.isUITesting, cloudKitDatabase: .none)
        if CloudSync.isEnabled {
            do {
                return try ModelContainer(for: Schema(models),
                                          configurations: ModelConfiguration(cloudKitDatabase: .private(CloudSync.containerID)))
            } catch {
                CloudSync.databaseSyncFailed = true
            }
        }
        do {
            return try ModelContainer(for: Schema(models), configurations: local)
        } catch {
            fatalError("Could not open the IdeaScout database: \(error)")
        }
    }

    /// One window with the tab bar, the shared services injected, and StoreKit loaded at launch.
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(DigestService.shared)
                .environment(TipStore.shared)
                .defaultAppStorage(AppSettings.defaults)   // @AppStorage uses the UI-test store in test mode
                .task { await TipStore.shared.load() }
        }
        .modelContainer(container)
        /// Each time the app goes to the background, ask iOS for the next daily refresh.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { DigestService.shared.scheduleBackgroundRefresh() }
            if phase == .active { SyncHousekeeping.mergeDuplicates(in: container.mainContext) }
        }
        /// Runs when iOS grants a background refresh. SwiftUI cancels this task when iOS ends the
        /// background time; DigestService passes that cancellation on so the work stops cleanly.
        .backgroundTask(.appRefresh(DigestService.backgroundTaskID)) {
            await DigestService.shared.runBackgroundRefresh()
        }
    }
}
