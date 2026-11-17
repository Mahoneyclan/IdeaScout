// RefreshViews.swift
// The top of the Ideas tab: today's status row, pull-to-refresh with its cost pop-up, and why there are no ideas yet.

import SwiftUI
import SwiftData

/// The first row of the Ideas tab: refresh progress, or when today's digest was made, how many ideas it
/// produced and the latest note (e.g. limit reached). Tapping it opens today's full digest.
struct TodayStatus: View {
    /// Today's digest, if there is one.
    let today: Digest?
    /// All ideas, to count today's.
    let ideas: [KillerIdea]
    @Environment(DigestService.self) private var service

    var body: some View {
        if service.isRefreshing {
            let step = service.stage?.rawValue ?? 1
            VStack(alignment: .leading, spacing: 6) {
                Text("Step \(step) of \(DigestService.Stage.allCases.count) · \(service.stage?.label ?? "Starting")…")
                    .font(.subheadline)
                ProgressView(value: Double(step), total: Double(DigestService.Stage.allCases.count))
                Text("Takes a few minutes. Keep the app open.").font(.caption).foregroundStyle(.secondary)
            }
        } else if let today {
            let found = KillerIdea.seen(on: today.day, in: ideas).count
            NavigationLink {
                DigestContentView(digest: today)
                    .navigationTitle(today.day.formatted(date: .abbreviated, time: .omitted))
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Updated \(today.createdAt.formatted(date: .omitted, time: .shortened)) · \(found) idea\(found == 1 ? "" : "s") today",
                          systemImage: "checkmark.circle")
                        .font(.subheadline)
                    // Show the reason inline (e.g. limit reached, every idea rejected) rather than a count.
                    if let note = service.lastError ?? today.warnings.last.map({ DigestWarning.parts($0).message }) {
                        Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("No refresh yet today", systemImage: "sun.max").font(.subheadline)
                if let error = service.lastError { Text(error).font(.caption).foregroundStyle(.secondary) }
                Text("Pull down to find today's ideas.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Pull to refresh

/// Refreshing by pulling the list down, or with the small ↻ button in the top bar (for people who don't know the
/// gesture, and for VoiceOver and Switch Control). Every refresh asks first in a pop-up with its cost, because a pull
/// is easy to make by accident and a refresh costs money (owner, 17 Nov 2026).
struct PullToRefresh: ViewModifier {
    @Environment(DigestService.self) private var service
    @Environment(StoreManager.self) private var store
    @State private var showPaywall = false
    @State private var showConsent = false
    /// Shows the "Find today's ideas?" pop-up.
    @State private var confirm = false
    @Query(sort: \Digest.createdAt, order: .reverse) private var digests: [Digest]
    @AppStorage(AppSettings.Keys.claudeMaxItems) private var maxItems = AppSettings.defaultClaudeMaxItems
    @AppStorage(AppSettings.Keys.dailyCap) private var dailyCap = AppSettings.defaultDailyCap
    @AppStorage(AppSettings.Keys.aiProvider) private var providerRaw = AIProvider.claude.rawValue
    /// The chosen cloud model's price, or `nil` when a refresh is free. Kept here because looking it up reads
    /// the Keychain; refreshed when the screen appears (after any change in Settings) and when the AI changes.
    @State private var price: ModelPrice?

    /// The estimated cost of one refresh: "~$0.45", or "Free".
    private var costText: String {
        AppSettings.refreshCostText(items: maxItems, price: price, mixed: AppSettings.usesMixedModels,
                                    priceCheck: AppSettings.provider == .claude)
    }

    private var hasToday: Bool { digests.contains { Calendar.current.isDateInToday($0.day) } }

    func body(content: Content) -> some View {
        content
            // The pull only opens the pop-up; the refresh itself runs after "Refresh", with its own progress row.
            .refreshable { request() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Refresh", systemImage: "arrow.clockwise", action: request)
                        .disabled(service.isRefreshing)
                }
            }
            .sheet(isPresented: $showPaywall) { PaywallView() }
            .sheet(isPresented: $showConsent) {
                ConsentView(provider: AppSettings.provider) { agreed in if agreed { confirm = true } }
            }
            .onAppear { price = AppSettings.chosenModelPrice() }
            .onChange(of: providerRaw) { price = AppSettings.chosenModelPrice() }
            .alert(hasToday ? "Run another refresh today?" : "Find today's ideas?", isPresented: $confirm) {
                Button("Cancel", role: .cancel) {}
                Button("Refresh (\(costText))") { Task { await service.refresh(force: true) } }
            } message: {
                let spent = UsageTracker.summary().today.cost.formatted(.currency(code: "USD"))
                let limit = dailyCap > 0 ? " of \(dailyCap.formatted(.currency(code: "USD")))" : ""
                Text((hasToday ? "Today's refresh already ran. " : "Takes a few minutes. Keep the app open. ")
                     + "Spent today: \(spent)\(limit).")
            }
    }

    /// Asks first: the paywall after the trial, consent before a cloud AI, otherwise the cost pop-up.
    private func request() {
        guard !service.isRefreshing else { return }
        if !store.access.canRefresh { showPaywall = true }
        else if AppSettings.needsConsent { showConsent = true }
        else { confirm = true }
    }
}

extension View {
    /// Pull down (or tap ↻) to refresh, always confirmed in a pop-up with the cost.
    func pullToRefresh() -> some View { modifier(PullToRefresh()) }
}

// MARK: - No ideas yet

/// Shown on the Ideas tab when there are no ideas to list: why, and what to do (usability review, 17 Nov 2026).
struct IdeasEmptyState: View {
    /// Today's latest note (a warning from the last refresh), if any.
    let lastNote: String?
    let refreshedToday: Bool
    /// Read when the screen appears (it reads the Keychain); `nil` until then, or when there's nothing to add.
    @State private var reason: NoIdeasReason?
    @State private var checked = false

    var body: some View {
        if let reason {
            VStack(alignment: .leading, spacing: 8) {
                Label(reason.title, systemImage: reason.needsAISettings ? "key" : "lightbulb").font(.headline)
                Text(reason.message).foregroundStyle(.secondary)
                if reason.needsAISettings {
                    NavigationLink { AISettings() } label: { Text("Set up your AI").frame(minHeight: 44) }
                }
            }
            .padding(.vertical, 4)
        } else if !checked {
            Color.clear.frame(height: 1)
                .onAppear {
                    checked = true
                    reason = NoIdeasReason.make(hasCloudAI: AppSettings.provider.isCloud
                                                    && AppSettings.makeClient(for: AppSettings.provider) != nil
                                                    && AppSettings.hasConsent(AppSettings.provider),
                                                overLimit: AppSettings.isOverDailyCap, refreshedToday: refreshedToday,
                                                lastNote: lastNote)
                }
        }
    }
}

/// Why the Ideas tab is empty, in plain words, and whether the fix is in the AI settings.
struct NoIdeasReason: Equatable {
    var title: String
    var message: String
    var needsAISettings = false

    /// The most useful reason first: no AI that can make ideas, then the spending limit, then the last refresh's note.
    /// - Returns: `nil` when nothing is wrong and there's simply been no refresh yet (the status row already says
    ///   to tap the button).
    static func make(hasCloudAI: Bool, overLimit: Bool, refreshedToday: Bool, lastNote: String?) -> NoIdeasReason? {
        if !hasCloudAI {
            return NoIdeasReason(title: "Ideas need a cloud AI",
                                 message: "Apple's on-device AI can only group trends. Add a Claude key (or another AI's) "
                                    + "and agree to share data with it, then refresh.", needsAISettings: true)
        }
        if overLimit {
            return NoIdeasReason(title: "Today's spending limit is reached",
                                 message: "Refresh again tomorrow, or raise the daily limit.", needsAISettings: true)
        }
        if refreshedToday, let lastNote, !lastNote.isEmpty {
            return NoIdeasReason(title: "No ideas from today's refresh", message: lastNote)
        }
        return refreshedToday ? NoIdeasReason(title: "No ideas from today's refresh",
                                              message: "Every idea was too weak or rejected. Try again tomorrow, or widen your interest area in Settings.") : nil
    }
}
