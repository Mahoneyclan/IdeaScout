// WelcomeView.swift
// First-launch welcome (three pages: what IdeaScout does, the free trial, choosing an AI) and the
// ConsentView shown before any personal data goes to a cloud AI.

import SwiftUI

/// Shown once on first launch: what IdeaScout does, the free trial, and choosing an AI.
struct WelcomeView: View {
    @Environment(StoreManager.self) private var store
    @AppStorage(AppSettings.Keys.onboarded) private var onboarded = false
    @AppStorage(AppSettings.Keys.aiProvider) private var provider = AIProvider.claude.rawValue
    /// 0 = intro, 1 = trial, 2 = choose your AI.
    @State private var page = 0
    /// Shows the consent screen after "Done" when a cloud provider is chosen.
    @State private var showConsent = false

    /// The provider picked on the last page.
    private var chosen: AIProvider { AIProvider(rawValue: provider) ?? .claude }

    var body: some View {
        NavigationStack {
            Group {
                switch page {
                case 0: intro
                case 1: trial
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
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "lightbulb.max.fill").font(.system(size: 64)).foregroundStyle(.indigo)
                .accessibilityHidden(true)
            Text("Welcome to IdeaScout").font(.largeTitle.bold()).multilineTextAlignment(.center)
            Text("Every day IdeaScout reads what businesses complain about, pay for and build, groups it into pain clusters and trends, and proposes business ideas that survive a devil's-advocate check.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Spacer()
            primary("Continue") { page = 1 }
        }
    }

    /// Page 2: start the free trial (or restore a purchase).
    private var trial: some View {
        VStack(spacing: 18) {
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
        }
    }

    /// Page 3: choose a provider and paste its key; "Done" asks for consent if needed, then finishes.
    private var aiChoice: some View {
        Form {
            Section {
                Picker("Provider", selection: $provider) {
                    ForEach(AIProvider.allCases) { Text($0.label).tag($0.rawValue) }
                }
                if chosen.isCloud {
                    SecretField(title: "\(chosen.shortName) API key", key: chosen.keychainKey!).id(chosen)
                }
            } header: {
                Text("Choose your AI")
            } footer: {
                Text(chosen.isCloud
                     ? "Get a key at \(chosen.keyURL). You pay \(chosen.shortName) directly for what you use (about $0.20–0.45 a day with Claude). You can change this later in Settings."
                     : "Apple's on-device AI is free and private but makes simpler trends and no killer ideas. You can add a cloud AI later in Settings.")
            }
            Section {
                Button {
                    if chosen.isCloud && !AppSettings.hasConsent(chosen) { showConsent = true } else { onboarded = true }
                } label: {
                    Text("Done").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Almost there")
    }

    /// A full-width prominent button with a 44-point minimum height.
    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity, minHeight: 44) }
            .buttonStyle(.borderedProminent)
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
                    Label("Your About me, industry focus and business challenges", systemImage: "person.text.rectangle")
                    Label("Public posts and listings IdeaScout collected (e.g. Hacker News, App Store reviews, government contracts)", systemImage: "doc.text")
                    Label("Your saved project notes, when you ask for variant suggestions", systemImage: "note.text")
                } footer: {
                    Text("It's sent directly from your iPhone using your own API key. IdeaScout has no server and never sees your data. \(provider.shortName)'s own privacy policy applies to what it receives. \(provider.dataNote ?? "")")
                }
                // Security: what users type here leaves the phone and is kept under the provider's own retention
                // rules (some providers are outside the user's country), so warn before anything is shared.
                Section {
                    Label {
                        Text("Don't include confidential company information, client names or personal details in About me or My Business Challenges. Describe problems in general terms.")
                    } icon: {
                        Image(systemName: "exclamationmark.shield").foregroundStyle(.orange)
                    }
                }
            }
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
                .padding(16)
                .background(.bar)
            }
        }
        .interactiveDismissDisabled()
    }
}
