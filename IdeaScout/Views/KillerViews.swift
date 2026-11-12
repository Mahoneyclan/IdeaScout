// KillerViews.swift
// Killer ideas on screen: the Ideas tab (leaderboard), idea cards and badges. The detail screen is in
// KillerIdeaDetailView.swift; today's status and the refresh button are in RefreshViews.swift.

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

/// Labels an idea "Killer" (score at or above the quality bar, which the user can change), "Near-miss", or
/// "Not worth testing" when the devil's advocate rejected it, whatever its score.
/// Recomputed on screen, so changing the bar relabels saved ideas at once.
struct KillerStatusLabel: View {
    /// The killer score (0–5).
    let score: Double
    /// The devil's advocate judged it not worth a one-week test.
    var rejected = false
    @AppStorage(AppSettings.Keys.qualityBar) private var qualityBar = AppSettings.defaultQualityBar

    var body: some View {
        if rejected {
            Label("Not worth testing, says the devil's advocate", systemImage: "xmark.octagon")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
        } else {
            let killer = score >= qualityBar
            Label(killer ? "Killer" : "Near-miss", systemImage: killer ? "flame.fill" : "scope")
                .font(.caption2.bold())
                .foregroundStyle(killer ? Color.orange : Color.secondary)
        }
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
                KillerStatusLabel(score: idea.killerScore, rejected: idea.criticRejected)
                if idea.isSaved {
                    Image(systemName: "bookmark.fill").font(.caption2).foregroundStyle(.indigo)
                        .accessibilityLabel("Saved")
                }
                Text("Last seen \(idea.lastSeen.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            IdeaKindTag(idea: idea)
            Text(idea.pitch).font(.subheadline)
            Text("\(idea.buyer) · " + (idea.engineVersion >= 1 && idea.monthlyPrice >= FiveTests.minimumPrice
                                         ? (idea.salesPlan.map { "\($0.model.label), " } ?? "") + idea.priceText : idea.pricing))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if let weakest = idea.principles.min(by: { $0.score < $1.score }) {
                    Text("Weakest: \(weakest.name) " + (weakest.known ? "\(weakest.score)/5" : "unproven")).font(.caption).foregroundStyle(.secondary)
                } else {
                    let weakest = KillerScoreMetrics.weakest(idea)
                    Text("Weakest: \(weakest.name) \(weakest.value)/5 · older scoring").font(.caption).foregroundStyle(.secondary)
                }
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

    /// Ideas not dismissed: those judged on the five principles first, then best leaderboard score.
    private var ranked: [KillerIdea] { ideas.filter { !$0.isDismissed }.sorted(by: KillerIdea.ranksAbove) }

    var body: some View {
        let killers = ranked.filter { !$0.criticRejected && $0.killerScore >= qualityBar }
        let nearMisses = ranked.filter { !$0.criticRejected && $0.killerScore < qualityBar }
        let rejected = ranked.filter(\.criticRejected)
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
                if !rejected.isEmpty {
                    Section {
                        rows(rejected, offset: killers.count + nearMisses.count)
                    } header: {
                        Text("Not worth testing")
                    } footer: {
                        Text("The devil's advocate didn't think these worth a one-week test; its reason is on each idea. You can still improve them or disagree.")
                    }
                }
            }
            .readableList()
            .navigationTitle("Ideas")
            .safeAreaInset(edge: .bottom) { RefreshBar() }
            // An alert rather than a confirmation dialog: it comes from a swipe, so on iPad there's no button to point at.
            .alert("Dismiss \(pendingDismiss?.title ?? "this idea")?",
                   isPresented: Binding(get: { pendingDismiss != nil }, set: { if !$0 { pendingDismiss = nil } })) {
                Button("Cancel", role: .cancel) { pendingDismiss = nil }
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
