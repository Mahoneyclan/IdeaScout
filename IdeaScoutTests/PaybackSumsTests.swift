// PaybackSumsTests.swift
// Test 5 from a first year of sales (owner, 12 Nov 2026): one-off versus subscription, running costs, half the
// customer guess (owner, 13 Nov 2026), losing money on each customer, and the AI's sales plan being cleaned and
// carried onto the idea.

import Foundation
import Testing
@testable import IdeaScout

private func plan(_ model: SalesModel, running: Double = 0, yearly: Double = 0, churn: Double = 0) -> SalesPlan {
    SalesPlan(model: model, reason: "r", runningCostPerCustomer: running, otherYearlyCosts: yearly, monthlyChurnPercent: churn)
}

/// An AI reply in Claude's message format, as the parsers expect.
private func reply(_ json: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": json]], "stop_reason": "end_turn"])
}

struct PaybackSumsTests {
    /// 10 days of Claude Code is $20 up front, plus any yearly costs (Apple's fee isn't counted). A guess of 40
    /// customers counts as 20, arriving one every 18 days or so.
    @Test(arguments: [
        (SalesModel.subscription, 9.0, 0.0, 0.0, 40, 5, 5, "paid back in about 2 months"),
        (.subscription, 9.0, 0.0, 40.0, 40, 5, 5, "paid back in about 3 months"),     // last month that scores 5
        (.subscription, 9.0, 0.0, 60.0, 40, 5, 4, "paid back in about 4 months"),
        (.subscription, 9.0, 0.0, 200.0, 40, 5, 4, "paid back in about 6 months"),    // last month that scores 4
        (.subscription, 9.0, 0.0, 240.0, 40, 5, 3, "paid back in about 7 months"),
        (.subscription, 9.0, 0.0, 900.0, 40, 5, 3, "paid back in about 12 months"),   // last month that scores 3
        (.subscription, 9.0, 0.0, 0.0, 40, 4, 4, "hard to reach"),                   // channel holds it back
        (.oneOff, 2.0, 0.0, 0.0, 40, 5, 5, " once make "),                         // $24 one-off sales
        (.oneOff, 2.0, 0.5, 0.0, 40, 5, 2, "a cost that comes every month"),          // one-off can't carry a running cost
        (.subscription, 3.0, 3.0, 0.0, 40, 5, 1, "Loses money on each customer"),      // $2.55 kept, $3 to run
        (.subscription, 3.0, 0.0, 0.0, 3, 5, 2, "not paid back within the year"),      // a guess of 3 counts as 1
        (.subscription, 9.0, 0.0, 0.0, 0, 5, 1, "No likely paying customers"),
    ])
    func firstYearDecidesTheScore(model: SalesModel, price: Double, running: Double, yearly: Double, customers: Int,
                                  channel: Int, score: Int, says: String) {
        let outcome = PaybackSums.coversBuild(plan: plan(model, running: running, yearly: yearly), monthlyPrice: price,
                                              customers: customers, buildDays: 10, tool: .claudeCode, channelScore: channel)
        #expect(outcome.score == score)
        #expect(outcome.reason.contains(says), "\(outcome.reason)")
    }

    @Test(arguments: [(0, 0), (1, 1), (3, 1), (40, 20), (41, 20)])
    func theSumsCountHalfTheCustomerGuess(guess: Int, counted: Int) {
        #expect(PaybackSums.cautiousCustomers(guess) == counted)
    }

    @Test func yearlyCostsAndChurn() {
        let year = PaybackSums.firstYear(plan: plan(.subscription, yearly: 60), monthlyPrice: 10, customers: 24, buildDays: 1,
                                         tool: .claudeCode)
        #expect(year.upfront == 80, "the build and the yearly costs, with no Apple fee")
        // A guess of 24 counts as 12 subscribers a year, one a month, at $10: with churn the year earns less.
        let kept = PaybackSums.firstYear(plan: plan(.subscription), monthlyPrice: 10, customers: 24, buildDays: 1,
                                         tool: .claudeCode)
        let leaving = PaybackSums.firstYear(plan: plan(.subscription, churn: 20), monthlyPrice: 10, customers: 24, buildDays: 1,
                                            tool: .claudeCode)
        #expect(leaving.income < kept.income && kept.income < 78 * 8.5, "zero churn is raised to the 2% minimum")
        let once = PaybackSums.firstYear(plan: plan(.oneOff), monthlyPrice: 2, customers: 24, buildDays: 1,
                                         tool: .claudeCode)
        #expect(abs(once.income - 12 * 24 * 0.85) < 0.001, "each one-off customer pays once")
    }

    @Test func theAIsSalesPlanIsCleanedAndOptional() throws {
        let fields = #""title":"T","survives":true,"objection":"o","competitors":"c","verdict":"v","pain":3,"willing_to_pay":3,"timing":3,"gap":3,"fit":3,"buildability":4,"channel_score":4,"evidence_needed":"","build_days":10,"likely_customers":40,"competitors_found":[],"follow_risk":"f","copy_risk":"c","keep_paying":"k""#
        let withPlan = #"{"reviews":[{"# + fields + #","sales_model":"subscription","sales_model_reason":"AI calls","running_cost_per_customer_usd":-1,"other_yearly_costs_usd":1e300,"monthly_churn_percent":500}]}"#
        let p = try #require(try KillerEngine.parseReviews(try reply(withPlan)).first?.salesPlan)
        #expect(p.runningCostPerCustomer == 0 && p.otherYearlyCosts == PaybackSums.maxYearlyCosts
                && p.monthlyChurnPercent == PaybackSums.maxChurnPercent)
        let older = #"{"reviews":[{"# + fields + "}]}"
        #expect(try KillerEngine.parseReviews(try reply(older)).first?.salesPlan == nil)
        let odd = #"{"reviews":[{"# + fields + #","sales_model":"lifetime"}]}"#
        #expect(try KillerEngine.parseReviews(try reply(odd)).first?.salesPlan == nil, "an unknown model is ignored")
    }

    @Test func theCriticsPlanWinsAndTheGeneratorsModelIsTheFallback() {
        var candidate = KillerEngine.Candidate(title: "T", pitch: "", buyer: "", pricing: "", whyNow: "", oneWeekTest: "",
                                               evidenceNumbers: [], sameAs: "")
        candidate.salesModel = .oneOff
        var review = KillerEngine.Review(title: "T", survives: true, objection: "", competitors: "", verdict: "", pain: 3,
                                         willingToPay: 3, timing: 3, gap: 3, fit: 3, buildability: 4, channelScore: 4)
        #expect(KillerEngine.Result(candidate: candidate, review: review).salesPlan?.model == .oneOff)
        review.salesPlan = plan(.subscription, running: 1)
        #expect(KillerEngine.Result(candidate: candidate, review: review).salesPlan?.model == .subscription)
    }

    /// An idea saved with a plan uses the first-year sums; one saved before keeps the older payback until it returns.
    @Test func savedIdeasUseTheirPlanOrKeepTheOlderSums() {
        let idea = KillerIdea(key: "k", title: "T")
        idea.engineVersion = 1; idea.monthlyPrice = 2; idea.likelyCustomers = 40; idea.buildDays = 10; idea.channelScore = 5
        #expect(idea.principles.last?.reason.hasPrefix("Build about") == true)
        idea.salesPlan = plan(.oneOff); idea.appTypeRaw = BuilderTool.AppType.onDevice.rawValue
        #expect(idea.principles.last?.reason.hasPrefix("Costs \(FiveTests.money(20))") == true, "no Apple fee")
        #expect(idea.priceText == FiveTests.money(24) + " once")
        #expect(IdeaVersion(idea).offer?.salesPlan == idea.salesPlan, "kept through Improve this idea")
    }
}
