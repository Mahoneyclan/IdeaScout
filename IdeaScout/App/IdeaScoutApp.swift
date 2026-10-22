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
        do {
            container = try ModelContainer(for: Digest.self, Theme.self, Item.self, Idea.self, KillerIdea.self)
        } catch {
            fatalError("Could not open the IdeaScout database: \(error)")
        }
        DigestService.shared.container = container
        DigestService.shared.removeRetiredSources()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(DigestService.shared)
                .environmentObject(StoreManager.shared)
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
