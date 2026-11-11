// StoreManager.swift
// The free 7-day trial and the one-off $1.99 unlock. DigestService asks it whether a refresh is allowed;
// PaywallView, AccessStatusRow, WelcomeView and RefreshBar show its state and start purchases.
// Product IDs must match the in-app purchases in App Store Connect and IdeaScout.storekit (local testing).

import Foundation
import StoreKit

/// The free 7-day trial and the one-off unlock, using StoreKit 2.
/// Apple's rule for trials in non-subscription apps: the trial is a free ($0) non-consumable
/// in-app purchase named "7-Day Trial". Its purchase date is the trial start, kept by Apple,
/// so reinstalling the app doesn't restart the trial.
@MainActor
@Observable
final class StoreManager {
    /// The single shared instance, injected into SwiftUI by IdeaScoutApp. Runs on the main thread
    /// (`@MainActor`) because views observe its state (Observation).
    static let shared = StoreManager()

    /// Product ID of the $0 "7-Day Trial" non-consumable.
    nonisolated static let trialID = "com.mahoney.IdeaScout.trial7"
    /// Product ID of the $1.99 one-off unlock non-consumable.
    nonisolated static let unlockID = "com.mahoney.IdeaScout.unlock"
    /// Trial length, counted from the trial purchase date.
    nonisolated static let trialDays = 7

    /// What the user may do right now.
    enum Access: Equatable {
        /// Bought the unlock: everything works, forever.
        case unlocked
        /// Within the 7-day trial; `daysLeft` is rounded up (the last day shows 1).
        case trial(daysLeft: Int)
        /// Trial not started yet: no new refreshes until it is.
        case notStarted
        /// Trial over and not unlocked: history and saved ideas stay readable, new refreshes are blocked.
        case expired
        /// Developer builds only, when the products aren't set up in App Store Connect yet.
        case developer

        /// Whether new refreshes (and so new AI spending) are allowed.
        var canRefresh: Bool {
            switch self {
            case .unlocked, .trial, .developer: true
            case .notStarted, .expired: false
            }
        }
    }

    /// Store products by ID, once loaded. Empty if the App Store couldn't be reached or the products
    /// aren't set up yet.
    private(set) var products: [String: Product] = [:]
    /// Whether a verified, unrefunded unlock exists.
    private(set) var isUnlocked = false
    /// When the trial was started (Apple's original purchase date), or `nil`.
    private(set) var trialStart: Date?
    /// Set after the first load, so `access` doesn't report "developer" before products had a chance to load.
    private(set) var loaded = false
    /// A plain message for the last failed or pending purchase, shown on the paywall and welcome screens.
    var purchaseError: String?

    /// Listens for transactions that arrive outside a purchase call. Lives as long as the app.
    @ObservationIgnored private var updates: Task<Void, Never>?

    /// The user's current access, combining the purchases with the developer-build rule below.
    var access: Access {
        if TestMode.isUITesting {   // UI tests: fixed state, changed by the fake purchases below
            return Self.access(unlocked: isUnlocked, trialStart: trialStart ?? Self.testTrialStart, now: .now)
        }
        let state = Self.access(unlocked: isUnlocked, trialStart: trialStart, now: .now)
        #if DEBUG
        // Side-loaded developer builds can't reach the store products until they exist in App Store Connect.
        if !state.canRefresh && products.isEmpty && loaded { return .developer }
        #endif
        return state
    }

    /// The trial and unlock rules, separated out so they can be unit tested.
    /// - Parameters:
    ///   - unlocked: Whether the unlock was bought.
    ///   - trialStart: When the trial began, if it did.
    ///   - now: The time to evaluate at.
    /// - Returns: The access level.
    nonisolated static func access(unlocked: Bool, trialStart: Date?, now: Date) -> Access {
        if unlocked { return .unlocked }
        guard let trialStart else { return .notStarted }
        let end = trialStart.addingTimeInterval(Double(trialDays) * 86_400)
        guard now < end else { return .expired }
        let days = Int((end.timeIntervalSince(now) / 86_400).rounded(.up))
        return .trial(daysLeft: max(days, 1))
    }

    /// UI tests: a trial started yesterday, or 8 days ago with `-ui-trial-expired`.
    private static var testTrialStart: Date {
        Date.now.addingTimeInterval((TestMode.has(TestMode.Argument.trialExpired) ? -8 : -1) * 86_400)
    }

    /// Loads products and current purchases once, and starts listening for purchases made elsewhere
    /// (another device, Ask to Buy, refunds). In UI-test mode there is no App Store: it just marks itself loaded.
    func load() async {
        guard !TestMode.isUITesting else { loaded = true; return }
        if updates == nil {
            updates = Task { [weak self] in
                for await update in Transaction.updates {
                    if case .verified(let transaction) = update { await transaction.finish() }
                    await self?.refreshEntitlements()
                }
            }
        }
        if let found = try? await Product.products(for: [Self.trialID, Self.unlockID]) {
            products = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
        }
        await refreshEntitlements()
        loaded = true
    }

    /// Loads once if not loaded yet. DigestService awaits this before deciding whether a refresh may run.
    func ensureLoaded() async {
        if !loaded { await load() }
    }

    /// Re-reads the user's current purchases from StoreKit. Only verified, unrevoked transactions count,
    /// so refunded or tampered purchases don't unlock anything.
    func refreshEntitlements() async {
        var unlocked = false
        var start: Date?
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement, transaction.revocationDate == nil else { continue }
            if transaction.productID == Self.unlockID { unlocked = true }
            if transaction.productID == Self.trialID { start = transaction.originalPurchaseDate }
        }
        isUnlocked = unlocked
        trialStart = start
    }

    /// Starts the free trial (a $0 purchase). Result is reflected in `access`; errors in `purchaseError`.
    func startTrial() async { await buy(Self.trialID) }
    /// Buys the one-off unlock. Result is reflected in `access`; errors in `purchaseError`.
    func unlock() async { await buy(Self.unlockID) }

    /// Asks the App Store to re-sync purchases (e.g. on a new iPhone). May prompt for the Apple ID password.
    func restore() async {
        purchaseError = nil
        do { try await AppStore.sync() } catch { purchaseError = error.localizedDescription }
        await refreshEntitlements()
    }

    /// Runs one purchase and finishes the transaction. Cancelling isn't an error; "pending" means Ask to
    /// Buy or another approval is waiting.
    private func buy(_ id: String) async {
        purchaseError = nil
        if TestMode.isUITesting {   // UI tests: no App Store; purchases succeed instantly
            if id == Self.unlockID { isUnlocked = true } else { trialStart = .now }
            return
        }
        if products.isEmpty { await load() }
        guard let product = products[id] else {
            purchaseError = "The App Store isn't available right now. Try again later."
            return
        }
        do {
            switch try await product.purchase() {
            case .success(let result):
                if case .verified(let transaction) = result { await transaction.finish() }
                else { purchaseError = "The purchase couldn't be verified." }
            case .pending:
                purchaseError = "The purchase is waiting for approval."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
        await refreshEntitlements()
    }

    /// The unlock's localised price from the App Store, or "$1.99" before products load.
    var unlockPrice: String { products[Self.unlockID]?.displayPrice ?? "$1.99" }
}
