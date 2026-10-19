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
                    DigestContentView(digest: today, showKillerIdeas: true)
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
            .navigationSubtitle("Trends from the past 7 days")
            .toolbar {
                if service.isRefreshing && today != nil { ProgressView() }
            }
            .refreshable { await service.refresh(force: true) }
            .task { if !AppSettings.isRunningTests { await service.refresh(force: false) } }
        }
    }
}

/// The themes and items of one digest. Used by Today and History.
struct DigestContentView: View {
    let digest: Digest
    var showKillerIdeas = false
    @Query private var killerIdeas: [KillerIdea]
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var service: DigestService
    @Query private var ideas: [Idea]
    @AppStorage(AppSettings.Keys.weightNovelty) private var wNovelty = 1.0
    @AppStorage(AppSettings.Keys.weightMomentum) private var wMomentum = 1.0
    @AppStorage(AppSettings.Keys.weightViability) private var wViability = 1.0
    @AppStorage(AppSettings.Keys.weightGap) private var wGap = 1.0
    @AppStorage("filter.gamesOnly") private var gamesOnly = false
    @AppStorage(AppSettings.Keys.qualityBar) private var qualityBar = AppSettings.defaultQualityBar
    @State private var showBelowBar = false

    private var weights: RankWeights {
        RankWeights(novelty: wNovelty, momentum: wMomentum, viability: wViability, gap: wGap)
    }

    /// With "Games only", keeps trends that contain games and shows only their game projects.
    private func visibleItems(_ theme: Theme) -> [Item] {
        gamesOnly ? theme.sortedItems.filter { $0.source == .games } : theme.sortedItems
    }

    var body: some View {
        let starred = Set(ideas.map(\.key))
        let withItems = Theme.ranked(digest.themes, weights: weights).filter { !visibleItems($0).isEmpty }
        let themes = showBelowBar ? withItems : withItems.filter { $0.clears(qualityBar, weights: weights) }
        let hiddenCount = withItems.count - themes.count
        let todaysKillers = killerIdeas.filter { $0.isFromToday && $0.killerScore >= qualityBar }
            .sorted { $0.killerScore > $1.killerScore }
        List {
            if showKillerIdeas && !gamesOnly && !todaysKillers.isEmpty {
                Section {
                    ForEach(todaysKillers, id: \.key) { idea in
                        NavigationLink { KillerIdeaDetailView(idea: idea) } label: { KillerIdeaCard(idea: idea) }
                    }
                } header: {
                    Label("Killer ideas today", systemImage: "flame")
                } footer: {
                    Text("Survived a devil's-advocate check. See all in Top Ideas.")
                }
            }
            ForEach(themes) { theme in
                Section {
                    Text(theme.summary).font(.subheadline)
                    if !theme.isCatchAll && theme.scores != ThemeScores() {
                        DisclosureGroup {
                            ScoreReasonsView(scores: theme.scores, reasons: theme.reasons)
                        } label: {
                            ScoreBadges(scores: theme.scores)
                        }
                    }
                    if !theme.opportunities.isEmpty {
                        DisclosureGroup {
                            ForEach(theme.opportunities, id: \.self) { idea in
                                Label(idea, systemImage: "lightbulb").font(.subheadline)
                            }
                        } label: {
                            Label("Money-making variants", systemImage: "dollarsign.circle").font(.subheadline.bold())
                        }
                    }
                    ForEach(visibleItems(theme)) { item in
                        ItemRow(item: item, isStarred: starred.contains(item.key)) {
                            service.toggleStar(item, ideas: ideas, context: context)
                        }
                    }
                } header: {
                    HStack {
                        Text(theme.title)
                        Spacer()
                        if !theme.isCatchAll, let overall = theme.scores.overall(weights) {
                            Text(overall, format: .number.precision(.fractionLength(1)))
                                .monospacedDigit()
                                .accessibilityLabel("Overall score \(overall.formatted(.number.precision(.fractionLength(1)))) out of 5")
                        }
                    }
                }
            }
            if hiddenCount > 0 || showBelowBar {
                Section {
                    Toggle("Show trends below the quality bar", isOn: $showBelowBar)
                } footer: {
                    Text(showBelowBar ? "Showing everything." :
                            "\(hiddenCount) trend\(hiddenCount == 1 ? "" : "s") scored below \(qualityBar.formatted()) / 5 and \(hiddenCount == 1 ? "is" : "are") hidden. Change the bar in Settings.")
                }
            }
            Section {
                Text("Summarised by \(digest.summarizer) · \(digest.itemCount) projects")
                ForEach(digest.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle") }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .overlay {
            if themes.isEmpty && gamesOnly && hiddenCount == 0 {
                ContentUnavailableView("No games in this digest", systemImage: "gamecontroller",
                                       description: Text("Turn on the Games source in Settings, or switch the filter back to All."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Picker("Show", selection: $gamesOnly) {
                    Label("All", systemImage: "square.grid.2x2").tag(false)
                    Label("Games only", systemImage: "gamecontroller").tag(true)
                }
                .pickerStyle(.menu)
            }
        }
    }
}

/// The four ranking scores, shown compactly. Each score's full name is in its accessibility label.
struct ScoreBadges: View {
    let scores: ThemeScores

    static let metrics: [(name: String, symbol: String, value: KeyPath<ThemeScores, Int>)] = [
        ("Novelty", "sparkles", \.novelty),
        ("Momentum", "chart.line.uptrend.xyaxis", \.momentum),
        ("Viability", "checkmark.seal", \.viability),
        ("Opportunity gap", "arrow.triangle.branch", \.gap),
    ]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Self.metrics, id: \.name) { metric in
                let value = scores[keyPath: metric.value]
                if value > 0 {
                    Label("\(value)", systemImage: metric.symbol)
                        .labelStyle(.titleAndIcon)
                        .accessibilityLabel("\(metric.name) \(value) out of 5")
                }
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

struct ScoreReasonsView: View {
    let scores: ThemeScores
    let reasons: ScoreReasons

    var body: some View {
        let reasonText: [String: String] = ["Novelty": reasons.novelty, "Momentum": reasons.momentum,
                                            "Viability": reasons.viability, "Opportunity gap": reasons.gap]
        ForEach(ScoreBadges.metrics, id: \.name) { metric in
            let value = scores[keyPath: metric.value]
            if value > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    Label("\(metric.name): \(value)/5", systemImage: metric.symbol).font(.subheadline.bold())
                    if let text = reasonText[metric.name], !text.isEmpty {
                        Text(text).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
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
                if item.isNew {
                    Text("NEW").font(.caption2.bold()).foregroundStyle(.green)
                }
                Label(item.source.label, systemImage: item.source.symbol)
                if item.score > 0 { Label("\(item.score)", systemImage: "arrow.up") }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}
