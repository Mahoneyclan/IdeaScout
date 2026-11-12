// FiveTestsTests.swift
// The five principles (owner, 11 Nov 2026): the price comparison and payback sums done in code, the parsing of
// competitors and prices from the AI, the ideas' stored principles and ranking, and older saved data still reading.

import Foundation
import Testing
import SwiftData
@testable import IdeaScout

private func paidApp(_ price: Double) -> Competitor { Competitor(name: "Incumbent", plan: "", monthlyPrice: price) }

struct FiveTestsTests {
    private func competitor(_ price: Double, confirmed: Bool = false) -> Competitor {
        Competitor(name: "Incumbent", plan: "Starter", monthlyPrice: price, confirmed: confirmed)
    }

    /// Half the cheapest competitor's price or less scores 3+; dearer scores lower but is never a drop. Exact
    /// boundaries: a quarter (5), 40% (4), half (3), three-quarters (2). An unconfirmed price tops out at 4.
    @Test(arguments: [(10.0, true, 5), (10.0, false, 4), (16.0, true, 4), (20.0, true, 3), (20.1, true, 2),
                      (30.0, true, 2), (30.1, true, 1), (39.0, false, 1)])
    func priceComparedWithTheCheapestCompetitor(price: Double, confirmed: Bool, score: Int) {
        let outcome = FiveTests.cheaper(price: price, competitors: [competitor(80), competitor(40, confirmed: confirmed)],
                                        fillsGap: false)
        #expect(outcome.score == score)
        #expect(outcome.known)
    }

    @Test func freeCompetitorOrNoPriceIsNotATick() {
        var free = competitor(0)
        free.isFree = true
        #expect(FiveTests.cheaper(price: 2, competitors: [competitor(40), free], fillsGap: false).score == 1)
        let unknown = FiveTests.cheaper(price: 2, competitors: [competitor(0)], fillsGap: false)
        #expect(!unknown.known && !unknown.passed, "no price found is unknown, not met")
        #expect(FiveTests.cheaper(price: 2, competitors: [], fillsGap: true).passed, "a gap is fine")
    }

    /// A tiny or broken price from the AI must never crash the sums (they run on every leaderboard sort).
    @Test func tinyPricesAreTreatedAsUnknown() {
        #expect(KillerEngine.cleanPrice(1e-300) == 0 && KillerEngine.cleanPrice(.nan) == 0 && KillerEngine.cleanPrice(-1) == 0)
        #expect(FiveTests.cheaper(price: 2, competitors: [competitor(1e-300)], fillsGap: false).known == false)
        #expect(FiveTests.paybackMonths(buildCost: 20, customers: 1, price: 1e-18) == nil)
        let slow = FiveTests.paybackMonths(buildCost: 1e9, customers: 1, price: 0.01)
        #expect(slow == FiveTests.maxPaybackMonths)
        #expect(FiveTests.monthsText(FiveTests.maxPaybackMonths).hasPrefix("more than"))
        #expect(FiveTests.cheaper(price: 1e6, competitors: [competitor(0.01)], fillsGap: false).score == 1)
    }

    @Test func gapOrUnpricedCompetitorIsNeutral() {
        #expect(FiveTests.cheaper(price: 5, competitors: [], fillsGap: true).score == 3)
        #expect(FiveTests.cheaper(price: 5, competitors: [competitor(0)], fillsGap: false).reason.contains("No competitor price"))
        #expect(FiveTests.cheaper(price: 0, competitors: [competitor(40)], fillsGap: false).score == 1)
    }

    @Test func buildCostAndPayback() {
        #expect(FiveTests.buildCost(days: 10, tool: .claudeCode) == 20)
        #expect(FiveTests.buildCost(days: 45, tool: .lovable) == 50, "a started month counts")
        #expect(FiveTests.buildCost(days: 0, tool: .cursor) == 20, "at least one month")
        let months = FiveTests.paybackMonths(buildCost: 20, customers: 10, price: 2)
        #expect(abs((months ?? 0) - 20 / 17) < 0.001, "10 customers × $2 × 85% kept = $17 a month")
        #expect(FiveTests.paybackMonths(buildCost: 20, customers: 0, price: 2) == nil)
    }

    @Test(arguments: [(40, 9.0, 5, 5), (40, 9.0, 2, 2), (1, 1.0, 5, 2), (0, 9.0, 5, 1)])
    func salesCoverTheBuildHeldBackByAWeakChannel(customers: Int, price: Double, channel: Int, score: Int) {
        let outcome = FiveTests.coversBuild(buildDays: 10, customers: customers, price: price, tool: .claudeCode, channelScore: channel)
        #expect(outcome.score == score)
    }

    @Test func competitorsAndPricesFromTheAIAreCleaned() throws {
        let json = #"{"ideas":[{"title":"T","pitch":"p","buyer":"b","pricing":"$3 a month","why_now":"w","one_week_test":"t","replaces":"r","channel":"c","evidence_numbers":[1],"same_as":"","one_job":"j","keep_features":["a","  ","b"],"leave_out_features":["x"],"competitors":[{"name":"Big https://evil.example","cheapest_plan":"Solo","price_per_month_usd":40},{"name":"Odd","cheapest_plan":"","price_per_month_usd":-5},{"name":" ","cheapest_plan":"","price_per_month_usd":1},{"name":"C","cheapest_plan":"","price_per_month_usd":1},{"name":"D","cheapest_plan":"","price_per_month_usd":1}],"fills_gap":false,"price_per_month_usd":1e12}]}"#
        let data = try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": json]], "stop_reason": "end_turn"])
        let c = try #require(try KillerEngine.parseCandidates(data).first)
        #expect(c.competitors.map(\.name) == ["Big", "Odd", "C"], "links removed, blanks dropped, at most 3")
        #expect(c.competitors[1].monthlyPrice == 0, "a negative price is unknown")
        #expect(c.monthlyPrice == 0, "an impossible price is unknown")
        #expect(c.keepFeatures == ["a", "b"] && c.oneJob == "j")
    }

    /// Prompts and schemas move together: every field the schemas require is described in the instructions.
    @Test func schemasAndInstructionsAgree() throws {
        func required(_ schema: [String: Any], list: String) throws -> [String] {
            let items = try #require(((schema["properties"] as? [String: Any])?[list] as? [String: Any])?["items"] as? [String: Any])
            return try #require(items["required"] as? [String])
        }
        let added = ["one_job", "keep_features", "leave_out_features", "fills_gap", "price_per_month_usd"]
        let ideaFields = try required(KillerEngine.candidateSchema, list: "ideas")
        for field in added + ["competitors"] {
            #expect(ideaFields.contains(field))
            #expect(KillerEngine.generateInstructions.contains(field + " ") || KillerEngine.generateInstructions.contains(field + " ("),
                    "instructions should describe \(field)")
        }
        let reviewFields = try required(KillerEngine.reviewSchema, list: "reviews")
        for field in ["competitors_found", "build_days", "likely_customers", "follow_risk", "copy_risk", "keep_paying"] {
            #expect(reviewFields.contains(field) && KillerEngine.critiqueInstructions.contains(field))
        }
        #expect(KillerEngine.competitorSchema["required"] as? [String] == ["name", "cheapest_plan", "price_per_month_usd", "is_free"])
        for field in IdeaImprover.rewriteFields { #expect(IdeaImprover.rewriteInstructions.contains(field)) }
    }

    @Test func reviewEstimatesAreClamped() throws {
        let json = #"{"reviews":[{"title":"T","survives":true,"objection":"o","competitors":"c","verdict":"v","pain":9,"willing_to_pay":3,"timing":3,"gap":3,"fit":3,"buildability":4,"channel_score":4,"evidence_needed":"","build_days":-4,"likely_customers":99999999,"competitors_found":[],"follow_risk":"f","copy_risk":"c","keep_paying":"k"}]}"#
        let data = try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": json]], "stop_reason": "end_turn"])
        let r = try #require(try KillerEngine.parseReviews(data).first)
        #expect(r.pain == 5 && r.buildDays == 0 && r.likelyCustomers == KillerEngine.maxLikelyCustomers)
    }

    /// The critic decides who competes, but keeps a price only the generator knew; a gap idea can have none.
    @Test func competitorListsAreMerged() {
        let generator = [Competitor(name: "Jobber", plan: "Core", monthlyPrice: 69)]
        let critic = [Competitor(name: "jobber", plan: "", monthlyPrice: 0), Competitor(name: "Other", plan: "", monthlyPrice: 20)]
        let merged = KillerEngine.mergedCompetitors(critic: critic, generator: generator, fillsGap: false)
        #expect(merged.map(\.monthlyPrice) == [69, 20])
        #expect(KillerEngine.mergedCompetitors(critic: [], generator: generator, fillsGap: false) == generator)
        #expect(KillerEngine.mergedCompetitors(critic: [], generator: generator, fillsGap: true).isEmpty)
    }

    @Test func newIdeasAreJudgedOnThePrinciplesAndRankFirst() {
        let older = KillerIdea(key: "old", title: "Old")
        older.pain = 5; older.willingToPay = 5; older.timing = 5; older.gap = 5; older.fit = 5
        let new = KillerIdea(key: "new", title: "New")
        new.engineVersion = 1
        new.pain = 3; new.willingToPay = 3; new.buildability = 4; new.channelScore = 4
        new.monthlyPrice = 9; new.competitorList = [competitor(40)]; new.buildDays = 10; new.likelyCustomers = 40
        #expect(new.principles.map(\.name) == ["Vibe-codable", "People will pay", "Real pain", "Materially cheaper",
                                              "Sales cover the build cost"])
        // 4 + 3 + 3 + 4 (78% cheaper, unconfirmed) + 4 (pays back in 1 month, held back by the channel score of 4) = 18 / 5
        #expect(abs(new.killerScore - 3.6) < 0.0001)
        #expect(older.principles.isEmpty && older.killerScore == 5)
        #expect(KillerIdea.ranksAbove(new, older), "older ideas rank below new ones")
        let better = KillerIdea(key: "b", title: "B")
        better.engineVersion = 1; better.pain = 5; better.willingToPay = 5; better.buildability = 5
        better.monthlyPrice = 9; better.competitorList = [competitor(40)]
        #expect(KillerIdea.ranksAbove(better, new) && !KillerIdea.ranksAbove(new, better), "same version: higher score first")
        better.criticRejected = true
        #expect(KillerIdea.ranksAbove(new, better) && !KillerIdea.ranksAbove(better, new),
                "an idea the devil's advocate rejected ranks below one it backed, whatever the score")
        #expect(KillerIdea.ranksAbove(better, older), "but still above older ideas")
    }

    /// Only "not vibe-codable" stops a version being kept; the devil's advocate's rejection carries over to the idea.
    @Test func rejectedVersionCanBeKeptAndStaysMarked() {
        let idea = KillerIdea(key: "a", title: "A")
        idea.engineVersion = 1; idea.buildability = 4; idea.criticRejected = true
        var version = IdeaVersion(idea)
        #expect(!version.survives && version.passes)
        version.buildability = 2
        #expect(!version.passes, "not vibe-codable can't be kept")
        version.buildability = 4; version.survives = true
        version.apply(to: idea)
        #expect(!idea.criticRejected)
        let rejected = version.reviewed(by: KillerEngine.Review(title: "A", survives: false, objection: "o", competitors: "c",
            verdict: "v", pain: 3, willingToPay: 3, timing: 3, gap: 3, fit: 3, buildability: 4, channelScore: 3))
        #expect(IdeaImprover.stop(after: rejected, best: 0, original: 0, round: 1, bar: 5) == .rejected,
                "a run still stops when the devil's advocate rejects a rewrite")
    }

    /// "People will pay" needs proof (owner, 12 Nov 2026): a paid competitor or posts about paying; otherwise unproven.
    @Test(arguments: [([paidApp(40)], 0, 2, 3, true, "People already pay Incumbent "),
                      ([paidApp(40), paidApp(25)], 0, 5, 5, true, " a month, and 1 other app charge too."),
                      ([Competitor(name: "Free", plan: "", monthlyPrice: 0, isFree: true)], 0, 4, 2, false, "No proof"),
                      ([], 1, 4, 4, true, "Posts show"),
                      ([], 0, 5, 2, false, "No proof")] as [([Competitor], Int, Int, Int, Bool, String)])
    func willPayNeedsProof(competitors: [Competitor], posts: Int, aiScore: Int, score: Int, known: Bool, phrase: String) {
        let outcome = FiveTests.willPay(score: aiScore, competitors: competitors, payEvidence: posts)
        #expect(outcome.score == score && outcome.known == known && outcome.passed == known)
        #expect(outcome.reason.contains(phrase))
    }

    @Test func ideaKindSaysWhetherItUndercutsOrFillsAGap() {
        #expect(IdeaKindTag.kind(competitors: [competitor(40)], fillsGap: false) == .undercuts("Undercuts Incumbent (\(FiveTests.money(40))/mo)"))
        #expect(IdeaKindTag.kind(competitors: [competitor(40), competitor(25)], fillsGap: false)
                == .undercuts("Undercuts 2 competitors (from \(FiveTests.money(25))/mo)"))
        #expect(IdeaKindTag.kind(competitors: [competitor(0)], fillsGap: false) == .competes("Competes with Incumbent"))
        #expect(IdeaKindTag.kind(competitors: [], fillsGap: true) == .fillsGap)
        #expect(IdeaKindTag.kind(competitors: [], fillsGap: false) == .noneNamed)
    }

    @Test func payEvidenceCountsDifferentPayingSources() {
        func item(_ key: String, _ source: SourceKind) -> FetchedItem {
            FetchedItem(key: key, source: source, title: key, detail: "", url: URL(string: "https://example.com/\(key)")!,
                        score: 1, postedAt: .now)
        }
        let review = item("a", .appReviews), other = item("b", .devTo)
        #expect(KillerEngine.payEvidenceCount([review, review, other]) == 1, "the same item once; a non-paying source not at all")
    }

    /// Stored data is permanent: an improvement run saved before the principles still reads, as an older version.
    @Test func improvementSavedBeforeThePrinciplesStillReads() throws {
        let json = #"{"versions":[{"pitch":"p","buyer":"b","pricing":"$1","whyNow":"w","oneWeekTest":"t","replaces":"","channel":"","changes":"","survives":true,"objection":"o","competitors":"c","verdict":"v","evidenceNeeded":"","pain":3,"willingToPay":3,"timing":3,"gap":3,"fit":3,"buildability":3,"channelScore":3}],"madeAt":0,"model":""}"#
        let run = try JSONDecoder().decode(IdeaImprover.Run.self, from: Data(json.utf8))
        #expect(run.versions.first?.offer == nil && run.versions.first?.principles.isEmpty == true)
    }

    @Test func improvementKeepsThePrinciplesFields() {
        let idea = KillerIdea(key: "a", title: "A")
        idea.engineVersion = 1; idea.monthlyPrice = 9; idea.competitorList = [competitor(40)]; idea.buildability = 4
        let version = IdeaVersion(idea)
        #expect(version.offer?.monthlyPrice == 9 && version.principles.count == 5)
        let copy = KillerIdea(key: "b", title: "B")
        copy.engineVersion = 1
        version.apply(to: copy)
        #expect(copy.competitorList == idea.competitorList && copy.monthlyPrice == 9)
    }
}

/// A returning idea is rewritten by the scan onto the five principles, and loses anything scored on the old text.
@MainActor
struct FiveTestsMergeTests {
    @Test func returningOlderIdeaGetsThePrinciplesAndDropsStaleRuns() throws {
        let container = try ModelContainer(for: Digest.self, Theme.self, Item.self, Idea.self, KillerIdea.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let service = DigestService(dependencies: .init(
            makeFetchers: { [] }, makeSummarizer: { KeywordSummarizer(topics: []) },
            freeSummarizer: { KeywordSummarizer(topics: []) }, access: { .unlocked }, isOverDailyCap: { false },
            needsConsent: { false }, notify: { _, _ in }))
        let older = KillerIdea(key: "invoicechaser", title: "InvoiceChaser")
        older.improvementJSON = "{}"; older.originalVersionJSON = "{}"; older.improvedAt = .now
        container.mainContext.insert(older)
        let candidate = KillerEngine.Candidate(title: "InvoiceChaser", pitch: "p", buyer: "b", pricing: "$9 a month", whyNow: "w",
                                               oneWeekTest: "t", evidenceNumbers: [], sameAs: "", oneJob: "Chase invoices",
                                               keepFeatures: ["Reminders"], monthlyPrice: 9,
                                               competitors: [Competitor(name: "Chaser", plan: "Starter", monthlyPrice: 40)])
        let review = KillerEngine.Review(title: "InvoiceChaser", survives: true, objection: "o", competitors: "c", verdict: "v",
                                         pain: 3, willingToPay: 3, timing: 3, gap: 3, fit: 3, buildability: 4, channelScore: 4,
                                         buildDays: 10, likelyCustomers: 40, followRisk: "f", copyRisk: "c", keepPaying: "k")
        service.mergeKillerIdeas([KillerEngine.Result(candidate: candidate, review: review, tool: .lovable)], items: [],
                                 context: container.mainContext)
        #expect(older.engineVersion == 1 && older.oneJob == "Chase invoices" && older.monthlyPrice == 9)
        #expect(older.competitorList.first?.monthlyPrice == 40 && older.buildDays == 10 && older.likelyCustomers == 40)
        #expect(older.builderTool == .lovable && older.keepPaying == "k")
        #expect(older.improvementJSON.isEmpty && older.originalVersionJSON.isEmpty && older.improvedAt == nil)
    }
}
