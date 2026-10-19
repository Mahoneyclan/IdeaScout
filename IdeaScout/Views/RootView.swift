import SwiftUI
import SwiftData

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Today", systemImage: "sun.max") { TodayView() }
            Tab("Top Ideas", systemImage: "trophy") { LeaderboardView() }
            Tab("History", systemImage: "calendar") { HistoryView() }
            Tab("Ideas", systemImage: "star") { IdeasView() }
            Tab("Settings", systemImage: "gearshape") { SettingsView() }
        }
    }
}

struct HistoryView: View {
    @Query(sort: \Digest.day, order: .reverse) private var digests: [Digest]

    var body: some View {
        NavigationStack {
            List(digests) { digest in
                NavigationLink {
                    DigestContentView(digest: digest)
                        .navigationTitle(digest.day.formatted(date: .abbreviated, time: .omitted))
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(digest.day.formatted(date: .complete, time: .omitted)).font(.headline)
                        Text(digest.sortedThemes.prefix(3).map(\.title).joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .overlay {
                if digests.isEmpty {
                    ContentUnavailableView("No digests yet", systemImage: "calendar",
                                           description: Text("Past daily digests will appear here."))
                }
            }
            .navigationTitle("History")
        }
    }
}
