import SwiftUI
import SwiftData

struct IdeasView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Idea.starredAt, order: .reverse) private var ideas: [Idea]

    var body: some View {
        NavigationStack {
            List {
                ForEach(ideas) { idea in
                    NavigationLink {
                        IdeaDetailView(idea: idea)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(idea.title).font(.headline)
                            Text(idea.note.isEmpty ? idea.detail : idea.note)
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .onDelete { offsets in
                    offsets.map { ideas[$0] }.forEach(context.delete)
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
        }
    }
}

struct IdeaDetailView: View {
    @Bindable var idea: Idea
    @EnvironmentObject private var service: DigestService
    @State private var isSuggesting = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text(idea.title).font(.headline)
                if !idea.detail.isEmpty { Text(idea.detail) }
                if let url = idea.url { Link("Open project", destination: url) }
                Label(idea.source.label, systemImage: idea.source.symbol).foregroundStyle(.secondary)
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
                        Label(idea.extensions.isEmpty ? "Suggest extensions & differentiators" : "Suggest again",
                              systemImage: "sparkles")
                    }
                }
                .disabled(isSuggesting)
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            } header: {
                Text("Extensions & differentiation")
            } footer: {
                Text("Your notes are included, so add your angle first for more relevant suggestions.")
            }
        }
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
