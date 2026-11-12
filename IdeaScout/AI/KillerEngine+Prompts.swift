// KillerEngine+Prompts.swift
// Pass 1 of the idea step (proposing ideas): instructions, prompt, reply shape (JSON schema) and parser, plus the
// competitor and price cleaning both passes share. Prompts and schemas move together: field names here must match
// the parsers. The devil's advocate is in KillerEngine+Critique.swift; the rules applied in code in KillerEngine.swift.

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
    1-2 star reviews of business and consumer apps people pay for, which show buyers ready to switch, "Hacker News on \
    your area" are recent posts and comments about the user's interest area (read them for complaints and needs), \
    "AusTender" is government IT spending, and "My pain points" \
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
    ideally half the cheapest competitor's or less); sales_model ("one_off" for a single purchase or "subscription"): \
    choose one_off when the app costs nothing per customer to keep running (for example it runs entirely on the \
    device), and subscription when each customer costs money every month (AI calls, hosting, data) or gets something \
    new every month; sales_model_reason (one sentence on why); pricing (the price as customers would see it, for \
    example "$3 a month" or "$24 once", matching the sales model); replaces (the manual task or app it replaces and roughly what that costs the buyer \
    today); channel (the named place where the first buyers would be found); why now (what recently became \
    possible); a one-week test (the cheapest way to check demand in 7 days, with a pass mark); the numbers of the \
    projects that are evidence for it; and same_as: if the idea is essentially the same as one on the existing \
    leaderboard, copy that title exactly, otherwise an empty string. Propose new ideas: repeat one from the existing \
    leaderboard only if today's projects add evidence it didn't have, and never repeat one marked [dismissed by the \
    user] without such new evidence. Write everything in English.
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

    /// "one_off" or "subscription" (the `SalesModel` raw values).
    static let salesModelSchema: [String: Any] = ["type": "string", "enum": SalesModel.allCases.map(\.rawValue)]

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
                        "sales_model": salesModelSchema, "sales_model_reason": ["type": "string"],
                    ] as [String: Any],
                    "required": ["title", "pitch", "buyer", "pricing", "why_now", "one_week_test", "replaces", "channel",
                                 "evidence_numbers", "same_as", "one_job", "keep_features", "leave_out_features",
                                 "competitors", "fills_gap", "price_per_month_usd", "sales_model", "sales_model_reason"],
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
                let sales_model, sales_model_reason: String?
            }
            let ideas: [I]
        }
        return try JSONDecoder().decode(Out.self, from: try LLMSummarizer.extractJSON(data)).ideas.map {
            Candidate(title: $0.title, pitch: $0.pitch, buyer: $0.buyer, pricing: $0.pricing, whyNow: $0.why_now,
                      oneWeekTest: $0.one_week_test, evidenceNumbers: $0.evidence_numbers, sameAs: $0.same_as,
                      replaces: $0.replaces ?? "", channel: $0.channel ?? "", oneJob: StarterKit.clean($0.one_job ?? "", 300),
                      keepFeatures: cleanList($0.keep_features), leaveOutFeatures: cleanList($0.leave_out_features),
                      monthlyPrice: cleanPrice($0.price_per_month_usd), fillsGap: $0.fills_gap ?? false,
                      competitors: competitors($0.competitors),
                      salesModel: $0.sales_model.flatMap(SalesModel.init(rawValue:)),
                      salesModelReason: StarterKit.clean($0.sales_model_reason ?? "", 300))
        }
    }
}
