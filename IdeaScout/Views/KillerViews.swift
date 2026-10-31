// KillerViews.swift
// Everything about killer ideas on screen: the Ideas tab (leaderboard with today's status and the refresh
// button), idea cards, badges and the idea detail screen with its build brief.

import SwiftUI
import SwiftData
import UIKit

// MARK: - Scores, badges and cards

/// The review scores: names, symbols and fields, used by the detail screen and the weakest-score summary.
enum KillerScoreMetrics {
    /// Name, symbol and field of each score, in display order. `canBeUnscored` marks scores that older
    /// ideas don't have (stored as 0), which are shown as "Not scored" and left out of the weakest score.
    static let metrics: [(name: String, symbol: String, value: KeyPath<KillerIdea, Int>, canBeUnscored: Bool)] = [
        ("Pain", "bandage", \.pain, false),
        ("Willing to pay", "dollarsign.circle", \.willingToPay, false),
        ("Buildable solo", "hammer", \.buildability, true),
        ("Sales channel", "storefront", \.channelScore, true),
        ("Gap", "arrow.triangle.branch", \.gap, false),
        ("Fit for me", "person.crop.circle.badge.checkmark", \.fit, false),
        ("Why now", "clock", \.timing, false),
    ]

    /// The scores this idea was actually given: older ideas leave out buildability and sales channel.
    /// - Parameter idea: The idea to check.
    /// - Returns: Name, symbol and value of each scored measure, in display order.
    static func scored(_ idea: KillerIdea) -> [(name: String, symbol: String, value: Int)] {
        metrics.map { ($0.name, $0.symbol, idea[keyPath: $0.value], $0.canBeUnscored) }
            .filter { !($0.3 && $0.2 == 0) }
            .map { ($0.0, $0.1, $0.2) }
    }

    /// The lowest score the idea was given: an idea is only as strong as its weakest point.
    /// - Parameter idea: The idea to check.
    /// - Returns: The measure's label and score; ("", 0) only if no measure was scored.
    static func weakest(_ idea: KillerIdea) -> (name: String, value: Int) {
        scored(idea).map { ($0.name, $0.value) }.min { $0.1 < $1.1 } ?? ("", 0)
    }

}

/// The killer score in a capsule: orange when it clears the quality bar, grey for a near-miss.
struct KillerScoreBadge: View {
    /// The killer score (0–5).
    let score: Double
    @AppStorage(AppSettings.Keys.qualityBar) private var qualityBar = AppSettings.defaultQualityBar

    var body: some View {
        Text(score, format: .number.precision(.fractionLength(1)))
            .font(.headline.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background((score >= qualityBar ? Color.orange : Color.gray).opacity(0.2), in: Capsule())
            .accessibilityLabel("Killer score \(score.formatted(.number.precision(.fractionLength(1)))) out of 5")
    }
}

/// Labels an idea "Killer" (score at or above the quality bar, which the user can change) or "Near-miss".
/// Recomputed on screen, so changing the bar relabels saved ideas at once.
struct KillerStatusLabel: View {
    /// The killer score (0–5).
    let score: Double
    @AppStorage(AppSettings.Keys.qualityBar) private var qualityBar = AppSettings.defaultQualityBar

    var body: some View {
        let killer = score >= qualityBar
        Label(killer ? "Killer" : "Near-miss", systemImage: killer ? "flame.fill" : "scope")
            .font(.caption2.bold())
            .foregroundStyle(killer ? Color.orange : Color.secondary)
    }
}

/// A card for one idea, used in the leaderboard, History days and Saved: title, score, status, pitch,
/// buyer and price, weakest score, and how many days it has come back.
struct KillerIdeaCard: View {
    /// The idea to show.
    let idea: KillerIdea

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(idea.title).font(.headline)
                Spacer()
                KillerScoreBadge(score: idea.killerScore)
            }
            HStack {
                KillerStatusLabel(score: idea.killerScore)
                if idea.isSaved {
                    Image(systemName: "bookmark.fill").font(.caption2).foregroundStyle(.indigo)
                        .accessibilityLabel("Saved")
                }
                Text("Last seen \(idea.lastSeen.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(idea.pitch).font(.subheadline)
            Text("\(idea.buyer) · \(idea.pricing)").font(.caption).foregroundStyle(.secondary)
            HStack {
                let weakest = KillerScoreMetrics.weakest(idea)
                Text("Weakest: \(weakest.name) \(weakest.value)/5").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if idea.timesSeen > 1 {
                    Label("\(idea.timesSeen) days", systemImage: "arrow.clockwise")
                        .font(.caption2.bold()).foregroundStyle(.orange)
                        .accessibilityLabel("Came back on \(idea.timesSeen) days")
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Everything about one idea: the opportunity, one-week test, devil's advocate, scores, evidence links,
/// and a pinned "Copy build brief" button. The bookmark in the toolbar saves it.
struct KillerIdeaDetailView: View {
    /// The idea shown; bindable so saving updates the screen.
    @Bindable var idea: KillerIdea
    @Environment(\.modelContext) private var context
    @State private var copied = false

    /// The days it was proposed, as text (first and last day for ideas saved before days were recorded).
    private var seenDays: String {
        let days = idea.daysSeen.isEmpty ? Array(Set([idea.firstSeen, idea.lastSeen].map { Calendar.current.startOfDay(for: $0) })).sorted() : idea.daysSeen.sorted()
        return days.map { $0.formatted(date: .abbreviated, time: .omitted) }.joined(separator: ", ")
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(idea.title).font(.title3.bold())
                    Spacer()
                    KillerScoreBadge(score: idea.killerScore)
                }
                KillerStatusLabel(score: idea.killerScore)
                Text(idea.pitch)
            }
            Section("The opportunity") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Who pays").font(.subheadline.bold())
                    Text(idea.buyer)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pricing").font(.subheadline.bold())
                    Text(idea.pricing)
                }
                if !idea.replaces.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Replaces").font(.subheadline.bold())
                        Text(idea.replaces)
                    }
                }
                if !idea.channel.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Where to find buyers").font(.subheadline.bold())
                        Text(idea.channel)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Why now").font(.subheadline.bold())
                    Text(idea.whyNow)
                }
            }
            Section("Test it in one week") {
                Text(idea.oneWeekTest)
            }
            Section("Devil's advocate") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Strongest objection").font(.subheadline.bold())
                    Text(idea.objection)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Competitors").font(.subheadline.bold())
                    Text(idea.competitors)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Verdict").font(.subheadline.bold())
                    Text(idea.verdict)
                }
            }
            Section {
                ForEach(KillerScoreMetrics.metrics, id: \.name) { metric in
                    let value = idea[keyPath: metric.value]
                    LabeledContent {
                        Text(metric.canBeUnscored && value == 0 ? "Not scored" : "\(value)/5").monospacedDigit()
                    } label: {
                        Label(metric.name, systemImage: metric.symbol)
                    }
                }
            } header: {
                Text("Scores")
            } footer: {
                Text("Buildable solo: could one person ship it with AI coding tools in about 4 weeks. Sales channel: can buyers be reached without a sales team. Why now counts half. Fit for me uses your About me in Settings. Seen on \(idea.timesSeen) day\(idea.timesSeen == 1 ? "" : "s"): \(seenDays).")
            }
            if !idea.evidence.isEmpty {
                Section("Evidence") {
                    ForEach(Array(idea.evidence.enumerated()), id: \.offset) { _, item in
                        if let url = item.url, url.isWebLink {   // Security: web links only
                            Link(item.title, destination: url).lineLimit(2)
                        } else {
                            Text(item.title)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            let prompt = Prompts.buildBrief(idea)
            HStack(spacing: 12) {
                Button {
                    SecureClipboard.copy(prompt)   // Security: this device only, expires after 10 minutes
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy build brief", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                ShareLink(item: prompt, subject: Text(idea.title)) {
                    Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Share build brief")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    idea.toggleSaved()
                    context.saveOrReport("your change")
                } label: {
                    Image(systemName: idea.isSaved ? "bookmark.fill" : "bookmark")
                }
                .accessibilityLabel(idea.isSaved ? "Remove from Saved" : "Save idea")
            }
        }
        .navigationTitle("Killer idea")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Ideas tab

/// Every idea so far, best first: killers (at or above the quality bar), then near-misses.
/// Ideas that come back on several days get a bonus.
struct LeaderboardView: View {
    @Environment(\.modelContext) private var context
    @Environment(DigestService.self) private var service
    @Query private var ideas: [KillerIdea]
    @Query(sort: \Digest.createdAt, order: .reverse) private var digests: [Digest]
    @AppStorage(AppSettings.Keys.qualityBar) private var qualityBar = AppSettings.defaultQualityBar
    /// The idea waiting for "Dismiss" confirmation.
    @State private var pendingDismiss: KillerIdea?

    /// Ideas not dismissed, best leaderboard score first.
    private var ranked: [KillerIdea] { ideas.filter { !$0.isDismissed }.sorted { $0.leaderboardScore > $1.leaderboardScore } }

    var body: some View {
        let killers = ranked.filter { $0.killerScore >= qualityBar }
        let nearMisses = ranked.filter { $0.killerScore < qualityBar }
        NavigationStack {
            List {
                Section { TodayStatus(today: digests.first { Calendar.current.isDateInToday($0.day) }, ideas: ideas) }
                if !killers.isEmpty {
                    Section("Killer ideas") { rows(killers) }
                }
                if !nearMisses.isEmpty {
                    Section {
                        rows(nearMisses, offset: killers.count)
                    } header: {
                        Text("Near-misses")
                    } footer: {
                        Text("Survived the devil's advocate but scored below your quality bar (\(qualityBar.formatted()) / 5). They can climb if they come back on later days.")
                    }
                }
            }
            .navigationTitle("Ideas")
            .safeAreaInset(edge: .bottom) { RefreshBar() }
            .confirmationDialog("Dismiss \(pendingDismiss?.title ?? "this idea")?",
                                isPresented: Binding(get: { pendingDismiss != nil }, set: { if !$0 { pendingDismiss = nil } }),
                                titleVisibility: .visible) {
                Button("Dismiss", role: .destructive) {
                    // Hidden rather than deleted, so its history and a saved copy are kept.
                    if let idea = pendingDismiss { idea.isDismissed = true; context.saveOrReport("the dismissal") }
                    pendingDismiss = nil
                }
            } message: {
                Text(pendingDismiss?.isSaved == true
                     ? "It's hidden from this list but stays in Saved. It comes back if it's proposed again."
                     : "It's hidden from this list. It comes back if it's proposed again on a later day.")
            }
        }
    }

    /// `offset` keeps the rank numbering continuous across sections.
    private func rows(_ list: [KillerIdea], offset: Int = 0) -> some View {
        ForEach(Array(list.enumerated()), id: \.element.key) { index, idea in
            NavigationLink {
                KillerIdeaDetailView(idea: idea)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Text("\(offset + index + 1)").font(.title3.bold().monospacedDigit()).foregroundStyle(.secondary)
                    KillerIdeaCard(idea: idea)
                }
            }
            .swipeActions(edge: .trailing) {
                Button("Dismiss", role: .destructive) { pendingDismiss = idea }
            }
            .swipeActions(edge: .leading) {
                Button(idea.isSaved ? "Unsave" : "Save", systemImage: idea.isSaved ? "bookmark.slash" : "bookmark") {
                    idea.toggleSaved()
                    context.saveOrReport("your change")
                }
                .tint(.indigo)
            }
        }
    }
}

/// The first row of the Ideas tab: refresh progress, or when today's digest was made, how many ideas it
/// produced and the latest note (e.g. limit reached). Tapping it opens today's full digest.
struct TodayStatus: View {
    /// Today's digest, if there is one.
    let today: Digest?
    /// All ideas, to count today's.
    let ideas: [KillerIdea]
    @Environment(DigestService.self) private var service

    var body: some View {
        if service.isRefreshing {
            let step = service.stage?.rawValue ?? 1
            VStack(alignment: .leading, spacing: 6) {
                Text("Step \(step) of \(DigestService.Stage.allCases.count) · \(service.stage?.label ?? "Starting")…")
                    .font(.subheadline)
                ProgressView(value: Double(step), total: Double(DigestService.Stage.allCases.count))
                Text("Takes a few minutes. Keep the app open.").font(.caption).foregroundStyle(.secondary)
            }
        } else if let today {
            let found = KillerIdea.seen(on: today.day, in: ideas).count
            NavigationLink {
                DigestContentView(digest: today)
                    .navigationTitle(today.day.formatted(date: .abbreviated, time: .omitted))
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Updated \(today.createdAt.formatted(date: .omitted, time: .shortened)) · \(found) idea\(found == 1 ? "" : "s") today",
                          systemImage: "checkmark.circle")
                        .font(.subheadline)
                    // Show the reason inline (e.g. limit reached, every idea rejected) rather than a count.
                    if let note = service.lastError ?? today.warnings.last.map({ DigestWarning.parts($0).message }) {
                        Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("No refresh yet today", systemImage: "sun.max").font(.subheadline)
                if let error = service.lastError { Text(error).font(.caption).foregroundStyle(.secondary) }
                Text("Use the button below to find today's ideas.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Refresh button

/// The main action, at the bottom of the screen where the thumb rests. The first refresh of the day
/// runs straight away; another one the same day asks first, because it costs money.
struct RefreshBar: View {
    @Environment(DigestService.self) private var service
    @Environment(StoreManager.self) private var store
    @State private var showPaywall = false
    @State private var showConsent = false
    @Query(sort: \Digest.createdAt, order: .reverse) private var digests: [Digest]
    @AppStorage(AppSettings.Keys.claudeMaxItems) private var maxItems = AppSettings.defaultClaudeMaxItems
    @AppStorage(AppSettings.Keys.dailyCap) private var dailyCap = AppSettings.defaultDailyCap
    @AppStorage(AppSettings.Keys.aiProvider) private var providerRaw = AIProvider.claude.rawValue
    /// Shows the "Run another refresh today?" confirmation.
    @State private var confirm = false
    /// The chosen cloud model's price, or `nil` when a refresh is free. Kept here because looking it up reads
    /// the Keychain; refreshed when the screen appears (after any change in Settings) and when the AI changes.
    @State private var price: ModelPrice?

    /// The estimated cost of one refresh, shown on the button: "~$0.45", or "Free".
    private var costText: String {
        AppSettings.refreshCostText(items: maxItems, price: price)
    }

    var body: some View {
        let hasToday = digests.contains { Calendar.current.isDateInToday($0.day) }
        Button {
            if !store.access.canRefresh { showPaywall = true }
            else if AppSettings.needsConsent { showConsent = true }
            else if hasToday { confirm = true }
            else { Task { await service.refresh(force: true) } }
        } label: {
            Label(!store.access.canRefresh ? (store.access == .expired ? "Unlock to find new ideas · \(store.unlockPrice)" : "Start free trial")
                  : service.isRefreshing ? "Refreshing…" : (hasToday ? "Refresh again · \(costText)" : "Find today's ideas · \(costText)"),
                  systemImage: store.access.canRefresh ? "arrow.clockwise" : "lock.open")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .sheet(isPresented: $showConsent) {
            ConsentView(provider: AppSettings.provider) { agreed in
                // Continue what the user asked for: refresh now, or confirm first if today already ran (it costs money).
                if agreed { if hasToday { confirm = true } else { Task { await service.refresh(force: true) } } }
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(service.isRefreshing)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear { price = AppSettings.chosenModelPrice() }
        .onChange(of: providerRaw) { price = AppSettings.chosenModelPrice() }
        .confirmationDialog("Run another refresh today?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Refresh (\(costText))") { Task { await service.refresh(force: true) } }
        } message: {
            let spent = UsageTracker.summary().today.cost.formatted(.currency(code: "USD"))
            Text(dailyCap > 0 ? "Today's refresh already ran. Spent today: \(spent) of \(dailyCap.formatted(.currency(code: "USD")))."
                              : "Today's refresh already ran. Spent today: \(spent).")
        }
    }
}
