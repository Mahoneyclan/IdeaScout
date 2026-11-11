// DayView.swift
// One day's results (DigestContentView), opened from History or the Ideas tab's status row: that day's
// ideas, pain clusters, ranked trends with their projects, and the refresh's notes. Also the small
// pieces it uses: score badges, score reasons and the project row with its star.

import SwiftUI
import SwiftData

/// One day's digest: the ideas proposed that day, pain clusters and trends. Opened from History.
struct DigestContentView: View {
    /// The day to show.
    let digest: Digest
    /// All killer ideas, filtered to the ones proposed on this day.
    @Query private var killerIdeas: [KillerIdea]
    @Environment(\.modelContext) private var context
    @Environment(DigestService.self) private var service
    /// Starred projects, to show which rows are starred.
    @Query private var ideas: [Idea]
    /// The user's ranking weights, so trends re-rank as soon as they change.
    @AppStorage(AppSettings.Keys.weightNovelty) private var wNovelty = 1.0
    @AppStorage(AppSettings.Keys.weightMomentum) private var wMomentum = 1.0
    @AppStorage(AppSettings.Keys.weightViability) private var wViability = 1.0
    @AppStorage(AppSettings.Keys.weightGap) private var wGap = 1.0
    /// "Games only" filter, kept between launches.
    @AppStorage("filter.gamesOnly") private var gamesOnly = false
    /// The filter only applies while the Games source is on (otherwise its picker is hidden).
    private var gamesFilter: Bool { gamesOnly && AppSettings.isEnabled(.games) }
    @AppStorage(AppSettings.Keys.qualityBar) private var qualityBar = AppSettings.defaultQualityBar
    /// Whether trends below the quality bar are shown.
    @State private var showBelowBar = false
    /// Trends whose score breakdown is open (tap the score to toggle).
    @State private var expandedScores: Set<PersistentIdentifier> = []

    private var weights: RankWeights {
        RankWeights(novelty: wNovelty, momentum: wMomentum, viability: wViability, gap: wGap)
    }

    /// With "Games only", keeps trends that contain games and shows only their game projects.
    private func visibleItems(_ theme: Theme) -> [Item] {
        gamesFilter ? theme.sortedItems.filter { $0.source == .games } : theme.sortedItems
    }

    var body: some View {
        let starred = Set(ideas.map(\.key))
        let clusters = gamesFilter ? [] : digest.sortedThemes.filter(\.isPainCluster)
        let withItems = Theme.ranked(digest.themes.filter { !$0.isPainCluster }, weights: weights).filter { !visibleItems($0).isEmpty }
        let themes = showBelowBar ? withItems : withItems.filter { $0.clears(qualityBar, weights: weights) }
        let hiddenCount = withItems.count - themes.count
        let dayIdeas = KillerIdea.seen(on: digest.day, in: killerIdeas)
        List {
            if !gamesFilter && !dayIdeas.isEmpty {
                Section {
                    ForEach(dayIdeas, id: \.key) { idea in
                        NavigationLink { KillerIdeaDetailView(idea: idea) } label: { KillerIdeaCard(idea: idea) }
                    }
                } header: {
                    Label("Ideas from this day", systemImage: "flame")
                } footer: {
                    Text("Killer: at least \(qualityBar.formatted()) / 5. Near-miss: just below. Scores are the latest.")
                }
            }
            if !clusters.isEmpty {
                Section {
                    ForEach(clusters) { cluster in
                        DisclosureGroup {
                            if !cluster.workaround.isEmpty {
                                LabeledContent("Today they", value: cluster.workaround).font(.subheadline)
                            }
                            if !cluster.paySignals.isEmpty {
                                LabeledContent("Pay signals", value: cluster.paySignals).font(.subheadline)
                            }
                            ForEach(cluster.sortedItems) { item in
                                ItemRow(item: item, isStarred: starred.contains(item.key)) {
                                    service.toggleStar(item, ideas: ideas, context: context)
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cluster.title).font(.subheadline.bold())
                                Text("\(cluster.buyer) · \(cluster.items.count) item\(cluster.items.count == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Label("Pain clusters", systemImage: "exclamationmark.bubble")
                } footer: {
                    Text("Problems businesses complain about or pay to work around, from complaints, App Store reviews, government spending and your pain points.")
                }
            }
            ForEach(themes) { theme in
                Section {
                    Text(theme.summary).font(.subheadline)
                    if expandedScores.contains(theme.persistentModelID) {
                        ScoreReasonsView(scores: theme.scores, reasons: theme.reasons)
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
                            // Tap the score to see how it was reached.
                            let open = expandedScores.contains(theme.persistentModelID)
                            Button {
                                if open { expandedScores.remove(theme.persistentModelID) } else { expandedScores.insert(theme.persistentModelID) }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(overall, format: .number.precision(.fractionLength(1))).monospacedDigit()
                                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2)
                                }
                                .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Overall score \(overall.formatted(.number.precision(.fractionLength(1)))) out of 5")
                            .accessibilityHint(open ? "Hides the score breakdown" : "Shows the score breakdown")
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
                ForEach(digest.warnings, id: \.self) { WarningRow(warning: $0) }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .readableList()
        .overlay {
            if themes.isEmpty && gamesFilter && hiddenCount == 0 {
                ContentUnavailableView("No games in this digest", systemImage: "gamecontroller",
                                       description: Text("Turn on the Games source in Settings, or switch the filter back to All."))
            }
        }
        .toolbar {
            // Only offered when the Games source is switched on.
            if AppSettings.isEnabled(.games) {
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
}

/// One refresh note: the plain message, with any technical detail tucked behind "Details".
struct WarningRow: View {
    /// The stored warning (see DigestWarning).
    let warning: String

    var body: some View {
        let parts = DigestWarning.parts(warning)
        VStack(alignment: .leading, spacing: 4) {
            Label(parts.message, systemImage: "exclamationmark.triangle")
            if let details = parts.details {
                DisclosureGroup("Details") {
                    Text(details).font(.caption.monospaced()).textSelection(.enabled)
                }
                .font(.caption)
            }
        }
    }
}

// MARK: - Score pieces

/// The four ranking scores, shown compactly. Each score's full name is in its accessibility label.
struct ScoreBadges: View {
    /// The scores to show.
    let scores: ThemeScores

    /// Name, symbol and field of each trend score, in display order.
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

/// Each trend score with its one-sentence reason (scores of 0 are hidden).
struct ScoreReasonsView: View {
    /// The scores.
    let scores: ThemeScores
    /// Their reasons.
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

/// One project, post, review or contract. Tapping the text opens the original (web links only); the
/// star saves it to Saved projects. The star has its own 44-point target with a gap, so it isn't
/// confused with the link.
struct ItemRow: View {
    /// The item to show.
    let item: Item
    /// Whether it's already in Saved projects.
    let isStarred: Bool
    /// Called when the star is tapped.
    let toggleStar: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let url = item.url, url.isWebLink {   // Security: web links only; others (e.g. field notes) show as text
                Link(destination: url) { content }.buttonStyle(.plain)
            } else {
                content
            }
            Spacer(minLength: 0)
            Spacer(minLength: 12)   // dead zone between the link and the star
            Button(action: toggleStar) {
                Image(systemName: isStarred ? "star.fill" : "star")
                    .foregroundStyle(isStarred ? .yellow : .secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .padding(.trailing, -8)
            .accessibilityLabel(isStarred ? "Remove from ideas" : "Save to ideas")
        }
    }

    /// Title, detail, NEW tag, source and score.
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
