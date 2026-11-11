// StarterKitView.swift
// The starter kit screen for one idea: make the kit (cost shown first), read it, and share it as a build prompt
// worded for the AI coding tool chosen in Settings. Making it again asks first, because it's another paid AI request.

import SwiftUI
import SwiftData

/// Shows or makes the idea's starter kit.
struct StarterKitView: View {
    @Bindable var idea: KillerIdea
    @Environment(DigestService.self) private var service
    @AppStorage(AppSettings.Keys.starterKitTool) private var toolRaw = BuilderTool.claudeCode.rawValue
    @AppStorage(AppSettings.Keys.dailyCap) private var dailyCap = AppSettings.defaultDailyCap
    /// Estimated cost of one kit; `nil` when no paid cloud AI is set up. Read when the screen appears.
    @State private var cost: Double?
    /// The last error: a plain message and any technical detail.
    @State private var failure: (message: String, details: String?)?
    /// Shows the "Make it again?" confirmation.
    @State private var confirmAgain = false

    private var tool: BuilderTool { BuilderTool(rawValue: toolRaw) ?? .claudeCode }
    private var isMaking: Bool { service.makingStarterKitFor == idea.key }
    private var costText: String { cost.map { " · " + AppSettings.approximateCostText($0) } ?? "" }

    var body: some View {
        Form {
            if let kit = idea.starterKit {
                Section {
                    LabeledContent("Worded for", value: tool.label)
                } footer: {
                    Text("Change your AI coding tool in Settings. It also decides the kind of app ideas are for, so a kit "
                         + "made for another tool may need making again.")
                }
                kitSections(kit)
                Section {
                    makeButton(title: "Make it again")
                } footer: {
                    Text(madeText)
                }
            } else {
                Section {
                    Text("One AI request plans the first version of \(idea.title): a short spec, the screens, the data it "
                         + "stores, a cheap stack for one person, what to leave out, and the first thing to build. Then "
                         + "share it, worded for your AI coding tool.")
                    makeButton(title: "Make starter kit")
                } footer: {
                    Text(cost == nil
                         ? "Starter kits need a cloud AI with its API key. See Settings → Advanced → AI & costs."
                         : "The cost is an upper guide and counts towards your daily AI spending limit.")
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
        .safeAreaInset(edge: .bottom) {
            if let kit = idea.starterKit {
                ShareLink(item: StarterKitPrompts.shareText(kit, title: idea.title, tool: tool), subject: Text(idea.title)) {
                    Label("Share build prompt for \(tool.label)…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: Layout.buttonWidth)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
        .confirmationDialog("Make the starter kit again?", isPresented: $confirmAgain, titleVisibility: .visible) {
            Button("Make it again" + costText) { make() }
        } message: {
            Text(repeatMessage)
        }
        .onAppear { cost = AppSettings.starterKitCost() }
        .navigationTitle("Starter kit")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The make button, or progress while the kit is being made.
    @ViewBuilder private func makeButton(title: String) -> some View {
        if isMaking {
            HStack(spacing: 12) {
                ProgressView()
                Text("Making your starter kit… this can take a minute.")
            }
            .frame(minHeight: 44)
        } else {
            Button {
                // Money: a repeat paid request asks first, like a second refresh does.
                if idea.starterKit != nil && cost != nil { confirmAgain = true } else { make() }
            } label: {
                Label(title + costText, systemImage: "hammer")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(service.makingStarterKitFor != nil)
        }
    }

    /// The kit's contents, as plain text.
    @ViewBuilder private func kitSections(_ kit: StarterKit) -> some View {
        Section("What it is") { Text(kit.spec) }
        Section("Screens") {
            ForEach(Array(kit.screens.enumerated()), id: \.offset) { _, screen in
                VStack(alignment: .leading, spacing: 4) {
                    Text(screen.name).font(.subheadline.bold())
                    Text(screen.purpose)
                }
            }
        }
        Section("Data it stores") {
            ForEach(Array(kit.dataModel.enumerated()), id: \.offset) { _, entity in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entity.name).font(.subheadline.bold())
                    Text(entity.fields.joined(separator: ", "))
                    if !entity.notes.isEmpty { Text(entity.notes).foregroundStyle(.secondary) }
                }
            }
        }
        Section {
            ForEach(Array(kit.stack.enumerated()), id: \.offset) { _, part in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(part.part): \(part.choice)").font(.subheadline.bold())
                    if !part.why.isEmpty { Text(part.why) }
                }
            }
        } header: {
            Text("Stack")
        } footer: {
            if !kit.monthlyCost.isEmpty { Text("Running cost: \(kit.monthlyCost)") }
        }
        if !kit.leaveOut.isEmpty {
            Section("Leave out of the first version") {
                ForEach(Array(kit.leaveOut.enumerated()), id: \.offset) { _, text in Label(text, systemImage: "minus.circle") }
            }
        }
        Section("First slice") {
            Text(kit.firstSlice)
            ForEach(Array(kit.doneWhen.enumerated()), id: \.offset) { _, text in Label(text, systemImage: "checkmark.circle") }
        }
        if !kit.projectRules.isEmpty {
            Section("Rules for your AI coding tool") {
                ForEach(Array(kit.projectRules.enumerated()), id: \.offset) { _, text in Text(text) }
            }
        }
    }

    /// When and with which model the kit was made.
    private var madeText: String {
        let date = idea.starterKitMadeAt.map { " on " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
        let model = idea.starterKitModel.isEmpty ? "" : " with \(idea.starterKitModel)"
        return "Made\(date)\(model). Making it again replaces this kit."
    }

    /// The repeat request's cost and today's spending against the daily limit.
    private var repeatMessage: String {
        let spent = UsageTracker.summary().today.cost.formatted(.currency(code: "USD"))
        let limit = dailyCap > 0 ? " of \(dailyCap.formatted(.currency(code: "USD")))" : ""
        let price = cost.map { " (\(AppSettings.approximateCostText($0)))" } ?? ""
        return "This makes another paid AI request\(price) and replaces the current kit. Spent today: \(spent)\(limit)."
    }

    /// Makes the kit; errors show on screen. Runs in its own task, so leaving the screen doesn't waste a paid call.
    private func make() {
        failure = nil
        Task {
            do {
                try await service.makeStarterKit(for: idea)
            } catch {
                guard !DigestService.isCancellation(error) else { return }
                let described = DigestWarning.describe(error)
                failure = (described.message, described.details)
            }
        }
    }
}
