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

    var body: some View {
        Text(score, format: .number.precision(.fractionLength(1)))
            .font(.headline.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.orange.opacity(0.2), in: Capsule())
            .accessibilityLabel("Killer score \(score.formatted(.number.precision(.fractionLength(1)))) out of 5")
    }
}

/// A card for one killer idea, used on Today and the leaderboard.
struct KillerIdeaCard: View {
    let idea: KillerIdea

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(idea.title).font(.headline)
                Spacer()
                KillerScoreBadge(score: idea.killerScore)
            }
            Text(idea.pitch).font(.subheadline)
            Text("\(idea.buyer) · \(idea.pricing)").font(.caption).foregroundStyle(.secondary)
            HStack {
                KillerScoreRow(idea: idea)
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

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(idea.title).font(.title3.bold())
                    Spacer()
                    KillerScoreBadge(score: idea.killerScore)
                }
                Text(idea.pitch)
            }
            Section("The opportunity") {
                LabeledContent("Who pays") { Text(idea.buyer).multilineTextAlignment(.trailing) }
                LabeledContent("Pricing") { Text(idea.pricing).multilineTextAlignment(.trailing) }
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
                Text("Seen on \(idea.timesSeen) day\(idea.timesSeen == 1 ? "" : "s"), first \(idea.firstSeen.formatted(date: .abbreviated, time: .omitted)). Fit for me uses your About me in Settings.")
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
            Section {
                let prompt = Prompts.fleshOut(idea)
                Button {
                    UIPasteboard.general.string = prompt
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy plan prompt", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                ShareLink(item: prompt, subject: Text(idea.title)) {
                    Label("Share prompt…", systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text("Paste into Claude or ChatGPT to turn this into an MVP plan, landing page and interview questions.")
            }
        }
        .navigationTitle("Killer idea")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Every killer idea so far, best first. Ideas that come back on several days get a bonus.
struct LeaderboardView: View {
    @Environment(\.modelContext) private var context
    @Query private var ideas: [KillerIdea]
    @AppStorage(AppSettings.Keys.qualityBar) private var qualityBar = AppSettings.defaultQualityBar

    private var ranked: [KillerIdea] {
        ideas.filter { $0.killerScore >= qualityBar }.sorted { $0.leaderboardScore > $1.leaderboardScore }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(ranked.enumerated()), id: \.element.key) { index, idea in
                    NavigationLink {
                        KillerIdeaDetailView(idea: idea)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)").font(.title3.bold().monospacedDigit()).foregroundStyle(.secondary)
                            KillerIdeaCard(idea: idea)
                        }
                    }
                }
                .onDelete { offsets in
                    let current = ranked
                    offsets.map { current[$0] }.forEach(context.delete)
                    try? context.save()
                }
                let hidden = ideas.count - ranked.count
                if hidden > 0 {
                    Text("\(hidden) idea\(hidden == 1 ? "" : "s") below the quality bar (\(qualityBar.formatted()) / 5) hidden. Lower the bar in Settings to see \(hidden == 1 ? "it" : "them").")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .overlay {
                if ranked.isEmpty && ideas.count == 0 {
                    ContentUnavailableView("No killer ideas yet", systemImage: "trophy",
                                           description: Text("Each refresh with Claude proposes ideas and keeps only the ones that survive a devil's-advocate check."))
                }
            }
            .navigationTitle("Top Ideas")
        }
    }
}
