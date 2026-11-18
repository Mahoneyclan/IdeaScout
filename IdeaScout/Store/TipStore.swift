// TipStore.swift
// "Shout me a coffee" (owner, 15 and 17 Nov 2026): IdeaScout is free, with three optional tips as consumable in-app
// purchases. Tips unlock nothing. If Apple can't supply the products (for example before the Paid Apps Agreement is
// signed), the list is empty and the Support section hides itself. StoreKit sits behind `TipShop`, so the rules can
// be tested without the App Store. Product IDs must match App Store Connect and IdeaScout.storekit, and are permanent.

import Foundation
import StoreKit

/// One tip as shown: its name and Apple's localised price.
struct Tip: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var price: String
}

/// How a tip purchase ended.
enum TipOutcome: Equatable, Sendable {
    case thanked
    /// Waiting for approval (Ask to Buy); it completes later on its own.
    case pending
    case cancelled
    /// Apple's signature didn't check out, so it isn't counted.
    case unverified
}

/// Where tips come from: the App Store in the app, a stand-in in tests.
protocol TipShop: Sendable {
    func tips(_ ids: [String]) async throws -> [Tip]
    func buy(_ id: String) async throws -> TipOutcome
}

/// The tips and the last purchase's result, for the Support section.
@MainActor
@Observable
final class TipStore {
    static let shared = TipStore(shop: {
        guard TestMode.isUITesting else { return AppStoreTipShop() as any TipShop }
        #if DEBUG
        if TestMode.has(TestMode.Argument.screenshots) { return SampleTipShop() }
        #endif
        return NoTipShop()
    }())

    /// Permanent product IDs, smallest first, with their names on screen.
    nonisolated static let catalogue: [(id: String, name: String)] = [
        ("com.mahoney.IdeaScout.tip.small", "Small coffee"),
        ("com.mahoney.IdeaScout.tip.medium", "Large coffee"),
        ("com.mahoney.IdeaScout.tip.large", "Coffee and cake"),
    ]

    /// The tips Apple supplied, in catalogue order; empty hides the Support section.
    private(set) var tips: [Tip] = []
    /// The tip being bought, so its button can show progress and the others wait.
    private(set) var buying: String?
    /// Shown after a tip: "Thank you!" or why it didn't go through.
    private(set) var message: String?
    /// Technical detail for a failure, behind "Details".
    private(set) var details: String?

    private let shop: any TipShop
    @ObservationIgnored private var updates: Task<Void, Never>?

    init(shop: any TipShop) { self.shop = shop }

    /// Loads the tips (quietly: no tips just means no Support section) and, once, starts finishing any tip that
    /// completes outside a purchase call (Ask to Buy, an interrupted purchase), as Apple requires.
    func load() async {
        if updates == nil && !TestMode.isUITesting {
            updates = Task.detached {
                for await update in Transaction.updates {
                    if case .verified(let transaction) = update { await transaction.finish() }
                }
            }
        }
        tips = Self.ordered((try? await shop.tips(Self.catalogue.map(\.id))) ?? [])
    }

    /// Buys one tip. Nothing is unlocked; the result is only a message.
    func buy(_ tip: Tip) async {
        guard buying == nil else { return }
        buying = tip.id
        message = nil
        details = nil
        defer { buying = nil }
        do {
            message = Self.message(for: try await shop.buy(tip.id))
        } catch {
            message = "The tip didn't go through. You haven't been charged."
            details = error.localizedDescription
        }
    }

    /// Keeps only known tips, in catalogue order (smallest first), with our names.
    nonisolated static func ordered(_ found: [Tip]) -> [Tip] {
        catalogue.compactMap { entry in
            found.first { $0.id == entry.id }.map { Tip(id: $0.id, name: entry.name, price: $0.price) }
        }
    }

    /// What to say after a purchase; `nil` when the user cancelled.
    nonisolated static func message(for outcome: TipOutcome) -> String? {
        switch outcome {
        case .thanked: "Thank you! That really helps."
        case .pending: "Your tip is waiting for approval. Thank you!"
        case .cancelled: nil
        case .unverified: "The App Store couldn't confirm the tip, so it wasn't counted."
        }
    }
}

/// The real App Store, through StoreKit 2.
struct AppStoreTipShop: TipShop {
    func tips(_ ids: [String]) async throws -> [Tip] {
        try await Product.products(for: ids).map { Tip(id: $0.id, name: $0.displayName, price: $0.displayPrice) }
    }

    func buy(_ id: String) async throws -> TipOutcome {
        guard let product = try await Product.products(for: [id]).first else { throw StoreKitError.notAvailableInStorefront }
        switch try await product.purchase() {
        case .success(.verified(let transaction)):
            await transaction.finish()   // a consumable: finishing it is all that's needed
            return .thanked
        case .success(.unverified(let transaction, _)):
            await transaction.finish()
            return .unverified
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: return .cancelled
        }
    }
}

/// Screen tests: no App Store, so no tips and no Support section.
struct NoTipShop: TipShop {
    func tips(_ ids: [String]) async throws -> [Tip] { [] }
    func buy(_ id: String) async throws -> TipOutcome { .cancelled }
}

#if DEBUG
/// App Store screenshots: sample tips with sample prices (Apple sets the real ones per country).
struct SampleTipShop: TipShop {
    func tips(_ ids: [String]) async throws -> [Tip] {
        zip(ids, ["$1.99", "$4.99", "$9.99"]).map { Tip(id: $0, name: "", price: $1) }
    }
    func buy(_ id: String) async throws -> TipOutcome { .thanked }
}
#endif
