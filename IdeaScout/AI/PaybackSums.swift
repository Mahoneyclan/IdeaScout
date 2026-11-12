// PaybackSums.swift
// Test 5, "sales cover the build cost", worked out from a first year of sales (owner, 12 Nov 2026): the build, the
// yearly fixed costs (hosting and similar; Apple's developer fee isn't counted, owner 13 Nov 2026), each customer's
// running cost, and whether the app is sold once or by subscription. To be cautious, the sums use half the AI's
// customer guess (owner, 13 Nov 2026). Customers arrive evenly across the year; a one-off customer pays
// once but keeps costing to run, a subscriber pays monthly until they leave. The sums are done here, not by the AI.

import Foundation

/// How an app is sold. The raw values are stored (in `SalesPlan` JSON), so they're permanent.
enum SalesModel: String, Codable, Sendable, CaseIterable {
    case oneOff = "one_off"
    case subscription

    /// "Pay once" or "Subscription".
    var label: String { self == .oneOff ? "Pay once" : "Subscription" }
}

/// How an idea is sold and what it costs to keep running: chosen by the AI that proposed it, checked and costed by the
/// devil's advocate. Stored as JSON on `KillerIdea`, so its property names are permanent.
struct SalesPlan: Codable, Equatable, Sendable {
    var model = SalesModel.subscription
    /// Why this way of selling suits the app, in one sentence.
    var reason = ""
    /// What each customer costs the builder per month (AI calls, hosting, data), in US dollars.
    var runningCostPerCustomer = 0.0
    /// Fixed yearly costs (hosting, a domain, keeping the tool's plan), in US dollars. Apple's developer fee isn't counted.
    var otherYearlyCosts = 0.0
    /// For a subscription, the share of customers who cancel each month, in percent.
    var monthlyChurnPercent = 0.0
}

extension SalesPlan {
    /// Tolerant decoding: keys added later may be missing from data saved earlier (stored data is permanent).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = (try? c.decodeIfPresent(SalesModel.self, forKey: .model)) ?? .subscription
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        runningCostPerCustomer = try c.decodeIfPresent(Double.self, forKey: .runningCostPerCustomer) ?? 0
        otherYearlyCosts = try c.decodeIfPresent(Double.self, forKey: .otherYearlyCosts) ?? 0
        monthlyChurnPercent = try c.decodeIfPresent(Double.self, forKey: .monthlyChurnPercent) ?? 0
    }

    /// The plan with the AI's numbers kept in believable ranges (AI output is untrusted).
    var cleaned: SalesPlan {
        var p = self
        p.reason = StarterKit.clean(reason, 300)
        p.runningCostPerCustomer = PaybackSums.clamp(runningCostPerCustomer, to: PaybackSums.maxRunningCost)
        p.otherYearlyCosts = PaybackSums.clamp(otherYearlyCosts, to: PaybackSums.maxYearlyCosts)
        p.monthlyChurnPercent = PaybackSums.clamp(monthlyChurnPercent, to: PaybackSums.maxChurnPercent)
        return p
    }
}

enum PaybackSums {
    /// No subscription keeps every customer: churn below this is raised to it.
    static let minimumChurnPercent = 2.0
    static let maxChurnPercent = 50.0
    static let maxRunningCost = 1_000.0
    static let maxYearlyCosts = 100_000.0

    /// A finite number from 0 to `limit`; anything else is 0.
    static func clamp(_ value: Double, to limit: Double) -> Double {
        value.isFinite ? min(max(value, 0), limit) : 0
    }

    /// The first year of sales.
    struct Year: Equatable, Sendable {
        /// The build plus a year of fixed costs, paid up front.
        var upfront: Double
        /// Money kept from sales after the store's or card processor's fee.
        var income: Double
        /// What the customers cost to run.
        var runningCosts: Double
        /// Income less running costs less the up-front costs.
        var profit: Double { income - runningCosts - upfront }
        /// The month (1–12) by which the costs are paid back, or `nil` if not within the year.
        var paybackMonth: Int?
        /// What one customer leaves after their running cost: a month of a subscription, or a one-off sale less a
        /// year of running it.
        var marginPerCustomer: Double
    }

    /// The customers the sums count: half the AI's guess, rounded down, but at least 1 if it guessed any.
    static func cautiousCustomers(_ guess: Int) -> Int {
        guess > 0 ? max(guess / 2, 1) : 0
    }

    /// Runs the first year month by month.
    /// - Parameters:
    ///   - monthlyPrice: The price per month; for a one-off sale, the one-off price ÷ 12 (as the AI gives it).
    ///   - customers: The AI's guess of paying customers in the first year; half of it (`cautiousCustomers`) arrive evenly.
    static func firstYear(plan: SalesPlan, monthlyPrice: Double, customers: Int, buildDays: Int, tool: BuilderTool) -> Year {
        let kept = FiveTests.keptShare
        let arrivals = Double(cautiousCustomers(customers)) / 12
        let upfront = FiveTests.buildCost(days: buildDays, tool: tool) + plan.otherYearlyCosts
        let churn = max(plan.monthlyChurnPercent, minimumChurnPercent) / 100
        let running = plan.runningCostPerCustomer
        var year = Year(upfront: upfront, income: 0, runningCosts: 0, paybackMonth: nil,
                        marginPerCustomer: plan.model == .oneOff ? monthlyPrice * 12 * kept - running * 12
                                                                 : monthlyPrice * kept - running)
        var using = 0.0
        for month in 1...12 {
            switch plan.model {
            case .oneOff:
                using += arrivals
                year.income += arrivals * monthlyPrice * 12 * kept
            case .subscription:
                using = using * (1 - churn) + arrivals
                year.income += using * monthlyPrice * kept
            }
            year.runningCosts += using * running
            if year.paybackMonth == nil && year.profit >= 0 { year.paybackMonth = month }
        }
        return year
    }

    /// Test 5 from the first year: paid back within 3 months scores 5, 6 months 4, 12 months 3; not within the year
    /// but each sale makes money 2; losing money on each customer 1. A one-off sale with a running cost can't score
    /// above 2, and a hard-to-reach buyer holds the score back as before.
    static func coversBuild(plan: SalesPlan, monthlyPrice: Double, customers: Int, buildDays: Int, tool: BuilderTool,
                            channelScore: Int) -> TestOutcome {
        let name = "Sales cover the build cost"
        guard customers > 0, monthlyPrice >= FiveTests.minimumPrice else {
            return TestOutcome(name: name, score: 1, reason: "No likely paying customers or price, so nothing pays back the build.")
        }
        let year = firstYear(plan: plan, monthlyPrice: monthlyPrice, customers: customers, buildDays: buildDays, tool: tool)
        let sales = "\(cautiousCustomers(customers)) customers (half the guess of \(customers)) at "
            + priceText(plan.model, monthlyPrice: monthlyPrice)
        guard year.marginPerCustomer > 0 else {
            return TestOutcome(name: name, score: 1, reason: "Loses money on each customer: \(sales), but each costs "
                               + "\(FiveTests.money(plan.runningCostPerCustomer)) a month to run.")
        }
        var score: Int
        var reason = "Costs \(FiveTests.money(year.upfront)) up front; \(sales) make \(FiveTests.money(year.profit)) "
            + "in the first year"
        if let month = year.paybackMonth {
            score = month <= 3 ? 5 : month <= 6 ? 4 : 3
            reason += ", paid back in about \(month) month\(month == 1 ? "" : "s")."
        } else {
            score = 2
            reason += ": not paid back within the year."
        }
        if plan.model == .oneOff && plan.runningCostPerCustomer > 0 && score > 2 {
            score = 2
            reason += " Held back: a one-off sale can't cover a cost that comes every month."
        }
        if channelScore > 0 && channelScore < score {
            score = channelScore
            reason += " Held back: buyers are hard to reach."
        }
        return TestOutcome(name: name, score: score, reason: reason)
    }

    /// "$24 once" or "$3 a month".
    static func priceText(_ model: SalesModel, monthlyPrice: Double) -> String {
        model == .oneOff ? FiveTests.money(monthlyPrice * 12) + " once" : FiveTests.money(monthlyPrice) + " a month"
    }
}
