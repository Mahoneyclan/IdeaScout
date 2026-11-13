// UndercutView.swift
// The "Undercut an app" sheet, opened from the Ideas tab: paste an App Store link (or type an app's name), check the
// name read from it, see the cost, then get one idea for a cheaper, simpler alternative, saved with the others.

import SwiftUI

/// Paste a link or name, confirm, wait, then open the idea.
struct UndercutView: View {
    @Environment(DigestService.self) private var service
    @Environment(\.dismiss) private var dismiss
    /// What the user pasted or typed.
    @State private var input = ""
    /// The app's name, read from `input` and editable.
    @State private var name = ""
    /// The App Store id from the link, if any (shown so the user knows the link was read).
    @State private var appID = ""
    /// The upper cost guide, or `nil` when Claude isn't set up.
    @State private var cost: Double?
    @State private var failure: (message: String, details: String?)?
    /// The idea made, once done.
    @State private var made: KillerIdea?
    @FocusState private var typing: Bool

    private var isRunning: Bool { !service.undercutStep.isEmpty }
    /// Pasted text that isn't an App Store app link (and isn't a plain name).
    private var badLink: Bool { !input.isEmpty && Undercut.target(from: input) == nil }

    var body: some View {
        NavigationStack {
            Form {
                if let made {
                    Section("Your idea") {
                        NavigationLink { KillerIdeaDetailView(idea: made) } label: { KillerIdeaCard(idea: made) }
                    }
                    Section {} footer: { Text("It's saved in Ideas, marked \"Undercuts \(made.undercutApp)\".") }
                } else {
                    inputSection
                    if let failure {
                        Section {
                            Label(failure.message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                            if let details = failure.details { ErrorDetailsDisclosure(details: details) }
                        }
                    }
                }
            }
            .readableList()
            .navigationTitle("Undercut an app")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(made == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
            .keyboardDone($typing)
            .onAppear { cost = AppSettings.undercutCost() }
            // Leaving mid-run would lose the result screen, not the paid work: the idea is still saved.
            .interactiveDismissDisabled(isRunning)
        }
    }

    @ViewBuilder private var inputSection: some View {
        Section {
            TextField("App Store link or app name", text: $input, axis: .vertical)
                .lineLimit(1...3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($typing)
                .disabled(isRunning)
                .onChange(of: input) { _, value in
                    let target = Undercut.target(from: value)
                    name = target?.name ?? ""
                    appID = target?.appID ?? ""
                }
            if badLink {
                Label("That isn't an App Store app link. Copy the link from the app's page with Share → Copy Link, "
                      + "or type the app's name.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            } else if !appID.isEmpty {
                TextField("App name", text: $name)
                    .focused($typing)
                    .disabled(isRunning)
                    .accessibilityLabel("App name, read from the link")
            }
        } header: {
            Text("Which app?")
        } footer: {
            Text(appID.isEmpty
                 ? "In the App Store, open the app, tap Share, then Copy Link, and paste it here. Or type its name."
                 : "Read from the link (App Store \(appID)). Correct the name if it's wrong.")
        }
        Section {
            if isRunning {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(service.undercutStep)
                }
                .frame(minHeight: 44)
            } else {
                Button {
                    start()
                } label: {
                    Label("Find a cheaper idea" + (cost.map { " · up to " + AppSettings.approximateCostText($0) } ?? ""),
                          systemImage: "scissors")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(cost == nil || badLink || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } footer: {
            Text(cost == nil
                 ? "This needs Claude with its API key, because it searches the web. See Settings → Advanced → AI & costs."
                 : "Claude searches the web (never the App Store itself) for the app's prices and the complaints about "
                   + "it, then writes ideas and the devil's advocate judges them. Takes about a minute. The cost is an "
                   + "upper guide and counts towards your daily AI spending limit.")
        }
    }

    /// Runs it in its own task, so closing the sheet doesn't waste the paid calls (the idea is still saved).
    private func start() {
        typing = false
        failure = nil
        let target = Undercut.Target(name: name, appID: appID)
        Task {
            do {
                made = try await service.undercut(target)
            } catch {
                guard !DigestService.isCancellation(error) else { return }
                let described = DigestWarning.describe(error)
                failure = (described.message, described.details)
            }
        }
    }
}
