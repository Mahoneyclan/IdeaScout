// AppSettings+Costs.swift
// Cost estimates shown before paid AI actions: a refresh and "Suggest variants", and the cost text
// on buttons and confirmations.

import Foundation

extension AppSettings {
    /// Rough cost range of one full refresh (trends, ideas, devil's advocate), in US dollars, shown in Settings and on
    /// the refresh button. Fitted to measured Claude Opus costs (about $0.29 at 150 items, $0.40–0.45 at 300) so the
    /// high end isn't below them (owner's choice, 31 Oct 2026), and scaled by how the model's price compares with
    /// Opus's, so dearer models show more and cheaper ones less.
    /// - Parameters:
    ///   - items: Items the AI reads per refresh.
    ///   - price: The chosen model's price.
    /// - Returns: Low and high estimates; the high end is 1.5× the low.
    static func estimatedRefreshCost(items: Int, price: ModelPrice) -> ClosedRange<Double> {
        let base = (0.11 + Double(items) * 0.00064) * refreshPriceScale(price)
        return base...(base * 1.5)
    }

    /// Claude Opus's price when the refresh costs above were measured (the 4.x and 5.5 list price).
    static let refreshReferencePrice = ModelPrice(input: 4, output: 20)

    /// How a model's price compares with `refreshReferencePrice`, for a refresh's token mix. A refresh reads far
    /// more than it writes; 5 input tokens per output token is a round figure close to the measured runs.
    /// - Parameter price: The model's price.
    /// - Returns: The multiplier: 1 for Opus, 2.5 for a model at $10/$50, 0 for a free model.
    static func refreshPriceScale(_ price: ModelPrice) -> Double {
        price.cost(input: 500_000, output: 100_000) / refreshReferencePrice.cost(input: 500_000, output: 100_000)
    }

    /// The price of the cloud model a refresh would use: the chosen provider when it has a key. Consent isn't
    /// checked because the refresh button asks for it before running.
    /// - Returns: The model's price, or `nil` when the refresh would be free (Apple on-device or keywords).
    /// - Note: Reads the Keychain, so call it on demand rather than in every view update.
    static func chosenModelPrice() -> ModelPrice? {
        guard provider.isCloud, provider.keychainKey.flatMap({ Keychain.get($0) }) != nil else { return nil }
        return price(for: provider, model: model(for: provider))
    }

    /// The refresh cost for buttons and confirmations.
    /// - Parameters:
    ///   - items: Items the AI reads per refresh.
    ///   - price: The chosen model's price, or `nil` when the refresh is free.
    /// - Returns: "Free", or the high estimate as in `approximateCostText` ("~$0.45").
    static func refreshCostText(items: Int, price: ModelPrice?) -> String {
        guard let price else { return "Free" }
        return approximateCostText(estimatedRefreshCost(items: items, price: price).upperBound)
    }

    /// Rough cost of one "Suggest variants" request, in US dollars. Assumes 1,500 input tokens (instructions,
    /// the project and the user's notes) and 1,500 output tokens (4–6 suggestions plus any reasoning), which
    /// is generous for a typical project, so treat it as an upper guide.
    /// - Parameter price: The chosen model's price.
    /// - Returns: The estimated cost.
    static func estimatedSuggestionCost(price: ModelPrice) -> Double {
        price.cost(input: 1_500, output: 1_500)
    }

    /// The estimated cost of "Suggest variants" with the current settings.
    /// - Returns: The cost when the request would go to a paid cloud provider (chosen, agreed to and with a
    ///   key, the same test `makeSummarizer` uses), or `nil` when it would be free (Apple on-device or keywords).
    /// - Note: Reads the Keychain, so call it on demand rather than in every view update.
    static func suggestionCost() -> Double? {
        guard hasConsent(provider), let price = chosenModelPrice() else { return nil }
        return estimatedSuggestionCost(price: price)
    }

    /// Rough cost of one starter kit, in US dollars. Assumes 2,500 input tokens (instructions and the idea) and
    /// 6,000 output tokens (the kit plus the model's thinking, which is billed as output), so treat it as an upper guide.
    /// - Parameter price: The chosen model's price.
    /// - Returns: The estimated cost.
    static func estimatedStarterKitCost(price: ModelPrice) -> Double {
        price.cost(input: 2_500, output: 6_000)
    }

    /// The estimated cost of a starter kit with the current settings.
    /// - Returns: The cost when a paid cloud AI is chosen, agreed to and has a key; `nil` when kits can't be made.
    /// - Note: Reads the Keychain, so call it on demand rather than in every view update.
    static func starterKitCost() -> Double? {
        guard hasConsent(provider), let price = chosenModelPrice() else { return nil }
        return estimatedStarterKitCost(price: price)
    }

    /// A cost for buttons and confirmations: "~$0.02", or "<$0.01" when it would round to nothing.
    /// - Parameter cost: US dollars.
    /// - Returns: The text to show.
    static func approximateCostText(_ cost: Double) -> String {
        cost < 0.01 ? "<$0.01" : "~" + cost.formatted(.currency(code: "USD"))
    }
}
