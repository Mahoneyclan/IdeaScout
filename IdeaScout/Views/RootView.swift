import SwiftUI
import SwiftData

struct RootView: View {
    @EnvironmentObject private var service: DigestService

    var body: some View {
        TabView {
            Tab("Ideas", systemImage: "trophy") { LeaderboardView() }
            Tab("History", systemImage: "calendar") { HistoryView() }
            Tab("Saved", systemImage: "bookmark") { IdeasView() }
            Tab("Settings", systemImage: "gearshape") { SettingsView() }
        }
        .task { if !AppSettings.isRunningTests { await service.refresh(force: false) } }
    }
}

/// Every daily digest, newest first. Each row shows the day's best idea and pain clusters;
/// tapping a day shows its ideas, pain clusters and trends.
struct HistoryView: View {
    @EnvironmentObject private var service: DigestService
    @Query(sort: \Digest.day, order: .reverse) private var digests: [Digest]
    @Query private var ideas: [KillerIdea]
    @AppStorage(AppSettings.Keys.trendWindowDays) private var windowDays = AppSettings.defaultTrendWindowDays

    var body: some View {
        NavigationStack {
            List(digests) { digest in
                NavigationLink {
                    DigestContentView(digest: digest)
                        .navigationTitle(digest.day.formatted(date: .abbreviated, time: .omitted))
                        .navigationSubtitle("Trends from the \(windowDays) days before")
                } label: {
                    HistoryRow(digest: digest, best: KillerIdea.seen(on: digest.day, in: ideas).first)
                }
            }
            .overlay {
                if digests.isEmpty {
                    ContentUnavailableView("No digests yet", systemImage: "calendar",
                                           description: Text("Each day's ideas, pain clusters and trends will appear here."))
                }
            }
            .navigationTitle("History")
            .safeAreaInset(edge: .bottom) { RefreshBar() }
        }
    }
}

struct HistoryRow: View {
    let digest: Digest
    let best: KillerIdea?

    var body: some View {
        let clusters = digest.sortedThemes.filter(\.isPainCluster)
        VStack(alignment: .leading, spacing: 4) {
            Text(Calendar.current.isDateInToday(digest.day) ? "Today" : digest.day.formatted(date: .complete, time: .omitted))
                .font(.headline)
            if let best {
                HStack(alignment: .firstTextBaseline) {
                    Label(best.title, systemImage: "flame").font(.subheadline.weight(.medium))
                    Spacer()
                    KillerStatusLabel(score: best.killerScore)
                }
            }
            if !clusters.isEmpty {
                Text("Pains: " + clusters.prefix(3).map(\.title).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text(digest.sortedThemes.filter { !$0.isCatchAll }.prefix(3).map(\.title).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}
