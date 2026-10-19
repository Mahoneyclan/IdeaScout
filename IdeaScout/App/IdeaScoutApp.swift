import SwiftUI
import SwiftData

@main
struct IdeaScoutApp: App {
    let container: ModelContainer
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do {
            container = try ModelContainer(for: Digest.self, Theme.self, Item.self, Idea.self)
        } catch {
            fatalError("Could not open the IdeaScout database: \(error)")
        }
        DigestService.shared.container = container
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(DigestService.shared)
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { DigestService.shared.scheduleBackgroundRefresh() }
        }
        .backgroundTask(.appRefresh(DigestService.backgroundTaskID)) {
            await DigestService.shared.runBackgroundRefresh()
        }
    }
}
