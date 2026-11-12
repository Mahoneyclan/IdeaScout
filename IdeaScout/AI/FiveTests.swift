// FiveTests.swift
// The owner's five tests for a killer idea (decided 11 Nov 2026), worked out in code from the devil's advocate's
// scores and the idea's prices: 1 vibe-codable, 2 people will pay, 3 real pain, 4 materially cheaper, 5 sales cover
// the build cost. They're principles that score and rank ideas; only "vibe-codable" is a must (owner, 11 Nov 2026).
// The price comparison and the payback sums are done here, not by the AI. See CLAUDE.md.

import Foundation

/// A competing product and its cheapest comparable plan, per month in US dollars.
struct Competitor: Codable, Equatable, Sendable {
    var name: String
    /// The plan compared, e.g. "Starter, per user".
    var plan: String
    /// Price per month; a one-off price counts as 12 months of use, and 0 means free or unknown.
    var monthlyPrice: Double
    /// Where the price was found (web research only); empty when it came from the AI's memory.
    var url = ""
    /// Whether the price was checked on the web, rather than recalled by the AI.
    var confirmed = false
    /// The product is free to use (0 then means free, not unknown).
    var isFree = false
}

extension Competitor {
    /// Tolerant decoding: keys added later may be missing from data saved earlier (stored data is permanent).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        plan = try c.decodeIfPresent(String.self, forKey: .plan) ?? ""
        monthlyPrice = try c.decodeIfPresent(Double.self, forKey: .monthlyPrice) ?? 0
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
        isFree = try c.decodeIfPresent(Bool.self, forKey: .isFree) ?? false
    }
}

/// One test's outcome for the screen.
struct TestOutcome: Equatable, Sendable {
    var name: String
    var score: Int
    var reason: String
    /// `false` when there isn't enough to judge (for example no competitor price): shown as unknown, not met.
    var known = true
    /// Met means known and a score of at least 3 (the middle of the 1–5 scale).
    var passed: Bool { known && score >= 3 }
}

enum FiveTests {
    /// The recommended price should be at most this share of the cheapest competitor's (owner, 11 Nov 2026).
    static let maxPriceShare = 0.5
    /// Below this, an idea isn't vibe-codable and is always dropped: the one test that's a must.
    static let minimumVibeCodable = 3
    /// Without a confirmed (web-checked) competitor price, "materially cheaper" can't score above this.
    static let unconfirmedPriceCap = 4
    /// Share of each sale kept after the app store's or card processor's fee (Apple's small-business rate is 15%).
    static let keptShare = 0.85
    /// Prices below this are treated as unknown, so the sums stay sensible whatever the AI writes.
    static let minimumPrice = 0.01
    /// Longest payback shown, in months; anything longer is "more than" this.
    static let maxPaybackMonths = 999.0

    /// A month of the tool's usual paid plan, in US dollars, for the build-cost estimate. From third-party price
    /// summaries checked 11 Nov 2026 (Claude Pro $20, Cursor Pro $20, Replit Core $20, Lovable Pro $25); check the
    /// tools' own pricing pages before relying on them.
    static func toolMonthlyCost(_ tool: BuilderTool) -> Double {
        switch tool {
        case .claudeCode, .cursor, .replit: 20
        case .lovable: 25
        }
    }

    /// The cheapest competitor with a known price.
    static func cheapest(_ competitors: [Competitor]) -> Competitor? {
        competitors.filter { $0.monthlyPrice >= minimumPrice }.min { $0.monthlyPrice < $1.monthlyPrice }
    }

    /// Test 4: at most half the cheapest competitor's price scores 3 or more; dearer scores lower but isn't dropped.
    /// A gap idea, or one with no priced competitor, scores 3.
    static func cheaper(price: Double, competitors: [Competitor], fillsGap: Bool) -> TestOutcome {
        let name = "Materially cheaper"
        if let free = competitors.first(where: \.isFree) {
            return TestOutcome(name: name, score: 1, reason: "\(free.name) already does this for free.")
        }
        guard let cheapest = cheapest(competitors) else {
            if fillsGap { return TestOutcome(name: name, score: 3, reason: "No direct competitor: it fills a gap.") }
            return TestOutcome(name: name, score: 3, reason: "No competitor price found, so this can't be judged yet.", known: false)
        }
        guard price >= minimumPrice else { return TestOutcome(name: name, score: 1, reason: "No price was given.") }
        let share = min(price / cheapest.monthlyPrice, 100)
        let percent = Int(((1 - share) * 100).rounded(.down))
        let compared = "\(money(price))/mo against \(cheapest.name) at \(money(cheapest.monthlyPrice))/mo"
        guard share <= maxPriceShare else {
            let score = share <= 0.75 ? 2 : 1
            let reason = percent > 0 ? "Only \(percent)% cheaper: \(compared)." : "Not cheaper: \(compared)."
            return TestOutcome(name: name, score: score, reason: reason)
        }
        var score = share <= 0.25 ? 5 : share <= 0.4 ? 4 : 3
        var reason = "\(percent)% cheaper: \(compared)."
        if !cheapest.confirmed {
            score = min(score, unconfirmedPriceCap)
            reason += " Competitor price unconfirmed."
        }
        return TestOutcome(name: name, score: score, reason: reason)
    }

    /// The build cost: the tool's plan for each started month of building (at least one).
    static func buildCost(days: Int, tool: BuilderTool) -> Double {
        Double(max(1, Int((Double(max(days, 1)) / 30).rounded(.up)))) * toolMonthlyCost(tool)
    }

    /// Months for the likely customers' payments (after fees) to recover the build cost, at most `maxPaybackMonths`;
    /// `nil` if nothing comes in.
    static func paybackMonths(buildCost: Double, customers: Int, price: Double) -> Double? {
        let monthly = Double(customers) * price * keptShare
        guard customers > 0, price >= minimumPrice, monthly.isFinite, monthly > 0 else { return nil }
        return min(buildCost / monthly, maxPaybackMonths)
    }

    /// "about 3 months", or "more than 999 months" at the cap.
    static func monthsText(_ months: Double) -> String {
        if months >= maxPaybackMonths { return "more than \(Int(maxPaybackMonths)) months" }
        let whole = max(1, Int(months.rounded(.up)))
        return "about \(whole) month\(whole == 1 ? "" : "s")"
    }

    /// Test 5: the likely sales recover the build cost. Capped by the sales-channel score, because the customers have
    /// to be found in a named place where they already look.
    static func coversBuild(buildDays: Int, customers: Int, price: Double, tool: BuilderTool, channelScore: Int) -> TestOutcome {
        let name = "Sales cover the build cost"
        let cost = buildCost(days: buildDays, tool: tool)
        guard let months = paybackMonths(buildCost: cost, customers: customers, price: price) else {
            return TestOutcome(name: name, score: 1, reason: "No likely paying customers or price, so nothing pays back the build.")
        }
        var score = months <= 3 ? 5 : months <= 6 ? 4 : months <= 12 ? 3 : months <= 24 ? 2 : 1
        let days = buildDays > 0 ? "Build about \(buildDays) day\(buildDays == 1 ? "" : "s")" : "Build time not estimated"
        var reason = "\(days) (\(money(cost))); \(customers) customers at \(money(price))/mo pay it back in "
            + monthsText(months) + "."
        if channelScore > 0 && channelScore < score {
            score = channelScore
            reason += " Held back: buyers are hard to reach."
        }
        return TestOutcome(name: name, score: score, reason: reason)
    }

    /// Without proof that people pay, "people will pay" can't score above this (owner, 12 Nov 2026).
    static let unprovenPayCap = 2

    /// The competitors people pay for: not free, with a known price; cheapest first.
    static func paid(_ competitors: [Competitor]) -> [Competitor] {
        competitors.filter { !$0.isFree && $0.monthlyPrice >= minimumPrice }.sorted { $0.monthlyPrice < $1.monthlyPrice }
    }

    /// Test 2: people will pay. Passes only with proof (owner, 12 Nov 2026): a competitor people already pay for, or
    /// cited posts showing people pay for this or a workaround. Without proof it's "unproven" and capped, however
    /// sure the AI sounds.
    /// - Parameters:
    ///   - score: The devil's advocate's score, already capped by the evidence.
    ///   - competitors: The idea's competitors.
    ///   - payEvidence: How many cited items are from sources that show people paying.
    static func willPay(score: Int, competitors: [Competitor], payEvidence: Int) -> TestOutcome {
        let name = "People will pay"
        if let cheapest = paid(competitors).first {
            let others = paid(competitors).count - 1
            return TestOutcome(name: name, score: max(score, 3),
                               reason: "People already pay \(cheapest.name) \(money(cheapest.monthlyPrice)) a month"
                                + (others > 0 ? ", and \(others) other app\(others == 1 ? "" : "s") charge too." : "."))
        }
        if payEvidence > 0 {
            return TestOutcome(name: name, score: score,
                               reason: score >= 4 ? "Posts show people pay for this or a workaround." : "Some posts hint that people pay for this.")
        }
        return TestOutcome(name: name, score: min(score, unprovenPayCap),
                           reason: "No proof anyone pays for this yet: no paid competitor and no posts about paying.", known: false)
    }

    /// All five outcomes, in the owner's order.
    static func outcomes(vibeCodable: Int, willPay: TestOutcome, pain: Int, cheaper: TestOutcome, coversBuild: TestOutcome) -> [TestOutcome] {
        [TestOutcome(name: "Vibe-codable", score: vibeCodable,
                     reason: vibeCodable >= minimumVibeCodable ? "One person can build it with their AI coding tool." : "Too hard to build alone with the tool."),
         willPay,
         TestOutcome(name: "Real pain", score: pain,
                     reason: pain >= 4 ? "People complain about this." : pain == 3 ? "Some signs, not proven by the evidence."
                        : "Weak evidence of pain."),
         cheaper, coversBuild]
    }

    /// The killer score: the average of the five test scores.
    static func score(_ outcomes: [TestOutcome]) -> Double {
        outcomes.isEmpty ? 0 : Double(outcomes.map(\.score).reduce(0, +)) / Double(outcomes.count)
    }

    /// Whole dollars when it's a round number, otherwise cents.
    static func money(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value.rounded() == value ? 0 : 2)))
    }
}
