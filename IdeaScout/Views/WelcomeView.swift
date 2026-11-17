// WelcomeView.swift
// First-launch welcome (four pages: what IdeaScout does, the free trial, your interest area and coding tool, and
// setting up an AI with guided key steps; usability review, 17 Nov 2026) and the ConsentView shown before any
// personal data goes to a cloud AI.

import SwiftUI

/// Shown once on first launch: what IdeaScout does, the free trial, what you're interested in, and setting up an AI.
struct WelcomeView: View {
    @Environment(StoreManager.self) private var store
    @AppStorage(AppSettings.Keys.onboarded) private var onboarded = false
    @AppStorage(AppSettings.Keys.aiProvider) private var provider = AIProvider.claude.rawValue
    @AppStorage(AppSettings.Keys.interestArea) private var interestArea = ""
    @AppStorage(AppSettings.Keys.starterKitTool) private var toolRaw = BuilderTool.claudeCode.rawValue
    @AppStorage(AppSettings.Keys.appType) private var appTypeRaw = ""
    /// 0 = intro, 1 = trial, 2 = about you, 3 = set up your AI.
    @State private var page = 0
    /// Shows the consent screen after "Done" when a cloud provider is chosen.
    @State private var showConsent = false
    /// Asks before finishing without a key ("No key yet").
    @State private var confirmNoKey = false
    /// Shows the other providers (Claude is the recommended default).
    @State private var showOthers = false
    @FocusState private var typing: Bool

    /// The provider picked on the last page.
    private var chosen: AIProvider { AIProvider(rawValue: provider) ?? .claude }

    var body: some View {
        NavigationStack {
            Group {
                switch page {
                case 0: intro
                case 1: trial
                case 2: aboutYou
                default: aiChoice
                }
            }
            .padding(24)
            .sheet(isPresented: $showConsent) {
                ConsentView(provider: chosen) { agreed in
                    if !agreed { provider = AIProvider.apple.rawValue }
                    onboarded = true
                }
            }
        }
        .interactiveDismissDisabled()
    }

    /// Page 1: what IdeaScout does.
    private var intro: some View {
        FillingScrollView { VStack(spacing: 18) {
            Spacer()
            Image(systemName: "lightbulb.max.fill").font(.system(size: 64)).foregroundStyle(.indigo)
                .accessibilityHidden(true)
            Text("Welcome to IdeaScout").font(.largeTitle.bold()).multilineTextAlignment(.center)
            Text("IdeaScout finds app ideas in your area that you can build yourself with an AI coding tool and sell for a quarter of what competitors charge, or less. A devil's advocate (a second, sceptical AI) tries to knock down every idea first, and each one comes with a starter kit to build it.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Spacer()
            primary("Continue") { page = 1 }
        } }
    }

    /// Page 2: start the free trial (or restore a purchase).
    private var trial: some View {
        FillingScrollView { VStack(spacing: 18) {
            Spacer()
            Image(systemName: "gift").font(.system(size: 56)).foregroundStyle(.indigo).accessibilityHidden(true)
            Text("Free for 7 days").font(.title.bold())
            Text("Then a one-off \(store.unlockPrice) to keep finding new ideas. No subscription. Your history and saved ideas always stay readable.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if let error = store.purchaseError {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Spacer()
            if store.access == .notStarted {
                primary("Start free trial") { Task { await store.startTrial(); if store.access.canRefresh { page = 2 } } }
            } else {
                primary("Continue") { page = 2 }
            }
            Button("Restore purchases") { Task { await store.restore() } }.frame(minHeight: 44)
        } }
    }

    /// Page 3: what the user is interested in and which tool they'll build with, so the first refresh fits them.
    /// Both can be skipped ("Not sure") and changed later in Settings.
    private var aboutYou: some View {
        Form {
            Section {
                TextField("For example: fitness coaching, bookkeeping", text: $interestArea).focused($typing)
            } header: {
                Text("What area interests you?")
            } footer: {
                Text("Ideas will be in this area. Leave it empty for any area.")
            }
            Section {
                Picker("Coding tool", selection: $toolRaw) {
                    ForEach(BuilderTool.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .onChange(of: toolRaw) { _, raw in
                    appTypeRaw = (BuilderTool(rawValue: raw) ?? .claudeCode).defaultAppType.rawValue
                }
            } header: {
                Text("Which tool will you build with?")
            } footer: {
                Text("Claude Code and Cursor build iPhone and iPad apps; Replit and Lovable build web apps. Not sure? "
                     + "Leave it on Claude Code.")
            }
        }
        .readableList()
        .safeAreaInset(edge: .bottom) { pinned { primary("Continue") { typing = false; page = 3 } } }
        .keyboardDone($typing)
        .navigationTitle("About you")
    }

    /// Page 4: set up an AI. Claude is the recommended default with numbered key steps; the others are one tap away.
    /// "Done" asks for consent if needed; with no key it says what that means first.
    private var aiChoice: some View {
        Form {
            if chosen.isCloud {
                Section {
                    stepRow(1, "Create an account at", link: chosen.keyURL)
                    stepRow(2, chosen == .claude ? "Add some credit (about $5 lasts weeks)" : "Add some credit or a payment method")
                    stepRow(3, "Create an API key, then copy it")
                    stepRow(4, "Paste it here")
                    // Safe to unwrap: every cloud provider (`isCloud`) has a Keychain key.
                    SecretField(title: "\(chosen.shortName) API key", key: chosen.keychainKey!).id(chosen)
                } header: {
                    Text("Set up \(chosen.shortName)")
                } footer: {
                    Text("An API key lets IdeaScout use \(chosen.shortName) on your behalf. You pay \(chosen.shortName) directly for what you use "
                         + "(about $0.20–0.45 a day with Claude). It's kept in this device's Keychain.")
                }
            }
            Section {
                DisclosureGroup("Use a different AI", isExpanded: $showOthers) {
                    Picker("AI", selection: $provider) {
                        ForEach(AIProvider.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            } footer: {
                if !chosen.isCloud {
                    Text("Apple's on-device AI is free and private but makes simpler trends and no killer ideas. You can add a cloud AI later in Settings.")
                }
            }
        }
        .readableList()
        // Pinned so it's always on screen, however long the steps make the page.
        .safeAreaInset(edge: .bottom) { pinned { primary("Done", action: finish) } }
        .navigationTitle("Set up your AI")
        .confirmationDialog("No key yet", isPresented: $confirmNoKey, titleVisibility: .visible) {
            Button("Continue anyway") { askConsentOrFinish() }
            Button("Add key", role: .cancel) {}
        } message: {
            Text("Without a key you'll get simple trends from Apple's on-device AI, not killer ideas. You can add a key later in Settings.")
        }
    }

    /// One numbered setup step, with a tappable link when there is one.
    @ViewBuilder private func stepRow(_ number: Int, _ text: String, link: String = "") -> some View {
        let address = link.split(separator: " ").first.map(String.init) ?? ""
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.headline.monospacedDigit()).foregroundStyle(.indigo).accessibilityHidden(true)
            if let url = URL(string: "https://" + address), !address.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(text)
                    Link(link, destination: url)
                }
            } else {
                Text(text)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(text) \(link)")
    }

    /// "Done": warns first when a cloud AI has no key, then asks for consent if needed.
    private func finish() {
        if chosen.isCloud, let key = chosen.keychainKey, (Keychain.get(key) ?? "").isEmpty {
            confirmNoKey = true
        } else {
            askConsentOrFinish()
        }
    }

    private func askConsentOrFinish() {
        if chosen.isCloud && !AppSettings.hasConsent(chosen) { showConsent = true } else { onboarded = true }
    }

    /// A bottom bar for a page's main button, like the rest of the app's pinned actions.
    private func pinned(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
    }

    /// A full-width prominent button (capped on large screens) with a 44-point minimum height.
    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity, minHeight: 44) }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: Layout.buttonWidth)
    }
}

/// Asks before any personal data goes to a third-party AI (Apple App Review Guideline 5.1.2).
struct ConsentView: View {
    /// The provider the user would be sharing data with.
    let provider: AIProvider
    /// Called with `true` after "Agree" (consent is already saved), `false` for "Don't share".
    var onDecision: (Bool) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("To make your daily ideas, IdeaScout sends the following to **\(provider.label)**, a company based in **\(provider.country)**:")
                    Label("Your About me, interest area and pain points", systemImage: "person.text.rectangle")
                    Label("Public posts and listings IdeaScout collected (e.g. Hacker News, App Store reviews, government contracts)", systemImage: "doc.text")
                    Label("Your saved project notes, when you ask for variant suggestions", systemImage: "note.text")
                } footer: {
                    Text("It's sent directly from your device using your own API key. IdeaScout has no server and never sees your data. \(provider.shortName)'s own privacy policy applies to what it receives. \(provider.dataNote ?? "")")
                }
                // Security: what users type here leaves the phone and is kept under the provider's own retention
                // rules (some providers are outside the user's country), so warn before anything is shared.
                Section {
                    Label {
                        Text("Don't include confidential company information, client names or personal details in About me or My pain points. Describe problems in general terms.")
                    } icon: {
                        Image(systemName: "exclamationmark.shield").foregroundStyle(.orange)
                    }
                }
            }
            .readableList()
            .navigationTitle("Share data with \(provider.shortName)?")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button {
                        AppSettings.setConsent(provider, true)
                        onDecision(true)
                        dismiss()
                    } label: { Text("Agree").frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.borderedProminent)
                    Button {
                        onDecision(false)
                        dismiss()
                    } label: { Text("Don't share · use Apple's on-device AI").frame(maxWidth: .infinity, minHeight: 44) }
                }
                .frame(maxWidth: Layout.buttonWidth)
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
        .interactiveDismissDisabled()
    }
}
