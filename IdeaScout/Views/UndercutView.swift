// UndercutView.swift
// The "Reimagine an app" sheet (first built as "Undercut an app"), opened from the Ideas tab, in steps (owner, 16 Nov
// 2026): name the app (a link or its name, plus an optional note), see it explained, see the ways to reimagine it,
// pick one (or write your own), then get one idea judged by the devil's advocate. Each step's result shows as soon as
// it's ready, and recent research can be reopened to try another direction without paying for it again.

import SwiftUI

/// Name the app, then step through explaining it, the ways to reimagine it, and one idea.
struct UndercutView: View {
    @Environment(DigestService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var name = ""
    @State private var note = ""
    @State private var read: Undercut.Target?
    @State private var costs: (research: Double, build: Double)?
    @State private var recent: [Reimagine.Run] = []
    @State private var run: Reimagine.Run?
    @State private var chosen: Reimagine.Direction?
    @State private var ownText = ""
    @State private var built: ReimagineBuilt?
    @State private var saved: KillerIdea?
    @State private var failure: (message: String, details: String?)?
    @FocusState private var typing: Bool

    private var isRunning: Bool { !service.undercutStep.isEmpty }
    private var badLink: Bool { !input.isEmpty && Undercut.target(from: input) == nil }

    var body: some View {
        NavigationStack {
            Form {
                if let run {
                    ReimagineProfileSections(run: run, notThisApp: built == nil && !isRunning ? { reset(keepInput: true) } : nil)
                    directionsSection(run)
                    if let built { builtSections(built) }
                } else {
                    inputSections
                }
                if isRunning {
                    Section {
                        HStack(spacing: 12) { ProgressView(); Text(service.undercutStep) }.frame(minHeight: 44)
                    }
                }
                if let failure {
                    Section {
                        Label(failure.message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        if let details = failure.details { ErrorDetailsDisclosure(details: details) }
                    }
                }
            }
            .readableList()
            .navigationTitle("Reimagine an app")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(saved == nil ? "Close" : "Done") { dismiss() } }
            }
            .keyboardDone($typing)
            .onAppear { costs = AppSettings.reimagineCosts(); recent = ReimagineStore.load() }
            // Leaving mid-step would lose the screen, not the paid work: research is saved, and so is a backed idea.
            .interactiveDismissDisabled(isRunning)
        }
    }

    // MARK: - Step 0: which app

    @ViewBuilder private var inputSections: some View {
        Section {
            TextField("Link to the app, or its name", text: $input, axis: .vertical)
                .lineLimit(1...3).textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($typing).disabled(isRunning)
                .onChange(of: input) { _, value in read = Undercut.target(from: value); name = read?.name ?? "" }
            if badLink {
                Label("That isn't a link IdeaScout can read. Paste the app's website, GitHub or App Store link "
                      + "(in the App Store: Share → Copy Link), or type the app's name.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            } else if let from = read?.from, !from.isEmpty {
                TextField("App name", text: $name).focused($typing).disabled(isRunning)
                    .accessibilityLabel("App name, read from the link")
            }
        } header: {
            Text("Which app?")
        } footer: {
            Text("Paste its App Store link (Share → Copy Link) to include its App Store reviews, or its website or GitHub link. "
                 + "Or type its name.")
        }
        Section {
            TextField("Optional: what bugs you about it, or who you'd build for", text: $note, axis: .vertical)
                .lineLimit(2...4).focused($typing).disabled(isRunning)
        } footer: {
            Text("Your own experience counts as strong evidence.")
        }
        Section {
            if !isRunning {
                Button { explain() } label: {
                    Label("Explain this app" + (costs.map { " · up to " + AppSettings.approximateCostText($0.research) } ?? ""),
                          systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(costs == nil || badLink || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } footer: {
            Text(costs == nil
                 ? "This needs Claude with its API key, because it searches the web. See Settings → Advanced → AI & costs."
                 : "Claude searches the web (never Apple's site) to explain the app, then suggests ways to reimagine it. "
                   + "You choose one before any idea is made. The cost is an upper guide and counts towards your daily AI "
                   + "spending limit.\n\n" + Self.ownAppNote)
        }
        if !recent.isEmpty && !isRunning {
            Section("Recent apps (no new research cost)") {
                ForEach(recent) { past in
                    Button { open(past) } label: {
                        LabeledContent(past.target.name, value: past.madeAt.formatted(date: .abbreviated, time: .omitted))
                            .frame(minHeight: 44)
                    }
                }
            }
        }
    }

    // MARK: - Step 2: ways to reimagine it

    @ViewBuilder private func directionsSection(_ run: Reimagine.Run) -> some View {
        Section {
            if !run.directionsMade {
                if !isRunning { Button("Find ways to reimagine it", systemImage: "sparkles") { findDirections(run) }.frame(minHeight: 44) }
            } else if run.directions.isEmpty {
                Text("No clear gap found: the complaints don't point to a group or job this app serves badly. Add your own "
                     + "direction below, or try another app.")
            }
            ForEach(Array(run.directions.enumerated()), id: \.offset) { _, direction in
                Button { chosen = direction } label: { DirectionRow(direction: direction, chosen: chosen == direction) }
                    .buttonStyle(.plain).disabled(isRunning || built != nil)
            }
            if run.directionsMade && built == nil {
                TextField("Or write your own direction", text: $ownText, axis: .vertical)
                    .lineLimit(1...3).focused($typing).disabled(isRunning)
                    .onChange(of: ownText) { _, text in chosen = Reimagine.ownDirection(text) }
            }
            if let chosen, built == nil, !isRunning {
                Button { build(run, chosen) } label: {
                    Label("Build this idea" + (costs.map { " · up to " + AppSettings.approximateCostText($0.build) } ?? ""),
                          systemImage: "hammer")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
        } header: {
            Text("Step 2 · Ways to reimagine it")
        } footer: {
            if run.directionsMade && !run.directions.isEmpty {
                Text("Each is a group of people and a job \(run.target.name) serves badly, backed by at least two sources. Tap one to choose it.")
            }
        }
    }

    // MARK: - Step 3: the idea

    @ViewBuilder private func builtSections(_ built: ReimagineBuilt) -> some View {
        ReimagineBuiltSection(built: built)
        Section {
            if let saved {
                NavigationLink { KillerIdeaDetailView(idea: saved) } label: { KillerIdeaCard(idea: saved) }
                Text("Saved in Ideas, marked \"Gap spotted in \(saved.undercutApp)\". " + Self.ownAppNote).font(.footnote)
            } else {
                Button("Save anyway", systemImage: "tray.and.arrow.down") { save(built) }.frame(minHeight: 44)
            }
            Button("Try another direction", systemImage: "arrow.triangle.branch") {
                self.built = nil; saved = nil; chosen = nil; ownText = ""; failure = nil
            }
            .frame(minHeight: 44)
        }
    }

    /// Said before and after: the AI is asked not to copy, but nothing can guarantee it (legal review, 14 Nov 2026).
    static let ownAppNote = "The idea is meant to be your own app. IdeaScout asks the AI not to copy the name, look, "
        + "wording or code, but check before you build: you're responsible for what you ship."

    // MARK: - Actions (each in its own task, so closing the sheet doesn't waste a paid call)

    private func reset(keepInput: Bool) {
        run = nil; chosen = nil; built = nil; saved = nil; ownText = ""; failure = nil
        if !keepInput { input = ""; note = "" }
    }

    private func open(_ past: Reimagine.Run) {
        reset(keepInput: true)
        run = past
    }

    private func explain() {
        typing = false; failure = nil
        var target = read ?? Undercut.Target(name: name)
        target.name = name
        perform {
            let researched = try await service.reimagineResearch(target, note: note)
            run = researched
            run = try await service.reimagineDirections(researched)
        }
    }

    private func findDirections(_ current: Reimagine.Run) {
        failure = nil
        perform { run = try await service.reimagineDirections(current) }
    }

    private func build(_ current: Reimagine.Run, _ direction: Reimagine.Direction) {
        typing = false; failure = nil
        perform {
            let result = try await service.reimagineBuild(current, direction: direction)
            built = result
            if result.result.review.survives { saved = try service.saveReimagined(result, app: current.target.name) }
        }
    }

    private func save(_ result: ReimagineBuilt) {
        do { saved = try service.saveReimagined(result, app: run?.target.name ?? "") }
        catch { show(error) }
    }

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await work() } catch { show(error) }
            recent = ReimagineStore.load()
        }
    }

    private func show(_ error: Error) {
        guard !DigestService.isCancellation(error) else { return }
        let described = DigestWarning.describe(error)
        failure = (described.message, described.details)
    }
}
