import SwiftUI
import SwiftData
import UIKit

struct IdeasView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Idea.starredAt, order: .reverse) private var ideas: [Idea]
    @AppStorage("ideas.sortByScore") private var sortByScore = false
    @AppStorage(AppSettings.Keys.weightNovelty) private var wNovelty = 1.0
    @AppStorage(AppSettings.Keys.weightMomentum) private var wMomentum = 1.0
    @AppStorage(AppSettings.Keys.weightViability) private var wViability = 1.0
    @AppStorage(AppSettings.Keys.weightGap) private var wGap = 1.0

    private var weights: RankWeights {
        RankWeights(novelty: wNovelty, momentum: wMomentum, viability: wViability, gap: wGap)
    }

    private var sortedIdeas: [Idea] {
        guard sortByScore else { return ideas }
        return ideas.sorted { ($0.scores.overall(weights) ?? 0) > ($1.scores.overall(weights) ?? 0) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sortedIdeas) { idea in
                    NavigationLink {
                        IdeaDetailView(idea: idea)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(idea.title).font(.headline)
                            Text(idea.note.isEmpty ? idea.detail : idea.note)
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            if let overall = idea.scores.overall(weights) {
                                Text("Score \(overall.formatted(.number.precision(.fractionLength(1)))) · \(idea.themeTitle)")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    let current = sortedIdeas
                    offsets.map { current[$0] }.forEach(context.delete)
                    try? context.save()
                }
            }
            .overlay {
                if ideas.isEmpty {
                    ContentUnavailableView("No saved ideas", systemImage: "star",
                                           description: Text("Tap the star on any project to save it here."))
                }
            }
            .navigationTitle("Ideas")
            .toolbar {
                Picker("Sort", selection: $sortByScore) {
                    Text("Newest").tag(false)
                    Text("Top score").tag(true)
                }
                .pickerStyle(.menu)
            }
        }
    }
}

struct IdeaDetailView: View {
    @Bindable var idea: Idea
    @EnvironmentObject private var service: DigestService
    @State private var isSuggesting = false
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Text(idea.title).font(.headline)
                if !idea.detail.isEmpty { Text(idea.detail) }
                if let url = idea.url { Link("Open project", destination: url) }
                Label(idea.source.label, systemImage: idea.source.symbol).foregroundStyle(.secondary)
            }
            if idea.scores != ThemeScores() {
                Section("Theme scores · \(idea.themeTitle)") {
                    ScoreBadges(scores: idea.scores)
                }
            }
            Section("My notes") {
                TextField("Your thoughts on this idea…", text: $idea.note, axis: .vertical)
                    .lineLimit(3...10)
            }
            Section {
                ForEach(idea.extensions, id: \.self) { Label($0, systemImage: "lightbulb") }
                Button {
                    Task { await suggest() }
                } label: {
                    if isSuggesting {
                        HStack { ProgressView(); Text("Thinking…") }
                    } else {
                        Label(idea.extensions.isEmpty ? "Suggest money-making variants" : "Suggest again",
                              systemImage: "sparkles")
                    }
                }
                .disabled(isSuggesting)
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            } header: {
                Text("Monetisable extensions & variants")
            } footer: {
                Text("Your notes are included, so add your angle first for more relevant suggestions.")
            }

            Section {
                let prompt = Prompts.fleshOut(idea)
                DisclosureGroup("Preview prompt") {
                    Text(prompt).font(.caption.monospaced()).textSelection(.enabled)
                }
                Button {
                    UIPasteboard.general.string = prompt
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy prompt", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                ShareLink(item: prompt, subject: Text(idea.title)) {
                    Label("Share prompt…", systemImage: "square.and.arrow.up")
                }
            } header: {
                Text("Flesh out this idea")
            } footer: {
                Text("Paste into Claude, ChatGPT, Lovable or Bolt to get a full product brief. It includes your notes, scores and extensions.")
            }
        }
        .onChange(of: idea.note) { copied = false }
        .navigationTitle("Idea")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func suggest() async {
        isSuggesting = true
        error = nil
        do { try await service.suggestExtensions(for: idea) } catch { self.error = error.localizedDescription }
        isSuggesting = false
    }
}
