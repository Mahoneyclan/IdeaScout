// RootView.swift
// The app's top level: four tabs (Ideas, History, Saved, Settings), the first-launch welcome screens and
// the automatic refresh when the app opens. Also the History list.

import SwiftUI
import SwiftData

/// The tab bar. Shows the welcome screens until they're finished, then starts the day's automatic refresh
/// (which does nothing if today's digest already exists).
struct RootView: View {
    @Environment(DigestService.self) private var service
    /// Whether the welcome screens are done.
    @AppStorage(AppSettings.Keys.onboarded) private var onboarded = false

    var body: some View {
        TabView {
            Tab("Ideas", systemImage: "trophy") { LeaderboardView() }
            Tab("History", systemImage: "calendar") { HistoryView() }
            Tab("Saved", systemImage: "bookmark") { IdeasView() }
            Tab("Settings", systemImage: "gearshape") { SettingsView() }
        }
        .fullScreenCover(isPresented: Binding(get: { !onboarded && !AppSettings.isRunningTests }, set: { _ in })) {
            WelcomeView()
        }
        // The first automatic refresh waits until the welcome screens are finished.
        .task(id: onboarded) { if onboarded && !AppSettings.isRunningTests { await service.refresh(force: false) } }
    }
}

/// Every daily digest, newest first. Each row shows the day's best idea and pain clusters;
/// tapping a day shows its ideas, pain clusters and trends.
struct HistoryView: View {
    @Environment(DigestService.self) private var service
    @Query(sort: \Digest.day, order: .reverse) private var digests: [Digest]
    /// All killer ideas, to find each day's best.
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

/// One day in History: the date ("Today" for today), its best idea with Killer/Near-miss, and its
/// pain clusters (or its top trends when there are none).
struct HistoryRow: View {
    /// The day to summarise.
    let digest: Digest
    /// The best idea proposed that day, if any.
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
