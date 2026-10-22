// IdeaScoutApp.swift
// App entry point. Opens the SwiftData database, hands it to DigestService, injects the shared
// services into SwiftUI, and wires up the daily background refresh.

import SwiftUI
import SwiftData

/// The app itself. Owns the database container for its whole lifetime.
@main
struct IdeaScoutApp: App {
    /// The on-device database holding digests, themes, items, saved projects and killer ideas.
    let container: ModelContainer
    @Environment(\.scenePhase) private var scenePhase

    /// Opens the database before any view appears, because DigestService needs it for the first refresh.
    /// A database that can't be opened is unrecoverable, so the app stops with a clear message.
    /// Also runs the one-time clean-up of removed sources (Product Hunt).
    init() {
        TestMode.prepare()
        do {
            // UI tests use a throwaway in-memory database so the owner's real data is never touched.
            let config = ModelConfiguration(isStoredInMemoryOnly: TestMode.isUITesting)
            container = try ModelContainer(for: Digest.self, Theme.self, Item.self, Idea.self, KillerIdea.self,
                                           configurations: config)
        } catch {
            fatalError("Could not open the IdeaScout database: \(error)")
        }
        // Security: clear keys left by a previous install and upgrade older keys to "this device only".
        if !TestMode.isUITesting { Keychain.prepareOnLaunch() }
        DigestService.shared.container = container
        if !TestMode.isUITesting { DigestService.shared.removeRetiredSources() }
    }

    /// One window with the tab bar, the shared services injected, and StoreKit loaded at launch.
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(DigestService.shared)
                .environment(StoreManager.shared)
                .defaultAppStorage(AppSettings.defaults)   // @AppStorage uses the UI-test store in test mode
                .task { await StoreManager.shared.load() }
        }
        .modelContainer(container)
        /// Each time the app goes to the background, ask iOS for the next daily refresh.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { DigestService.shared.scheduleBackgroundRefresh() }
        }
        /// Runs when iOS grants a background refresh. SwiftUI cancels this task when iOS ends the
        /// background time; DigestService passes that cancellation on so the work stops cleanly.
        .backgroundTask(.appRefresh(DigestService.backgroundTaskID)) {
            await DigestService.shared.runBackgroundRefresh()
        }
    }
}
