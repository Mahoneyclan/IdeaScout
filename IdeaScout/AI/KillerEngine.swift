// KillerEngine.swift
// The idea step of a refresh: two cloud AI calls. Pass 1 proposes 5 money-making ideas from the pain clusters,
// trends and items; pass 2 plays devil's advocate and scores them. Code then applies the evidence rules
// and keeps up to 3 survivors, which DigestService saves as KillerIdeas. Ideas are aimed at a solo builder
// who will vibe-code the product, so each must be buildable by one person and have a named sales channel.

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
        /// Whether one person with AI coding tools could ship a first version in about 4 weeks (1–5).
        var buildability: Int
        /// How reachable the buyers are without a sales team, through the named channel (1–5).
        var channelScore: Int
        /// The one fact that would most raise the score.
        var evidenceNeeded = ""
    }

    /// A surviving idea with its (evidence-capped) review.
    struct Result: Equatable, Sendable {
        /// The idea as proposed in pass 1.
        var candidate: Candidate
        /// The pass 2 review, after evidence caps.
        var review: Review
        /// The weighted killer score (see `KillerIdea.killerScore(pain:willingToPay:timing:gap:fit:buildability:channel:)`).
        var score: Double { KillerEngine.score(review) }
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
        /// Industry that at least 2 ideas must target.
        var focusIndustry = ""
        /// Pain clusters as one-line summaries for the prompt.
        var painClusters: [String] = []
    }

    /// Every idea the devil's advocate didn't kill is kept (up to 3 a day). Whether it counts as a
    /// "killer" or a "near-miss" is decided on screen from the quality bar, so near-misses can come back and climb.
    /// - Parameter context: Trends, numbered items, profile and leaderboard from the trend step.
    /// - Returns: Up to `maxPerDay` survivors, best first; empty if pass 1 proposed nothing.
    /// - Throws: Errors from either AI call or the parsers.
    /// - Note: `onCritique` is called between the two passes. Two paid calls are made unless pass 1 returns nothing.
    func run(_ context: Context) async throws -> [Result] {
        let candidates = try await generate(context)
        guard !candidates.isEmpty else { return [] }
        await onCritique()
        let reviews = try await critique(candidates, items: context.items, aboutMe: context.aboutMe)
        return Self.survivors(candidates: candidates, reviews: reviews, items: context.items)
    }

    /// No single measure may be this low, however good the average.
    static let minimumSingleScore = 2
    /// At most this many ideas are kept per refresh, so the leaderboard isn't flooded.
    static let maxPerDay = 3
    /// Without matching evidence, pain and willingness to pay can't score above this.
    static let unprovenCap = 3

    // MARK: - Pass 1: generate

    /// Pass 1 instructions: someone pays (a business or a consumer), buildable by one person with AI coding tools, a named sales
    /// channel, at most 1 developer tool, at least 2 in the focus industry, each replacing a named manual task,
    /// with a one-week test. Field names must match `candidateSchema`.
    static let generateInstructions = """
    You are a sharp product strategist finding a software idea that makes money, for a solo builder who will \
    vibe-code it (build it alone with AI coding tools) and sell it without a sales team. A good idea has real pain, \
    a specific buyer who will pay, a clear gap, a place where those buyers already look for products like it, and \
    a good fit for the person described.
    Using the pain clusters, trends and numbered projects (items tagged Demand show need: "Pain points" are people \
    complaining or asking for tools that don't exist, "App Store complaints" and "Consumer app complaints" are \
    1-2 star reviews of business and consumer apps people pay for, which show buyers ready to switch, "AusTender" is government IT spending, and "My business challenges" \
    are the user's own observations from work, which are strong evidence; "Atlassian Marketplace", "Y Combinator" and \
    "App Store top paid" show what people and businesses already pay for, and also who the competitors are; "Vibe-coded", "Show HN" \
    and "GitHub" show what other builders have already made, so treat them as competition, not inspiration; \
    "AI research" shows new capabilities), propose 5 distinct product ideas. Rules:
    - Someone must pay for it. The buyer can be a business (small and medium businesses would pay $20 to $500 a \
    month; larger companies in the focus industry may pay more) or a consumer (for example a subscription of a few \
    dollars a month, a one-off purchase or usage-based pricing). It needs a clear way to make money: not a hobby \
    project or a free tool with no income.
    - One person with AI coding tools must be able to ship a useful first version in about 4 weeks. Avoid products \
    that need hardware, a team, real-time systems, many deep integrations, holding money or health records, or \
    government or enterprise procurement.
    - Each must have a named sales channel where these buyers already look for products like it: an app \
    marketplace (for example the App Store, Shopify App Store, Atlassian Marketplace, Chrome Web Store, WordPress \
    plugins, Google Workspace Marketplace), an industry or interest community, or a phrase buyers search for. "Social media" or "cold outreach" alone is not a channel.
    - Prefer a narrow niche (one type of buyer, one job) over a broad tool: easy-to-build products are easy to \
    copy, so the builder's protection is the niche, domain knowledge and owning the channel.
    - At most 1 of the 5 may be a tool for software developers.
    - At least 2 of the 5 must be aimed at the focus industry given below.
    - Each must replace a named manual task, spreadsheet or costly workaround that the buyer does today.
    - Each must be a concrete product someone could start building this month, not a trend summary.
    Prefer ideas that solve a pain cluster and are supported by several projects. Cite at least one Demand item for each idea. Only propose ideas you would genuinely back; \
    quality matters more than variety.
    For each idea give: a short memorable title; a one-sentence pitch; the buyer (a specific role in a specific \
    type of business, or a specific type of consumer); pricing (model and price per customer, per month or one-off); replaces (the manual task or workaround \
    it replaces and roughly what that costs the buyer today); channel (the named place where the first 100 buyers \
    would be found); why now (what recently became possible); a one-week test (the cheapest way to check demand \
    in 7 days, with a pass mark); the numbers of the projects that are evidence for it; and same_as: if the idea \
    is essentially the same as one on the existing leaderboard, copy that title exactly, otherwise an empty string. \
    Write everything in English.
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

    /// The pass 1 prompt: profile, focus industry, pain clusters, trends with variants, numbered items
    /// (160 characters of detail) and the existing leaderboard.
    /// - Parameter context: What the prompt is built from.
    /// - Returns: The prompt text. Contains public text, so it's paired with `Prompts.untrustedData` in the instructions.
    static func generatePrompt(_ context: Context) -> String {
        var parts: [String] = []
        parts.append("About me: " + (context.aboutMe.isEmpty ? "(not provided)" : context.aboutMe))
        if !context.focusIndustry.isEmpty { parts.append("Focus industry: " + context.focusIndustry) }
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
                    ],
                    "required": ["title", "pitch", "buyer", "pricing", "why_now", "one_week_test", "replaces", "channel",
                                 "evidence_numbers", "same_as"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["ideas"],
        "additionalProperties": false,
    ]

    /// Decodes the pass 1 reply.
    /// - Parameter data: The raw reply body.
    /// - Returns: The candidates. `replaces` and `channel` are optional so replies from older prompts still parse.
    /// - Throws: `DecodingError` or `SummarizerError` if the reply doesn't match `candidateSchema`.
    static func parseCandidates(_ data: Data) throws -> [Candidate] {
        /// The reply's JSON shape (field names match the schema).
        struct Out: Decodable {
            struct I: Decodable {
                let title, pitch, buyer, pricing, why_now, one_week_test, same_as: String
                let replaces, channel: String?
                let evidence_numbers: [Int]
            }
            let ideas: [I]
        }
        return try JSONDecoder().decode(Out.self, from: try LLMSummarizer.extractJSON(data)).ideas.map {
            Candidate(title: $0.title, pitch: $0.pitch, buyer: $0.buyer, pricing: $0.pricing, whyNow: $0.why_now,
                      oneWeekTest: $0.one_week_test, evidenceNumbers: $0.evidence_numbers, sameAs: $0.same_as,
                      replaces: $0.replaces ?? "", channel: $0.channel ?? "")
        }
    }

    // MARK: - Pass 2: devil's advocate

    /// Pass 2 instructions: try to kill each idea using its evidence, with a defined meaning for every
    /// score level; no invented competitor prices. Field names must match `reviewSchema`.
    static let critiqueInstructions = """
    You are a blunt, experienced investor playing devil's advocate for a solo builder who will vibe-code the \
    product (build it alone with AI coding tools) and sell it without a sales team. For each product idea, read its \
    cited evidence and try hard to kill it: name competitors you are confident exist, question whether the \
    buyer would really pay for it, whether one person could really build it, and whether the named channel would \
    really reach buyers. Give a competitor's price only if you are sure of it; otherwise say "price unknown". Don't invent facts.
    Score each 1-5 (be strict; 5 is rare):
    - pain: 1 nice-to-have; 3 a recurring problem people work around; 5 costly and frequent, shown in 2 or more independent evidence items
    - willing_to_pay: 1 no sign anyone spends money here; 3 people or businesses pay for nearby products; 5 buyers already pay for a worse product or name a budget
    - timing: 1 could have been built years ago; 3 recent tools make it easier; 5 a new capability, rule or price makes it possible or required now
    - gap: 1 well served by existing products; 3 options exist but leave a clear segment unhappy; 5 no credible option
    - fit: 1 needs skills or access the person lacks; 3 unknown or neutral; 5 uses their domain experience or access
    - buildability: 1 needs a team, hardware, regulated data or many deep integrations; 3 one person could build it \
    in 2-3 months; 5 one person with AI coding tools could ship a useful first version in 4 weeks
    - channel_score: 1 needs a sales team or cold outreach; 3 buyers are reachable but there is no obvious place they \
    look; 5 a named marketplace or community where these buyers already shop for tools like this
    Mark ideas down hard if there is no clear buyer who would pay, or no realistic way for it to make money. For \
    consumer ideas, also judge whether the channel reaches buyers without a large advertising budget.
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
    func critique(_ candidates: [Candidate], items: [FetchedItem], aboutMe: String) async throws -> [Review] {
        let data = try await llm.client.complete(system: Self.critiqueInstructions,
                                                 prompt: Self.critiquePrompt(candidates, items: items, aboutMe: aboutMe),
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
    static func critiquePrompt(_ candidates: [Candidate], items: [FetchedItem], aboutMe: String) -> String {
        var text = "About me: " + (aboutMe.isEmpty ? "(not provided)" : aboutMe) + "\n\nIdeas:"
        for c in candidates {
            text += "\n\nTitle: \(c.title)\nPitch: \(c.pitch)\nBuyer: \(c.buyer)\nPricing: \(c.pricing)"
            if !c.replaces.isEmpty { text += "\nReplaces: \(c.replaces)" }
            if !c.channel.isEmpty { text += "\nSales channel: \(c.channel)" }
            text += "\nWhy now: \(c.whyNow)\nOne-week test: \(c.oneWeekTest)"
            let evidence = Self.evidence(for: c, in: items)
            text += "\nEvidence:" + (evidence.isEmpty ? " (none cited)" : "")
            for item in evidence {
                let detail = item.detail.isEmpty ? "" : " — " + String(item.detail.prefix(200))
                text += "\n- [\(item.source.label)] \(item.title)\(detail)"
            }
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
                    ],
                    "required": ["title", "survives", "objection", "competitors", "verdict", "pain", "willing_to_pay",
                                 "timing", "gap", "fit", "buildability", "channel_score", "evidence_needed"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["reviews"],
        "additionalProperties": false,
    ]

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
                let buildability, channel_score: Int?
                let evidence_needed: String?
            }
            let reviews: [R]
        }
        return try JSONDecoder().decode(Out.self, from: try LLMSummarizer.extractJSON(data)).reviews.map {
            Review(title: $0.title, survives: $0.survives, objection: $0.objection, competitors: $0.competitors,
                   verdict: $0.verdict, pain: Ranking.clamp($0.pain), willingToPay: Ranking.clamp($0.willing_to_pay),
                   timing: Ranking.clamp($0.timing), gap: Ranking.clamp($0.gap), fit: Ranking.clamp($0.fit),
                   buildability: Ranking.clamp($0.buildability ?? 0), channelScore: Ranking.clamp($0.channel_score ?? 0),
                   evidenceNeeded: $0.evidence_needed ?? "")
        }
    }

    /// Pairs each candidate with its review and keeps ideas that survived and have no weak spot
    /// (any measure below 2), after capping scores the evidence doesn't support. Best first, at most three.
    /// - Parameters:
    ///   - candidates: The pass 1 ideas.
    ///   - reviews: The pass 2 reviews; a candidate with no matching review is dropped.
    ///   - items: The item list, to check each idea's evidence.
    /// - Returns: Up to `maxPerDay` results, highest killer score first.
    static func survivors(candidates: [Candidate], reviews: [Review], items: [FetchedItem] = []) -> [Result] {
        let byKey = Dictionary(reviews.map { (KillerIdea.key(for: $0.title), $0) }, uniquingKeysWith: { first, _ in first })
        return candidates.compactMap { candidate in
            guard let raw = byKey[KillerIdea.key(for: candidate.title)], raw.survives else { return nil }
            let review = capped(raw, evidence: evidence(for: candidate, in: items))
            guard [review.pain, review.willingToPay, review.timing, review.gap, review.fit,
                   review.buildability, review.channelScore].min() ?? 0 >= minimumSingleScore
            else { return nil }
            return Result(candidate: candidate, review: review)
        }
        .sorted { score($0.review) > score($1.review) }
        .prefix(maxPerDay)
        .map { $0 }
    }

    /// Sources that count as evidence of pain: complaints and the user's own business challenges.
    static let painEvidence: Set<SourceKind> = [.painPoints, .appReviews, .consumerReviews, .fieldNotes]
    /// Sources that count as evidence that people pay: complaints, funded startups, top paid apps, paid
    /// marketplace add-ons, government contracts.
    static let payEvidence: Set<SourceKind> = [.painPoints, .appReviews, .consumerReviews, .ycombinator, .appStore, .atlassian, .ausTender]

    /// Caps pain at 3 without pain evidence, and willingness to pay at 3 without pay evidence. Enforced
    /// in code rather than trusted to the prompt, because models tend to score generously.
    /// - Parameters:
    ///   - review: The critic's review.
    ///   - evidence: The items the idea cites.
    /// - Returns: The review with capped scores.
    static func capped(_ review: Review, evidence: [FetchedItem]) -> Review {
        var r = review
        let sources = Set(evidence.map(\.source))
        if sources.isDisjoint(with: painEvidence) { r.pain = min(r.pain, unprovenCap) }
        if sources.isDisjoint(with: payEvidence) { r.willingToPay = min(r.willingToPay, unprovenCap) }
        return r
    }

    /// The killer score of a review; the weighting lives in one place, on `KillerIdea`.
    /// - Parameter r: A review, normally already capped.
    /// - Returns: 0–5.
    static func score(_ r: Review) -> Double {
        KillerIdea.killerScore(pain: r.pain, willingToPay: r.willingToPay, timing: r.timing, gap: r.gap, fit: r.fit,
                               buildability: r.buildability, channel: r.channelScore)
    }
}
