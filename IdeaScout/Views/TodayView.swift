import SwiftUI
import SwiftData

struct TodayView: View {
    @EnvironmentObject private var service: DigestService
    @Query(sort: \Digest.day, order: .reverse) private var digests: [Digest]

    private var today: Digest? { digests.first { Calendar.current.isDateInToday($0.day) } }

    var body: some View {
        NavigationStack {
            Group {
                if let today {
                    DigestContentView(digest: today)
                } else if service.isRefreshing {
                    ProgressView("Scanning sources and finding themes…")
                } else {
                    ContentUnavailableView {
                        Label("No digest yet today", systemImage: "sparkles")
                    } description: {
                        Text(service.lastError ?? "Fetch today's new projects and themes.")
                    } actions: {
                        Button("Fetch today's ideas") { Task { await service.refresh(force: true) } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Today")
            .toolbar {
                if service.isRefreshing && today != nil { ProgressView() }
            }
            .refreshable { await service.refresh(force: true) }
            .task { await service.refresh(force: false) }
        }
    }
}

/// The themes and items of one digest. Used by Today and History.
struct DigestContentView: View {
    let digest: Digest
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var service: DigestService
    @Query private var ideas: [Idea]

    var body: some View {
        let starred = Set(ideas.map(\.key))
        List {
            ForEach(digest.sortedThemes) { theme in
                Section {
                    Text(theme.summary).font(.subheadline)
                    if !theme.opportunities.isEmpty {
                        DisclosureGroup {
                            ForEach(theme.opportunities, id: \.self) { idea in
                                Label(idea, systemImage: "lightbulb").font(.subheadline)
                            }
                        } label: {
                            Label("Build on this", systemImage: "arrow.up.right.circle").font(.subheadline.bold())
                        }
                    }
                    ForEach(theme.sortedItems) { item in
                        ItemRow(item: item, isStarred: starred.contains(item.key)) {
                            service.toggleStar(item, ideas: ideas, context: context)
                        }
                    }
                } header: {
                    Text(theme.title)
                }
            }
            Section {
                Text("Summarised by \(digest.summarizer) · \(digest.itemCount) projects")
                ForEach(digest.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle") }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

struct ItemRow: View {
    let item: Item
    let isStarred: Bool
    let toggleStar: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let url = item.url {
                Link(destination: url) { content }.buttonStyle(.plain)
            } else {
                content
            }
            Spacer(minLength: 0)
            Button(action: toggleStar) {
                Image(systemName: isStarred ? "star.fill" : "star")
                    .foregroundStyle(isStarred ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isStarred ? "Remove from ideas" : "Save to ideas")
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title).font(.body.weight(.medium))
            if !item.detail.isEmpty {
                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack(spacing: 8) {
                Label(item.source.label, systemImage: item.source.symbol)
                if item.score > 0 { Label("\(item.score)", systemImage: "arrow.up") }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}
