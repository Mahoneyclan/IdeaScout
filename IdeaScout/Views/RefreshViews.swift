// RefreshViews.swift
// The top of the Ideas tab: today's status row and the refresh button with its cost.

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
                Text("Use the button below to find today's ideas.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Refresh button

/// The main action, at the bottom of the screen where the thumb rests. The first refresh of the day
/// runs straight away; another one the same day asks first, because it costs money.
struct RefreshBar: View {
    @Environment(DigestService.self) private var service
    @Environment(StoreManager.self) private var store
    @State private var showPaywall = false
    @State private var showConsent = false
    @Query(sort: \Digest.createdAt, order: .reverse) private var digests: [Digest]
    @AppStorage(AppSettings.Keys.claudeMaxItems) private var maxItems = AppSettings.defaultClaudeMaxItems
    @AppStorage(AppSettings.Keys.dailyCap) private var dailyCap = AppSettings.defaultDailyCap
    @AppStorage(AppSettings.Keys.aiProvider) private var providerRaw = AIProvider.claude.rawValue
    /// Shows the "Run another refresh today?" confirmation.
    @State private var confirm = false
    /// The chosen cloud model's price, or `nil` when a refresh is free. Kept here because looking it up reads
    /// the Keychain; refreshed when the screen appears (after any change in Settings) and when the AI changes.
    @State private var price: ModelPrice?

    /// The estimated cost of one refresh, shown on the button: "~$0.45", or "Free".
    private var costText: String {
        AppSettings.refreshCostText(items: maxItems, price: price)
    }

    var body: some View {
        let hasToday = digests.contains { Calendar.current.isDateInToday($0.day) }
        Button {
            if !store.access.canRefresh { showPaywall = true }
            else if AppSettings.needsConsent { showConsent = true }
            else if hasToday { confirm = true }
            else { Task { await service.refresh(force: true) } }
        } label: {
            Label(!store.access.canRefresh ? (store.access == .expired ? "Unlock to find new ideas · \(store.unlockPrice)" : "Start free trial")
                  : service.isRefreshing ? "Refreshing…" : (hasToday ? "Refresh again · \(costText)" : "Find today's ideas · \(costText)"),
                  systemImage: store.access.canRefresh ? "arrow.clockwise" : "lock.open")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .sheet(isPresented: $showConsent) {
            ConsentView(provider: AppSettings.provider) { agreed in
                // Continue what the user asked for: refresh now, or confirm first if today already ran (it costs money).
                if agreed { if hasToday { confirm = true } else { Task { await service.refresh(force: true) } } }
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(service.isRefreshing)
        .frame(maxWidth: Layout.buttonWidth)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .onAppear { price = AppSettings.chosenModelPrice() }
        .onChange(of: providerRaw) { price = AppSettings.chosenModelPrice() }
        .confirmationDialog("Run another refresh today?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Refresh (\(costText))") { Task { await service.refresh(force: true) } }
        } message: {
            let spent = UsageTracker.summary().today.cost.formatted(.currency(code: "USD"))
            Text(dailyCap > 0 ? "Today's refresh already ran. Spent today: \(spent) of \(dailyCap.formatted(.currency(code: "USD")))."
                              : "Today's refresh already ran. Spent today: \(spent).")
        }
    }
}
