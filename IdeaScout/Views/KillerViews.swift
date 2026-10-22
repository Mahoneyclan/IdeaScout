import SwiftUI
import SwiftData
import UIKit

/// The five review scores, shown compactly.
struct KillerScoreRow: View {
    let idea: KillerIdea

    static let metrics: [(name: String, symbol: String, value: KeyPath<KillerIdea, Int>)] = [
        ("Pain", "bandage", \.pain),
        ("Willing to pay", "dollarsign.circle", \.willingToPay),
        ("Why now", "clock", \.timing),
        ("Gap", "arrow.triangle.branch", \.gap),
        ("Fit for me", "person.crop.circle.badge.checkmark", \.fit),
    ]

    /// The lowest of the five scores: an idea is only as strong as its weakest point.
    static func weakest(_ idea: KillerIdea) -> (name: String, value: Int) {
        metrics.map { ($0.name, idea[keyPath: $0.value]) }.min { $0.1 < $1.1 } ?? ("", 0)
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Self.metrics, id: \.name) { metric in
                let value = idea[keyPath: metric.value]
                Label("\(value)", systemImage: metric.symbol)
                    .accessibilityLabel("\(metric.name) \(value) out of 5")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

struct KillerScoreBadge: View {
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

/// A card for one killer idea, used on Today and the leaderboard.
/// "Killer" when the idea clears the quality bar, otherwise "Near-miss".
struct KillerStatusLabel: View {
    let score: Double
    @AppStorage(AppSettings.Keys.qualityBar) private var qualityBar = AppSettings.defaultQualityBar

    var body: some View {
        let killer = score >= qualityBar
        Label(killer ? "Killer" : "Near-miss", systemImage: killer ? "flame.fill" : "scope")
            .font(.caption2.bold())
            .foregroundStyle(killer ? Color.orange : Color.secondary)
    }
}

struct KillerIdeaCard: View {
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
                Text("Last seen \(idea.lastSeen.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(idea.pitch).font(.subheadline)
            Text("\(idea.buyer) · \(idea.pricing)").font(.caption).foregroundStyle(.secondary)
            HStack {
                let weakest = KillerScoreRow.weakest(idea)
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

struct KillerIdeaDetailView: View {
    let idea: KillerIdea
    @State private var copied = false

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
                ForEach(KillerScoreRow.metrics, id: \.name) { metric in
                    LabeledContent {
                        Text("\(idea[keyPath: metric.value])/5").monospacedDigit()
                    } label: {
                        Label(metric.name, systemImage: metric.symbol)
                    }
                }
            } header: {
                Text("Scores")
            } footer: {
                Text("Seen on \(idea.timesSeen) day\(idea.timesSeen == 1 ? "" : "s"): \(seenDays). Fit for me uses your About me in Settings.")
            }
            if !idea.evidence.isEmpty {
                Section("Evidence") {
                    ForEach(Array(idea.evidence.enumerated()), id: \.offset) { _, item in
                        if let url = item.url {
                            Link(item.title, destination: url).lineLimit(2)
                        } else {
                            Text(item.title)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            let prompt = Prompts.fleshOut(idea)
            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = prompt
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy plan prompt", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                ShareLink(item: prompt, subject: Text(idea.title)) {
                    Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Share plan prompt")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle("Killer idea")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Every idea so far, best first: killers (at or above the quality bar), then near-misses.
/// Ideas that come back on several days get a bonus.
struct LeaderboardView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var service: DigestService
    @Query private var ideas: [KillerIdea]
    @Query(sort: \Digest.createdAt, order: .reverse) private var digests: [Digest]
    @AppStorage(AppSettings.Keys.qualityBar) private var qualityBar = AppSettings.defaultQualityBar
    @State private var pendingDismiss: KillerIdea?

    private var ranked: [KillerIdea] { ideas.sorted { $0.leaderboardScore > $1.leaderboardScore } }

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
                    if let idea = pendingDismiss { context.delete(idea); try? context.save() }
                    pendingDismiss = nil
                }
            } message: {
                Text("It's removed from the list. If it's proposed again on a later day, it comes back as new.")
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
        }
    }
}

/// One line at the top of the Ideas tab: whether today's refresh has run and what it found.
struct TodayStatus: View {
    let today: Digest?
    let ideas: [KillerIdea]
    @EnvironmentObject private var service: DigestService

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
                    if let note = service.lastError ?? today.warnings.last {
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

/// The main action, at the bottom of the screen where the thumb rests. The first refresh of the day
/// runs straight away; another one the same day asks first, because it costs money.
struct RefreshBar: View {
    @EnvironmentObject private var service: DigestService
    @Query(sort: \Digest.createdAt, order: .reverse) private var digests: [Digest]
    @AppStorage(AppSettings.Keys.claudeMaxItems) private var maxItems = AppSettings.defaultClaudeMaxItems
    @AppStorage(AppSettings.Keys.dailyCap) private var dailyCap = AppSettings.defaultDailyCap
    @State private var confirm = false

    private var costText: String {
        AppSettings.estimatedRefreshCost(items: maxItems).upperBound.formatted(.currency(code: "USD"))
    }

    var body: some View {
        let hasToday = digests.contains { Calendar.current.isDateInToday($0.day) }
        Button {
            if hasToday { confirm = true } else { Task { await service.refresh(force: true) } }
        } label: {
            Label(service.isRefreshing ? "Refreshing…" : (hasToday ? "Refresh again · ~\(costText)" : "Find today's ideas · ~\(costText)"),
                  systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(service.isRefreshing)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .confirmationDialog("Run another refresh today?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Refresh (~\(costText))") { Task { await service.refresh(force: true) } }
        } message: {
            let spent = UsageTracker.summary().today.cost.formatted(.currency(code: "USD"))
            Text(dailyCap > 0 ? "Today's refresh already ran. Spent today: \(spent) of \(dailyCap.formatted(.currency(code: "USD")))."
                              : "Today's refresh already ran. Spent today: \(spent).")
        }
    }
}
