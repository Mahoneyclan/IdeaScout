// KillerEngine+Critique.swift
// Pass 2 of the idea step, the devil's advocate: its instructions, prompt, reply shape (JSON schema) and parser.
// Prompts and schemas move together: field names here must match the parser. Split from KillerEngine+Prompts.swift.

import Foundation

extension KillerEngine {
    // MARK: - Pass 2: devil's advocate

    /// Pass 2 instructions: try to kill each idea using its evidence, with a defined meaning for every
    /// score level; no invented competitor prices. Field names must match `reviewSchema`.
    static let critiqueInstructions = """
    You are a blunt, experienced investor playing devil's advocate for a solo builder who will vibe-code the \
    product (build it alone with AI coding tools) and sell it without a sales team. For each product idea, read its \
    cited evidence and try hard to kill it: name competitors you are confident exist, question whether the \
    buyer would really pay for it, whether one person could really build all of it with the builder's tool as the \
    kind of app given, and whether the named channel would \
    really reach buyers. Check the idea's competitors and prices: correct them, and list in competitors_found the \
    products it would really compete with (up to 3), each with name, cheapest_plan, price_per_month_usd (the cheapest \
    comparable plan for one user, a one-off price divided by 12) and is_free (true only if it is free to use); an \
    empty list if no app does this job. Give a price only if you are sure of it, otherwise 0. Don't invent facts.
    Score each 1-5 (be strict; 5 is rare):
    - pain: 1 nice-to-have; 3 a recurring problem people work around; 5 costly and frequent, shown in 2 or more independent evidence items
    - willing_to_pay: 1 no sign anyone spends money here; 3 people or businesses pay for nearby products; 5 buyers already pay for a worse product or name a budget
    - timing: 1 could have been built years ago; 3 recent tools make it easier; 5 a new capability, rule or price makes it possible or required now
    - gap: 1 well served by existing products; 3 options exist but leave a clear segment unhappy; 5 no credible option
    - fit: 1 needs skills or access the person lacks; 3 unknown or neutral; 5 uses their domain experience or access
    - buildability: 1 the builder's tool can't build it (it needs a team, hardware, regulated data or many deep \
    integrations); 3 one person could build it with the tool, but with real difficulty; 5 one person could build all \
    of it with the tool, simply
    - channel_score: 1 needs a sales team or cold outreach; 3 buyers are reachable but there is no obvious place they \
    look; 5 a named marketplace or community where these buyers already shop for tools like this
    Mark ideas down hard if there is no clear buyer who would pay, or no realistic way for it to make money. For \
    consumer ideas, also judge whether the channel reaches buyers without a large advertising budget.
    Estimate build_days (days for one person to build a first version people would pay for, with their tool) and \
    likely_customers (paying customers likely in the first year from the named channel, assuming the app stays small; \
    be realistic, often 10 to 200). Answer in one sentence each: follow_risk (would the competitors follow with a \
    cheaper or simpler version?), copy_risk (what stops another vibe coder copying it?) and keep_paying (will \
    customers keep paying, or leave after one use or for the next cheaper app?).
    Check how it is sold: give sales_model ("one_off" or "subscription"; keep the idea's choice unless it is wrong: \
    an app that costs money per customer every month should be a subscription) and sales_model_reason (one sentence). \
    Estimate running_cost_per_customer_usd (what each customer costs the builder per month: AI calls, hosting, data; \
    0 if it runs entirely on the device), other_yearly_costs_usd (fixed yearly costs such as hosting, a domain or \
    keeping the builder's tool plan to host the app; leave out Apple's developer fee; 0 if none) and monthly_churn_percent (for \
    a subscription, the share of customers who cancel each month, often 3 to 10; 0 for a one-off sale).
    Judge whether the one-week test would really show demand. survives is true only if the idea is still worth \
    a one-week test after your objections. Give the single strongest objection, the main competitors (or "none found"), \
    a one-sentence verdict, and evidence_needed: the one fact that would most raise the score. Copy each title exactly. \
    If an app the user named is given, survives is false for any idea that copies it: the same job for the same \
    people, or its name, slogans, feature wording, screens or design. Mark gap down hard when an app already built by \
    solo builders does the same job. Write everything in English.
    """ + Prompts.untrustedData

    /// Pass 2: the devil's advocate (feature "Devil's advocate"). Uses high effort because judging is where
    /// quality matters most.
    /// - Parameters:
    ///   - candidates: The pass 1 ideas.
    ///   - items: The numbered items, to attach each idea's cited evidence.
    ///   - aboutMe: The user's profile, for the fit score.
    /// - Returns: One review per idea the critic answered; matched to candidates later by title.
    /// - Throws: Errors from the AI call or the parser.
    func critique(_ candidates: [Candidate], items: [FetchedItem], aboutMe: String,
                  tool: BuilderTool = .claudeCode, appType: BuilderTool.AppType? = nil,
                  target: Undercut.Target? = nil) async throws -> [Review] {
        let data = try await (judge ?? llm.client).complete(system: Self.critiqueInstructions,
                                                 prompt: Self.critiquePrompt(candidates, items: items, aboutMe: aboutMe, tool: tool,
                                                                             appType: appType, target: target),
                                                 schema: Self.reviewSchema, effort: "high", feature: "Devil's advocate")
        return try Self.parseReviews(data)
    }

    /// The pass 2 prompt: each idea with its pitch, buyer, price, what it replaces, why now, one-week test
    /// and its cited evidence (200 characters each), so the critic can check claims.
    /// - Parameters:
    ///   - candidates: The pass 1 ideas.
    ///   - items: The numbered items the evidence numbers point into.
    ///   - aboutMe: The user's profile; "(not provided)" when empty.
    ///   - target: "Reimagine an app": the app the user named, so copies of it can be failed; `nil` for a scan.
    /// - Returns: The prompt text.
    static func critiquePrompt(_ candidates: [Candidate], items: [FetchedItem], aboutMe: String,
                               tool: BuilderTool = .claudeCode, appType: BuilderTool.AppType? = nil,
                               target: Undercut.Target? = nil) -> String {
        var text = "About me: " + (aboutMe.isEmpty ? "(not provided)" : aboutMe)
        text += "\nBuilder's tool: \(tool.label). Each idea must be \(tool.forAI(appType))."
        if let target { text += "\n" + Undercut.promptBlock(target) }
        text += "\n\nIdeas:"
        for c in candidates {
            text += "\n\nTitle: \(c.title)\nPitch: \(c.pitch)\nBuyer: \(c.buyer)\nPricing: \(c.pricing)"
            if !c.replaces.isEmpty { text += "\nReplaces: \(c.replaces)" }
            if !c.channel.isEmpty { text += "\nSales channel: \(c.channel)" }
            text += "\nWhy now: \(c.whyNow)\nOne-week test: \(c.oneWeekTest)"
            text += Self.offerText(oneJob: c.oneJob, keep: c.keepFeatures, leaveOut: c.leaveOutFeatures,
                                   price: FiveTests.capped(c.monthlyPrice, competitors: c.competitors),
                                   competitors: c.competitors, fillsGap: c.fillsGap, salesModel: c.salesModel)
            if !c.salesModelReason.isEmpty { text += "\nWhy sold this way: \(c.salesModelReason)" }
            let evidence = Self.evidence(for: c, in: items)
            text += "\nEvidence:" + (evidence.isEmpty ? " (none cited)" : "")
            for item in evidence {
                let detail = item.detail.isEmpty ? "" : " — " + String(item.detail.prefix(200))
                text += "\n- [\(item.source.label)] \(item.title)\(detail)"
            }
        }
        return text
    }

    /// The idea's job, features, price and competitors as prompt lines (shared with "Improve this idea").
    static func offerText(oneJob: String, keep: [String], leaveOut: [String], price: Double, competitors: [Competitor],
                          fillsGap: Bool, salesModel: SalesModel? = nil) -> String {
        var text = ""
        if !oneJob.isEmpty { text += "\nOne job: \(oneJob)" }
        if !keep.isEmpty { text += "\nKeeps: " + keep.joined(separator: "; ") }
        if !leaveOut.isEmpty { text += "\nLeaves out: " + leaveOut.joined(separator: "; ") }
        if price > 0 {
            text += salesModel == .oneOff
                ? "\nSold once for \(FiveTests.money(price * 12)) (\(FiveTests.money(price)) a month over a year)"
                : "\nRecommended price per month: \(FiveTests.money(price))"
        }
        if salesModel == .subscription { text += "\nSold as a subscription" }
        if fillsGap { text += "\nFills a gap: no app does this job yet" }
        if !competitors.isEmpty {
            text += "\nCompetitors: " + competitors.map {
                "\($0.name) (\($0.plan.isEmpty ? "plan unknown" : $0.plan), "
                    + ($0.monthlyPrice > 0 ? "\(FiveTests.money($0.monthlyPrice))/month" : "price unknown") + ")"
            }.joined(separator: "; ")
        }
        return text
    }

    /// The projects an idea cites, by their 1-based numbers in the item list.
    /// - Parameters:
    ///   - candidate: The idea whose `evidenceNumbers` to resolve.
    ///   - items: The item list in prompt order.
    /// - Returns: The cited items. Numbers outside the list are dropped, since AI output is untrusted.
    static func evidence(for candidate: Candidate, in items: [FetchedItem]) -> [FetchedItem] {
        candidate.evidenceNumbers.map { $0 - 1 }.filter { items.indices.contains($0) }.map { items[$0] }
    }

    /// JSON Schema for pass 2. Keep in sync with `parseReviews` and the instructions.
    static let reviewSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "reviews": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"], "survives": ["type": "boolean"], "objection": ["type": "string"],
                        "competitors": ["type": "string"], "verdict": ["type": "string"],
                        "pain": ["type": "integer"], "willing_to_pay": ["type": "integer"], "timing": ["type": "integer"],
                        "gap": ["type": "integer"], "fit": ["type": "integer"],
                        "buildability": ["type": "integer"], "channel_score": ["type": "integer"],
                        "evidence_needed": ["type": "string"],
                        "build_days": ["type": "integer"], "likely_customers": ["type": "integer"],
                        "competitors_found": ["type": "array", "items": competitorSchema],
                        "follow_risk": ["type": "string"], "copy_risk": ["type": "string"], "keep_paying": ["type": "string"],
                        "sales_model": salesModelSchema, "sales_model_reason": ["type": "string"],
                        "running_cost_per_customer_usd": ["type": "number"], "other_yearly_costs_usd": ["type": "number"],
                        "monthly_churn_percent": ["type": "number"],
                    ],
                    "required": ["title", "survives", "objection", "competitors", "verdict", "pain", "willing_to_pay",
                                 "timing", "gap", "fit", "buildability", "channel_score", "evidence_needed",
                                 "build_days", "likely_customers", "competitors_found", "follow_risk", "copy_risk",
                                 "keep_paying", "sales_model", "sales_model_reason", "running_cost_per_customer_usd",
                                 "other_yearly_costs_usd", "monthly_churn_percent"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["reviews"],
        "additionalProperties": false,
    ]

    /// Longest believable build, in days; longer estimates are capped.
    static let maxBuildDays = 365
    /// Most first-year customers believed for a small app; larger estimates are capped.
    static let maxLikelyCustomers = 100_000

    /// Decodes the pass 2 reply.
    /// - Parameter data: The raw reply body.
    /// - Returns: Reviews with every score clamped to 0–5. A missing buildability or channel score (a reply in
    ///   the older shape) becomes 0, which `survivors` then rejects as a weak spot.
    /// - Throws: `DecodingError` or `SummarizerError` if the reply doesn't match `reviewSchema`.
    static func parseReviews(_ data: Data) throws -> [Review] {
        /// The reply's JSON shape (field names match the schema).
        struct Out: Decodable {
            struct R: Decodable {
                let title, objection, competitors, verdict: String
                let survives: Bool
                let pain, willing_to_pay, timing, gap, fit: Int
                let buildability, channel_score, build_days, likely_customers: Int?
                let evidence_needed, follow_risk, copy_risk, keep_paying: String?
                let competitors_found: [CompetitorReply]?
                let sales_model, sales_model_reason: String?
                let running_cost_per_customer_usd, other_yearly_costs_usd, monthly_churn_percent: Double?

                /// The sales plan, when the reply has a sales model (older replies don't).
                var salesPlan: SalesPlan? {
                    sales_model.flatMap(SalesModel.init(rawValue:)).map {
                        SalesPlan(model: $0, reason: sales_model_reason ?? "",
                                  runningCostPerCustomer: running_cost_per_customer_usd ?? 0,
                                  otherYearlyCosts: other_yearly_costs_usd ?? 0,
                                  monthlyChurnPercent: monthly_churn_percent ?? 0).cleaned
                    }
                }
            }
            let reviews: [R]
        }
        return try JSONDecoder().decode(Out.self, from: try LLMSummarizer.extractJSON(data)).reviews.map {
            Review(title: $0.title, survives: $0.survives, objection: $0.objection, competitors: $0.competitors,
                   verdict: $0.verdict, pain: Ranking.clamp($0.pain), willingToPay: Ranking.clamp($0.willing_to_pay),
                   timing: Ranking.clamp($0.timing), gap: Ranking.clamp($0.gap), fit: Ranking.clamp($0.fit),
                   buildability: Ranking.clamp($0.buildability ?? 0), channelScore: Ranking.clamp($0.channel_score ?? 0),
                   evidenceNeeded: $0.evidence_needed ?? "",
                   buildDays: min(max($0.build_days ?? 0, 0), maxBuildDays),
                   likelyCustomers: min(max($0.likely_customers ?? 0, 0), maxLikelyCustomers),
                   competitorsFound: competitors($0.competitors_found),
                   followRisk: StarterKit.clean($0.follow_risk ?? "", 300), copyRisk: StarterKit.clean($0.copy_risk ?? "", 300),
                   keepPaying: StarterKit.clean($0.keep_paying ?? "", 300), salesPlan: $0.salesPlan)
        }
    }
}
