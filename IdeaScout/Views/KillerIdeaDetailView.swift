// KillerIdeaDetailView.swift
// The idea detail screen, the answer first (usability review, 17 Nov 2026): the pitch, why it's a killer idea (the
// tests, price against competitors, the money, doubts), then the opportunity, one-week test and evidence, with
// Improve and Dismiss at the bottom and the starter kit as the main action.

import SwiftUI
import SwiftData

/// Everything about one idea: the opportunity, one-week test, devil's advocate, scores, evidence links,
/// with a pinned "Starter kit" button. The bookmark in the toolbar saves it.
struct KillerIdeaDetailView: View {
    /// The idea shown; bindable so saving updates the screen.
    @Bindable var idea: KillerIdea
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// Asks before dismissing (it hides the idea).
    @State private var confirmDismiss = false

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
                KillerStatusLabel(score: idea.killerScore, rejected: idea.criticRejected)
                IdeaKindTag(idea: idea)
                if let improved = idea.improvedAt {
                    Label("Using the improved version, kept \(improved.formatted(date: .abbreviated, time: .omitted))",
                          systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
                Text(idea.pitch)
            }
            // The answer first (usability review, 17 Nov 2026): why it's a killer idea, then the details.
            if idea.engineVersion >= 1 {
                IdeaPrinciplesSections(idea: idea)
            } else {
                olderScores
            }
            Section("The opportunity") {
                labelled("Who pays", idea.buyer)
                if idea.engineVersion < 1 { labelled("Pricing", idea.pricing) }
                if !idea.replaces.isEmpty { labelled("Replaces", idea.replaces) }
                if !idea.channel.isEmpty { labelled("Where to find buyers", idea.channel) }
                labelled("Why now", idea.whyNow)
            }
            Section("Test it in one week") {
                Text(idea.oneWeekTest)
            }
            if idea.engineVersion < 1 {
                Section {
                    labelled("Strongest objection", idea.objection)
                    labelled("Competitors", idea.competitors)
                    labelled("Verdict", idea.verdict)
                } header: {
                    Text("Doubts")
                } footer: {
                    Text("From the devil's advocate: a second, sceptical AI that tries to knock the idea down.")
                }
            }
            if !idea.evidence.isEmpty {
                Section {
                    ForEach(Array(idea.evidence.enumerated()), id: \.offset) { _, item in
                        if let url = item.url, url.isWebLink {   // Security: web links only
                            Link(item.title, destination: url).lineLimit(2)
                        } else {
                            Text(item.title)
                        }
                    }
                } header: {
                    Text("Evidence")
                } footer: {
                    Text("What people say online, in the AI's words. Not verified: tap a link to read the original.")
                }
            }
            Section {
                NavigationLink {
                    ImproveIdeaView(idea: idea)
                } label: {
                    Label(idea.improvedAt == nil ? "Improve this idea" : "Improve again or undo", systemImage: "arrow.up.circle")
                        .frame(minHeight: 44)
                }
                .accessibilityHint("AI rewrites answer the devil's advocate; you choose which version to keep")
                if !idea.isDismissed {
                    Button("Dismiss this idea", systemImage: "eye.slash", role: .destructive) { confirmDismiss = true }
                        .frame(minHeight: 44)
                }
            } footer: {
                Text("Dismissed ideas are hidden from Ideas and come back only if a later refresh finds new evidence.")
            }
        }
        .readableList()
        .safeAreaInset(edge: .bottom) {
            NavigationLink {
                StarterKitView(idea: idea)
            } label: {
                Label(idea.starterKit == nil ? "Starter kit" : "Open starter kit", systemImage: "hammer")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
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
        .confirmationDialog("Dismiss \(idea.title)?", isPresented: $confirmDismiss, titleVisibility: .visible) {
            Button("Dismiss", role: .destructive) {
                // Hidden rather than deleted, so its history and a saved copy are kept.
                idea.isDismissed = true
                context.saveOrReport("the dismissal")
                dismiss()
            }
        }
        .navigationTitle("Killer idea")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Scores for ideas found before the principles (11 Nov 2026).
    private var olderScores: some View {
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
            Text("Buildable solo: could one person build all of it with their AI coding tool. Sales channel: can buyers be reached without a sales team. Why now counts half. Fit for me uses your About me in Settings. Seen on \(idea.timesSeen) day\(idea.timesSeen == 1 ? "" : "s"): \(seenDays).")
        }
    }

    private func labelled(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            Text(text)
        }
    }
}
