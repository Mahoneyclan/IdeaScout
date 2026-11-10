// KillerIdeaDetailView.swift
// The idea detail screen: the opportunity, one-week test, devil's advocate, scores, evidence links
// and the build brief.

import SwiftUI
import SwiftData

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
        .readableList()
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
            .frame(maxWidth: Layout.buttonWidth)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
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
