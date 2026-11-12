// KillerEngine.swift
// The idea step of a refresh: two cloud AI calls. Pass 1 proposes 5 money-making ideas from the pain clusters,
// trends and items; pass 2 plays devil's advocate and scores them. Code then applies the evidence caps and the
// owner's five principles (FiveTests.swift) and keeps up to 3, which DigestService saves as KillerIdeas. Only
// "vibe-codable" is a must; the other principles score and rank. Prompts, schemas and parsers are in
// KillerEngine+Prompts.swift.

import Foundation

/// Turns the trends and pain clusters into money-making product ideas, then has a second,
/// sceptical pass try to kill them. Up to 3 survivors a day are kept. Needs a cloud AI:
/// Apple's on-device model is too small for this kind of reasoning.
struct KillerEngine {
    /// The cloud AI to use (only its client is needed).
    let llm: LLMSummarizer
    /// Called when the devil's-advocate step starts (for progress on screen).
    var onCritique: @Sendable () async -> Void = {}

    /// One idea from pass 1, as the AI described it.
    struct Candidate: Equatable, Sendable {
        /// Short, memorable name. Also the key that matches it to its review and to past ideas.
        var title: String
        /// One-sentence pitch.
        var pitch: String
        /// Who pays: a specific role in a type of business, or a specific type of consumer.
        var buyer: String
        /// Pricing model and price per customer per month.
        var pricing: String
        /// What recently made it possible.
        var whyNow: String
        /// The cheapest way to check demand in seven days, with a pass mark.
        var oneWeekTest: String
        /// 1-based numbers of the items cited as evidence.
        var evidenceNumbers: [Int]
        /// The exact title of an existing leaderboard idea this repeats, or "" if new.
        var sameAs: String
        /// The manual task or costly workaround it replaces.
        var replaces = ""
        /// Where a solo builder would find buyers: a named marketplace, community or search phrase.
        var channel = ""
        /// The one job the app does.
        var oneJob = ""
        /// Features to keep, compared with the competitors.
        var keepFeatures: [String] = []
        /// Features to leave out, compared with the competitors.
        var leaveOutFeatures: [String] = []
        /// The recommended price per customer per month in US dollars (a one-off price ÷ 12).
        var monthlyPrice: Double = 0
        /// No app does this job yet.
        var fillsGap = false
        /// The competitors the generator believes exist, with their cheapest comparable plan.
        var competitors: [Competitor] = []
        /// Sold once or by subscription, as the generator proposed; `nil` in replies from older prompts.
        var salesModel: SalesModel?
        /// Why that way of selling suits it.
        var salesModelReason = ""
    }

    /// The devil's advocate's verdict on one candidate. Scores are clamped to 0–5 when parsed.
    struct Review: Equatable, Sendable {
        /// The candidate's title as copied by the critic; matched to the candidate with `KillerIdea.key(for:)`.
        var title: String
        /// Whether it's still worth a one-week test after the objections.
        var survives: Bool
        /// The single strongest objection.
        var objection: String
        /// Main competitors named by the critic, or "none found".
        var competitors: String
        /// One-sentence verdict.
        var verdict: String
        /// How badly the buyer needs it (1–5). Capped at `unprovenCap` without pain evidence.
        var pain: Int
        /// Signs that buyers spend money here (1–5). Capped at `unprovenCap` without pay evidence.
        var willingToPay: Int
        /// Why now: how recently it became possible or required (1–5).
        var timing: Int
        /// Room for a differentiated product (1–5).
        var gap: Int
        /// Fit with the user's experience and access, from About me (1–5).
        var fit: Int
        /// Whether one person could build all of it with their AI coding tool (1–5).
        var buildability: Int
        /// How reachable the buyers are without a sales team, through the named channel (1–5).
        var channelScore: Int
        /// The one fact that would most raise the score.
        var evidenceNeeded = ""
        /// Days one person would take to build a first version people pay for, with their tool.
        var buildDays = 0
        /// Paying customers likely in the first year from the named channel, assuming a small user base.
        var likelyCustomers = 0
        /// The competitors and prices the critic found (replace the generator's when given).
        var competitorsFound: [Competitor] = []
        /// Would the competitors follow with a cheaper or simpler version?
        var followRisk = ""
        /// What stops another vibe coder copying it?
        var copyRisk = ""
        /// Will customers keep paying, or leave after one use or for the next cheaper app?
        var keepPaying = ""
        /// How it should be sold and what it costs to run, as the critic judged; `nil` in replies from older prompts.
        var salesPlan: SalesPlan?
    }

    /// A kept idea with its (evidence-capped) review, judged on the five principles.
    struct Result: Equatable, Sendable {
        /// The idea as proposed in pass 1.
        var candidate: Candidate
        /// The pass 2 review, after evidence caps.
        var review: Review
        /// The builder's tool, for the build cost.
        var tool = BuilderTool.claudeCode
        /// How many of the cited items show people paying (proof for "people will pay").
        var payEvidence = 0
        /// The kind of app, for its yearly costs.
        var appType = BuilderTool.AppType.onDevice
        /// The critic's sales plan, or the generator's choice of sales model with no costs if the critic gave none.
        var salesPlan: SalesPlan? {
            review.salesPlan ?? candidate.salesModel.map { SalesPlan(model: $0, reason: candidate.salesModelReason) }
        }
        /// The critic's competitors, with a known price from the generator where the critic had none; the generator's
        /// when the critic named none (unless the idea fills a gap, when none is right).
        var competitors: [Competitor] { KillerEngine.mergedCompetitors(critic: review.competitorsFound, generator: candidate.competitors,
                                                                        fillsGap: candidate.fillsGap) }
        /// The five principles, in the owner's order.
        var outcomes: [TestOutcome] {
            KillerEngine.outcomes(review: review, price: candidate.monthlyPrice, competitors: competitors,
                                  fillsGap: candidate.fillsGap, tool: tool, payEvidence: payEvidence,
                                  salesPlan: salesPlan)
        }
        /// The killer score: the average of the five principles.
        var score: Double { FiveTests.score(outcomes) }
    }

    /// Context passed in from the digest: the trends found, the numbered items, the user's profile
    /// and the current leaderboard (so a returning idea reuses its title).
    struct Context: Sendable {
        /// Trends and pain clusters from the trend step.
        var themes: [ThemeBuilder.Built]
        /// The items in prompt order, so evidence numbers can be resolved.
        var items: [FetchedItem]
        /// The user's profile, used for the "fit" score.
        var aboutMe: String
        /// Top existing ideas as "Title: pitch", so a returning idea reuses its title.
        var leaderboard: [String]
        /// The area every idea must be in; empty means any area.
        var interestArea = ""
        /// The user's coding tool.
        var tool = BuilderTool.claudeCode
        /// The kind of app every idea must be; `nil` uses the tool's default.
        var appType: BuilderTool.AppType?
        /// Pain clusters as one-line summaries for the prompt.
        var painClusters: [String] = []
    }

    /// Every vibe-codable idea is kept (up to 3 a day); ones the devil's advocate rejected rank last. Whether it counts as a
    /// "killer" or a "near-miss" is decided on screen from the quality bar, so near-misses can come back and climb.
    /// - Parameter context: Trends, numbered items, profile and leaderboard from the trend step.
    /// - Returns: Up to `maxPerDay` ideas, best first; empty if pass 1 proposed nothing.
    /// - Throws: Errors from either AI call or the parsers.
    /// - Note: `onCritique` is called between the two passes. Two paid calls are made unless pass 1 returns nothing.
    func run(_ context: Context) async throws -> [Result] {
        let candidates = try await generate(context)
        guard !candidates.isEmpty else { return [] }
        await onCritique()
        let reviews = try await critique(candidates, items: context.items, aboutMe: context.aboutMe, tool: context.tool,
                                       appType: context.appType)
        return Self.survivors(candidates: candidates, reviews: reviews, items: context.items, tool: context.tool,
                              appType: context.appType ?? context.tool.defaultAppType)
    }

    /// Ideas scored before the five principles: no single measure may be this low (still used for older ideas).
    static let minimumSingleScore = 2
    /// At most this many ideas are kept per refresh, so the leaderboard isn't flooded.
    static let maxPerDay = 3
    /// Without matching evidence, pain and willingness to pay can't score above this.
    static let unprovenCap = 3
    /// A 5 for pain or willingness to pay needs at least this many different evidence items.
    static let independentItemsForTop = 2

    /// Pairs each candidate with its review, applies the evidence caps, and keeps ideas that are vibe-codable (the one
    /// must). The other principles only rank them; ideas the devil's advocate rejected are kept but rank below the ones
    /// it backed (owner, 12 Nov 2026). Best first, at most three.
    /// - Parameters:
    ///   - candidates: The pass 1 ideas.
    ///   - reviews: The pass 2 reviews; a candidate with no matching review is dropped.
    ///   - items: The item list, to check each idea's evidence.
    ///   - tool: The builder's tool, for the build cost.
    ///   - appType: The kind of app, for its yearly costs.
    /// - Returns: Up to `maxPerDay` results: the ones the devil's advocate backed first, then highest killer score.
    static func survivors(candidates: [Candidate], reviews: [Review], items: [FetchedItem] = [],
                          tool: BuilderTool = .claudeCode, appType: BuilderTool.AppType = .onDevice) -> [Result] {
        let byKey = Dictionary(reviews.map { (KillerIdea.key(for: $0.title), $0) }, uniquingKeysWith: { first, _ in first })
        return candidates.compactMap { candidate in
            guard let raw = byKey[KillerIdea.key(for: candidate.title)],
                  raw.buildability >= FiveTests.minimumVibeCodable else { return nil }
            let cited = evidence(for: candidate, in: items)
            return Result(candidate: candidate, review: capped(raw, evidence: cited), tool: tool,
                          payEvidence: payEvidenceCount(cited), appType: appType)
        }
        .sorted { $0.review.survives != $1.review.survives ? $0.review.survives : $0.score > $1.score }
        .prefix(maxPerDay)
        .map { $0 }
    }

    /// Merges the critic's competitors with the generator's: the critic decides who competes, but a price the critic
    /// didn't know is taken from the generator for the same name.
    static func mergedCompetitors(critic: [Competitor], generator: [Competitor], fillsGap: Bool) -> [Competitor] {
        guard !critic.isEmpty else { return fillsGap ? [] : generator }
        return critic.map { found in
            guard found.monthlyPrice == 0, !found.isFree,
                  let known = generator.first(where: { KillerIdea.key(for: $0.name) == KillerIdea.key(for: found.name) && $0.monthlyPrice > 0 })
            else { return found }
            var merged = found
            merged.monthlyPrice = known.monthlyPrice
            return merged
        }
    }

    /// The five principles for a review and the idea's prices. With a sales plan, test 5 runs the first-year sums
    /// (`PaybackSums`); ideas judged before sales plans keep the older build-cost-only payback.
    static func outcomes(review r: Review, price: Double, competitors: [Competitor], fillsGap: Bool,
                         tool: BuilderTool, payEvidence: Int, salesPlan: SalesPlan?) -> [TestOutcome] {
        FiveTests.outcomes(vibeCodable: r.buildability,
                           willPay: FiveTests.willPay(score: r.willingToPay, competitors: competitors, payEvidence: payEvidence),
                           pain: r.pain,
                           cheaper: FiveTests.cheaper(price: price, competitors: competitors, fillsGap: fillsGap),
                           coversBuild: salesPlan.map {
                               PaybackSums.coversBuild(plan: $0, monthlyPrice: price, customers: r.likelyCustomers,
                                                       buildDays: r.buildDays, tool: tool, channelScore: r.channelScore)
                           } ?? FiveTests.coversBuild(buildDays: r.buildDays, customers: r.likelyCustomers,
                                                      price: price, tool: tool, channelScore: r.channelScore))
    }

    /// Sources that count as evidence of pain: complaints and the user's own pain points.
    static let painEvidence: Set<SourceKind> = [.painPoints, .appReviews, .consumerReviews, .fieldNotes]
    /// Sources that count as evidence that people pay: complaints, funded startups, top paid apps, paid
    /// marketplace add-ons, government contracts.
    static let payEvidence: Set<SourceKind> = [.painPoints, .appReviews, .consumerReviews, .ycombinator, .appStore, .atlassian, .ausTender]

    /// How many different cited items show people paying.
    static func payEvidenceCount(_ cited: [FetchedItem]) -> Int {
        Set(cited.filter { payEvidence.contains($0.source) }.map(\.key)).count
    }

    /// Caps pain at 3 without pain evidence, and willingness to pay at 3 without pay evidence; a 5 for either needs
    /// at least two different evidence items of that kind. Enforced in code rather than trusted to the prompt,
    /// because models tend to score generously.
    /// - Parameters:
    ///   - review: The critic's review.
    ///   - evidence: The items the idea cites.
    /// - Returns: The review with capped scores.
    static func capped(_ review: Review, evidence: [FetchedItem]) -> Review {
        var r = review
        r.pain = min(r.pain, cap(for: evidence.filter { painEvidence.contains($0.source) }))
        r.willingToPay = min(r.willingToPay, cap(for: evidence.filter { payEvidence.contains($0.source) }))
        return r
    }

    /// The highest score the given supporting items allow: 3 with none, 4 with one, 5 with two or more different ones.
    private static func cap(for supporting: [FetchedItem]) -> Int {
        let distinct = Set(supporting.map(\.key)).count
        return distinct == 0 ? unprovenCap : distinct < independentItemsForTop ? 4 : 5
    }

    /// The score ideas had before the five principles (still used for older ideas and their improvements).
    /// - Parameter r: A review, normally already capped.
    /// - Returns: 0–5.
    static func legacyScore(_ r: Review) -> Double {
        KillerIdea.killerScore(pain: r.pain, willingToPay: r.willingToPay, timing: r.timing, gap: r.gap, fit: r.fit,
                               buildability: r.buildability, channel: r.channelScore)
    }
}
