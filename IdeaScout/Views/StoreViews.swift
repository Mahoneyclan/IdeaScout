// StoreViews.swift
// Screens for the trial and one-off unlock: the paywall sheet and the status row in Settings. The logic
// lives in StoreManager.

import SwiftUI

/// Start the free trial, or unlock after it ends. History and saved ideas stay readable either way.
struct PaywallView: View {
    @Environment(StoreManager.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// True while a purchase or restore is in progress (buttons are disabled).
    @State private var working = false

    var body: some View {
        NavigationStack {
            FillingScrollView { VStack(spacing: 20) {
                Image(systemName: "lightbulb.max.fill")
                    .font(.system(size: 56)).foregroundStyle(.indigo)
                    .accessibilityHidden(true)
                Text(headline).font(.title2.bold()).multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 10) {
                    Label("A fresh scan for money-making ideas every day", systemImage: "sun.max")
                    Label("Pain clusters, trends and devil's-advocate checks", systemImage: "checkmark.seal")
                    Label("Use the AI provider of your choice", systemImage: "cpu")
                    Label("Your history and saved ideas always stay yours", systemImage: "bookmark")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                if let error = store.purchaseError {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                VStack(spacing: 10) {
                    if store.access == .notStarted {
                        Button { run { await store.startTrial() } } label: {
                            Text("Start free 7-day trial").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if store.access == .notStarted {
                        Button { run { await store.unlock() } } label: {
                            Text("Unlock forever · \(store.unlockPrice)").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button { run { await store.unlock() } } label: {
                            Text("Unlock forever · \(store.unlockPrice)").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("Restore purchases") { run { await store.restore() } }
                        .frame(minHeight: 44)
                }
                .frame(maxWidth: Layout.buttonWidth)
                .disabled(working)
                Text("One-off purchase, no subscription. You pay your AI provider directly for its use.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(24) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onChange(of: store.access) { _, access in if access.canRefresh { dismiss() } }
        }
    }

    /// Title matching the current access state.
    private var headline: String {
        switch store.access {
        case .notStarted: "Try IdeaScout free for 7 days"
        case .expired: "Your free trial has ended"
        case .trial(let days): "\(days) day\(days == 1 ? "" : "s") left in your trial"
        case .unlocked, .developer: "IdeaScout is unlocked"
        }
    }

    /// Runs a purchase action with the buttons disabled until it finishes.
    private func run(_ action: @escaping () async -> Void) {
        working = true
        Task { await action(); working = false }
    }
}

/// One row describing the trial or unlock, used in Settings.
struct AccessStatusRow: View {
    @Environment(StoreManager.self) private var store
    @State private var showPaywall = false

    var body: some View {
        Button { showPaywall = true } label: {
            LabeledContent("IdeaScout", value: text)
        }
        .frame(minHeight: 44)
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }

    /// Status text, e.g. "Trial · 3 days left".
    private var text: String {
        switch store.access {
        case .unlocked: "Unlocked"
        case .trial(let days): "Trial · \(days) day\(days == 1 ? "" : "s") left"
        case .notStarted: "Start free trial"
        case .expired: "Trial ended · Unlock"
        case .developer: "Developer build"
        }
    }
}
