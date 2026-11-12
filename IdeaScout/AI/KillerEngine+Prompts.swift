// KillerEngine+Prompts.swift
// The idea step's two AI calls: what the AI is told (instructions and prompts), the reply shapes (JSON schemas) and
// the parsers. Prompts and schemas move together: field names here must match the parsers. Split from
// KillerEngine.swift, which keeps the types and the rules applied in code.

import Foundation

extension KillerEngine {
    // MARK: - Pass 1: generate

    /// Pass 1 instructions: the owner's purpose and five principles (only vibe-codable is a must), someone pays
    /// (a business or a consumer), a named sales channel, at most 1 developer tool, all in the interest area and of the
    /// tool's app type, each replacing a named manual task, with competitors, a much lower price and a one-week test.
    /// Field names must match `candidateSchema`.
    static let generateInstructions = """
    You are a sharp product strategist. Find killer app ideas that one person can vibe-code (build alone with their \
    AI coding tool) and sell for a fraction of what competitors charge, making money even if only a small group of \
    customers ever buys. Growth is a bonus, not the goal. Judge every idea by five principles:
    1. Vibe-codable (a must): one person can build all of it with their AI coding tool.
    2. People will pay: they already pay for an app that does this, or for a workaround (a pricier tool, a service \
    or their own time).
    3. Real pain: people complain about the apps they use for this (too expensive, too bloated, or missing the one \
    thing they need), or that no app does it.
    4. Materially cheaper: ideally half the price of the cheapest competitor or less.
    5. Sales cover the build cost: likely sales from a small number of customers, found in a named place where they \
    already look, pay back the build and keep making money.
    Using the pain clusters, trends and numbered projects (items tagged Demand show need: "Pain points" are people \
    complaining or asking for tools that don't exist, "App Store complaints" and "Consumer app complaints" are \
    1-2 star reviews of business and consumer apps people pay for, which show buyers ready to switch, "AusTender" is government IT spending, and "My pain points" \
    are the user's own problems, which are strong evidence; "Atlassian Marketplace", "Y Combinator" and \
    "App Store top paid" show what people and businesses already pay for, and also who the competitors are; "Vibe-coded", "Show HN" \
    and "GitHub" show what other builders have already made, so treat them as competition, not inspiration; \
    "AI research" shows new capabilities), propose 5 distinct product ideas. Rules:
    - Someone must pay for it. The buyer can be a business or a consumer (for example a subscription of a few \
    dollars a month, a one-off purchase or usage-based pricing). It needs a clear way to make money: not a hobby \
    project or a free tool with no income.
    - One person must be able to build all of it with their AI coding tool (vibe-code it). Avoid products \
    that need hardware, a team, real-time systems, many deep integrations, holding money or health records, or \
    government or enterprise procurement.
    - Each must have a named sales channel where these buyers already look for products like it: an app \
    marketplace (for example the App Store, Shopify App Store, Atlassian Marketplace, Chrome Web Store, WordPress \
    plugins, Google Workspace Marketplace), an industry or interest community, or a phrase buyers search for. "Social media" or "cold outreach" alone is not a channel.
    - Prefer doing the one job people need with fewer features than the apps they pay for now: it's quicker to \
    build and can be priced far lower. Easy-to-build products are easy to copy, so the builder's protection is a \
    narrow group of buyers, domain knowledge and owning the channel.
    - At most 1 of the 5 may be a tool for software developers.
    - If an interest area is given below, every idea must be in it.
    - Every idea must be the kind of app given below for the builder's tool, and one person must be able to build \
    all of it with that tool. Don't propose anything that tool can't build.
    - Each must replace a named manual task, spreadsheet or costly app that the buyer uses today.
    Prefer ideas that solve a pain cluster and are supported by several projects. Cite at least one Demand item for each idea. Only propose ideas you would genuinely back; \
    quality matters more than variety.
    For each idea give: a short memorable title; a one-sentence pitch; the buyer (a specific role in a specific \
    type of business, or a specific type of consumer); one_job (the one job it does); keep_features (2 to 6 \
    features to keep) and leave_out_features (2 to 6 features the competitors have that it leaves out); \
    competitors (1 to 3 products people pay for now, each with name, cheapest_plan and price_per_month_usd: the \
    cheapest comparable plan for one user, a one-off price divided by 12, 0 if you don't know; give a price only if \
    you are fairly sure of it; and is_free, true only if it is free to use; an empty list if no app does this job); fills_gap (true only if no app does this job); \
    price_per_month_usd (your recommended price per customer per month in US dollars, a one-off price divided by 12; \
    ideally half the cheapest competitor's or less); pricing (the price as customers would see it, for example \
    "$3 a month" or "$24 once"); replaces (the manual task or app it replaces and roughly what that costs the buyer \
    today); channel (the named place where the first buyers would be found); why now (what recently became \
    possible); a one-week test (the cheapest way to check demand in 7 days, with a pass mark); the numbers of the \
    projects that are evidence for it; and same_as: if the idea is essentially the same as one on the existing \
    leaderboard, copy that title exactly, otherwise an empty string. Write everything in English.
    """ + Prompts.untrustedData

    /// Pass 1: asks for 5 candidate ideas (feature "Killer ideas", medium effort).
    /// - Parameter context: What the prompt is built from.
    /// - Returns: The candidates as parsed; not yet checked against the evidence.
    /// - Throws: Errors from the AI call or the parser.
    func generate(_ context: Context) async throws -> [Candidate] {
        let data = try await llm.client.complete(system: Self.generateInstructions, prompt: Self.generatePrompt(context),
                                                 schema: Self.candidateSchema, effort: "medium", feature: "Killer ideas")
        return try Self.parseCandidates(data)
    }

    /// The pass 1 prompt: profile, interest area, the builder's tool and app type, pain clusters, trends with variants, numbered items
    /// (160 characters of detail) and the existing leaderboard.
    /// - Parameter context: What the prompt is built from.
    /// - Returns: The prompt text. Contains public text, so it's paired with `Prompts.untrustedData` in the instructions.
    static func generatePrompt(_ context: Context) -> String {
        var parts: [String] = []
        parts.append("About me: " + (context.aboutMe.isEmpty ? "(not provided)" : context.aboutMe))
        if !context.interestArea.isEmpty { parts.append("Interest area: " + context.interestArea) }
        parts.append("Builder's tool: \(context.tool.label). Every idea must be \(context.tool.forAI(context.appType)).")
        let trends = context.themes.filter { !$0.isCatchAll && !$0.isPainCluster }.map { theme in
            "- \(theme.title): \(theme.summary)" + (theme.opportunities.isEmpty ? "" : " Variants: " + theme.opportunities.joined(separator: " | "))
        }
        if !context.painClusters.isEmpty {
            parts.append("Pain clusters (demand):\n" + context.painClusters.map { "- \($0)" }.joined(separator: "\n"))
        }
        parts.append("Trends in this scan:\n" + trends.joined(separator: "\n"))
        parts.append("Projects:\n" + Prompts.itemList(context.items, detailLimit: 160))
        parts.append("Existing leaderboard:\n" + (context.leaderboard.isEmpty ? "(empty)" : context.leaderboard.map { "- \($0)" }.joined(separator: "\n")))
        return parts.joined(separator: "\n\n")
    }

    /// One competitor in a reply: name, cheapest comparable plan and its monthly price.
    static let competitorSchema: [String: Any] = [
        "type": "object",
        "properties": ["name": ["type": "string"], "cheapest_plan": ["type": "string"], "price_per_month_usd": ["type": "number"],
                       "is_free": ["type": "boolean"]],
        "required": ["name", "cheapest_plan", "price_per_month_usd", "is_free"],
        "additionalProperties": false,
    ]

    /// JSON Schema for pass 1. Keep in sync with `parseCandidates` and the instructions.
    static let candidateSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "ideas": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"], "pitch": ["type": "string"], "buyer": ["type": "string"],
                        "pricing": ["type": "string"], "why_now": ["type": "string"], "one_week_test": ["type": "string"],
                        "replaces": ["type": "string"], "channel": ["type": "string"],
                        "evidence_numbers": ["type": "array", "items": ["type": "integer"]], "same_as": ["type": "string"],
                        "one_job": ["type": "string"],
                        "keep_features": ["type": "array", "items": ["type": "string"]],
                        "leave_out_features": ["type": "array", "items": ["type": "string"]],
                        "competitors": ["type": "array", "items": competitorSchema],
                        "fills_gap": ["type": "boolean"], "price_per_month_usd": ["type": "number"],
                    ] as [String: Any],
                    "required": ["title", "pitch", "buyer", "pricing", "why_now", "one_week_test", "replaces", "channel",
                                 "evidence_numbers", "same_as", "one_job", "keep_features", "leave_out_features",
                                 "competitors", "fills_gap", "price_per_month_usd"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["ideas"],
        "additionalProperties": false,
    ]

    /// A competitor as the AI wrote it (field names match `competitorSchema`).
    struct CompetitorReply: Decodable {
        let name: String
        let cheapest_plan: String?
        let price_per_month_usd: Double?
        let is_free: Bool?
    }

    /// Most features or competitors kept from one reply.
    static let maxListItems = 6
    /// Highest believable monthly price; anything above is treated as unknown.
    static let maxMonthlyPrice = 100_000.0

    /// Cleans the AI's competitors: links removed, text capped, impossible prices treated as unknown, at most 3.
    static func competitors(_ replies: [CompetitorReply]?) -> [Competitor] {
        (replies ?? []).compactMap { reply in
            let name = StarterKit.clean(reply.name, 80)
            guard !name.isEmpty else { return nil }
            let isFree = reply.is_free ?? false
            return Competitor(name: name, plan: StarterKit.clean(reply.cheapest_plan ?? "", 80),
                              monthlyPrice: isFree ? 0 : cleanPrice(reply.price_per_month_usd), isFree: isFree)
        }
        .prefix(3).map { $0 }
    }

    /// Cleans a list from the AI: links removed, each item capped, empty items dropped, at most `maxListItems`.
    static func cleanList(_ list: [String]?) -> [String] {
        (list ?? []).map { StarterKit.clean($0, 120) }.filter { !$0.isEmpty }.prefix(maxListItems).map { $0 }
    }

    /// A price from the AI: a finite amount from `FiveTests.minimumPrice` to `maxMonthlyPrice`, otherwise 0 (unknown).
    static func cleanPrice(_ value: Double?) -> Double {
        guard let value, value.isFinite, value >= FiveTests.minimumPrice, value <= maxMonthlyPrice else { return 0 }
        return value
    }

    /// Decodes the pass 1 reply.
    /// - Parameter data: The raw reply body.
    /// - Returns: The candidates. Fields added later are optional, so replies from older prompts still parse.
    /// - Throws: `DecodingError` or `SummarizerError` if the reply doesn't match `candidateSchema`.
    static func parseCandidates(_ data: Data) throws -> [Candidate] {
        /// The reply's JSON shape (field names match the schema).
        struct Out: Decodable {
            struct I: Decodable {
                let title, pitch, buyer, pricing, why_now, one_week_test, same_as: String
                let replaces, channel, one_job: String?
                let evidence_numbers: [Int]
                let keep_features, leave_out_features: [String]?
                let competitors: [CompetitorReply]?
                let fills_gap: Bool?
                let price_per_month_usd: Double?
            }
            let ideas: [I]
        }
        return try JSONDecoder().decode(Out.self, from: try LLMSummarizer.extractJSON(data)).ideas.map {
            Candidate(title: $0.title, pitch: $0.pitch, buyer: $0.buyer, pricing: $0.pricing, whyNow: $0.why_now,
                      oneWeekTest: $0.one_week_test, evidenceNumbers: $0.evidence_numbers, sameAs: $0.same_as,
                      replaces: $0.replaces ?? "", channel: $0.channel ?? "", oneJob: StarterKit.clean($0.one_job ?? "", 300),
                      keepFeatures: cleanList($0.keep_features), leaveOutFeatures: cleanList($0.leave_out_features),
                      monthlyPrice: cleanPrice($0.price_per_month_usd), fillsGap: $0.fills_gap ?? false,
                      competitors: competitors($0.competitors))
        }
    }

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
    Judge whether the one-week test would really show demand. survives is true only if the idea is still worth \
    a one-week test after your objections. Give the single strongest objection, the main competitors (or "none found"), \
    a one-sentence verdict, and evidence_needed: the one fact that would most raise the score. Copy each title exactly. \
    Write everything in English.
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
                  tool: BuilderTool = .claudeCode, appType: BuilderTool.AppType? = nil) async throws -> [Review] {
        let data = try await llm.client.complete(system: Self.critiqueInstructions,
                                                 prompt: Self.critiquePrompt(candidates, items: items, aboutMe: aboutMe, tool: tool, appType: appType),
                                                 schema: Self.reviewSchema, effort: "high", feature: "Devil's advocate")
        return try Self.parseReviews(data)
    }

    /// The pass 2 prompt: each idea with its pitch, buyer, price, what it replaces, why now, one-week test
    /// and its cited evidence (200 characters each), so the critic can check claims.
    /// - Parameters:
    ///   - candidates: The pass 1 ideas.
    ///   - items: The numbered items the evidence numbers point into.
    ///   - aboutMe: The user's profile; "(not provided)" when empty.
    /// - Returns: The prompt text.
    static func critiquePrompt(_ candidates: [Candidate], items: [FetchedItem], aboutMe: String,
                               tool: BuilderTool = .claudeCode, appType: BuilderTool.AppType? = nil) -> String {
        var text = "About me: " + (aboutMe.isEmpty ? "(not provided)" : aboutMe)
        text += "\nBuilder's tool: \(tool.label). Each idea must be \(tool.forAI(appType)).\n\nIdeas:"
        for c in candidates {
            text += "\n\nTitle: \(c.title)\nPitch: \(c.pitch)\nBuyer: \(c.buyer)\nPricing: \(c.pricing)"
            if !c.replaces.isEmpty { text += "\nReplaces: \(c.replaces)" }
            if !c.channel.isEmpty { text += "\nSales channel: \(c.channel)" }
            text += "\nWhy now: \(c.whyNow)\nOne-week test: \(c.oneWeekTest)"
            text += Self.offerText(oneJob: c.oneJob, keep: c.keepFeatures, leaveOut: c.leaveOutFeatures,
                                   price: c.monthlyPrice, competitors: c.competitors, fillsGap: c.fillsGap)
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
                          fillsGap: Bool) -> String {
        var text = ""
        if !oneJob.isEmpty { text += "\nOne job: \(oneJob)" }
        if !keep.isEmpty { text += "\nKeeps: " + keep.joined(separator: "; ") }
        if !leaveOut.isEmpty { text += "\nLeaves out: " + leaveOut.joined(separator: "; ") }
        if price > 0 { text += "\nRecommended price per month: \(FiveTests.money(price))" }
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
                    ],
                    "required": ["title", "survives", "objection", "competitors", "verdict", "pain", "willing_to_pay",
                                 "timing", "gap", "fit", "buildability", "channel_score", "evidence_needed",
                                 "build_days", "likely_customers", "competitors_found", "follow_risk", "copy_risk",
                                 "keep_paying"],
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
                   keepPaying: StarterKit.clean($0.keep_paying ?? "", 300))
        }
    }
}
