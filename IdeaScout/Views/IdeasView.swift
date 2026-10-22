// IdeasView.swift
// The Saved tab: bookmarked killer ideas, then starred projects. A starred project opens IdeaDetailView,
// where the user adds notes, asks the AI for money-making variants and copies a "flesh out" prompt.
// (The type keeps its original name, IdeasView, from before the tab was renamed.)

import SwiftUI
import SwiftData
import UIKit

/// The Saved tab: killer ideas the user bookmarked, then projects they starred.
struct IdeasView: View {
    @Environment(\.modelContext) private var context
    /// Starred projects, newest first.
    @Query(sort: \Idea.starredAt, order: .reverse) private var ideas: [Idea]
    /// Killer ideas the user saved, most recently saved first.
    @Query(filter: #Predicate<KillerIdea> { $0.isSaved }, sort: \KillerIdea.savedAt, order: .reverse)
    private var savedIdeas: [KillerIdea]
    /// Sort projects by their trend's score instead of by date.
    @AppStorage("ideas.sortByScore") private var sortByScore = false
    @AppStorage(AppSettings.Keys.weightNovelty) private var wNovelty = 1.0
    @AppStorage(AppSettings.Keys.weightMomentum) private var wMomentum = 1.0
    @AppStorage(AppSettings.Keys.weightViability) private var wViability = 1.0
    @AppStorage(AppSettings.Keys.weightGap) private var wGap = 1.0

    private var weights: RankWeights {
        RankWeights(novelty: wNovelty, momentum: wMomentum, viability: wViability, gap: wGap)
    }

    /// Projects in the chosen order.
    private var sortedIdeas: [Idea] {
        guard sortByScore else { return ideas }
        return ideas.sorted { ($0.scores.overall(weights) ?? 0) > ($1.scores.overall(weights) ?? 0) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !savedIdeas.isEmpty {
                    Section("Saved ideas") {
                        ForEach(savedIdeas, id: \.key) { idea in
                            NavigationLink { KillerIdeaDetailView(idea: idea) } label: { KillerIdeaCard(idea: idea) }
                                .swipeActions(edge: .trailing) {
                                    Button("Unsave", systemImage: "bookmark.slash", role: .destructive) {
                                        idea.toggleSaved()
                                        try? context.save()
                                    }
                                }
                        }
                    }
                }
                Section(ideas.isEmpty ? "" : "Saved projects") {
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
            }
            .overlay {
                if ideas.isEmpty && savedIdeas.isEmpty {
                    ContentUnavailableView("Nothing saved yet", systemImage: "bookmark",
                                           description: Text("Tap the bookmark on an idea (or swipe right on it in Ideas), or the star on any project in History."))
                }
            }
            .navigationTitle("Saved")
            .toolbar {
                if !ideas.isEmpty {
                Picker("Sort projects", selection: $sortByScore) {
                    Text("Newest").tag(false)
                    Text("Top score").tag(true)
                }
                .pickerStyle(.menu)
                }
            }
        }
    }
}

/// One starred project: description, link, its trend's scores, the user's notes, AI variant suggestions
/// and the "flesh out" prompt to copy or share.
struct IdeaDetailView: View {
    /// The project; edits to notes save automatically.
    @Bindable var idea: Idea
    @EnvironmentObject private var service: DigestService
    /// True while waiting for the AI's suggestions.
    @State private var isSuggesting = false
    /// The last suggestion error, shown under the button.
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Text(idea.title).font(.headline)
                if !idea.detail.isEmpty { Text(idea.detail) }
                if let url = idea.url, url.isWebLink { Link("Open project", destination: url) }   // Security: web links only
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
                    SecureClipboard.copy(prompt)   // Security: this device only, expires after 10 minutes
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

    /// Asks the current AI for variants and shows any error.
    private func suggest() async {
        isSuggesting = true
        error = nil
        do { try await service.suggestExtensions(for: idea) } catch { self.error = error.localizedDescription }
        isSuggesting = false
    }
}
