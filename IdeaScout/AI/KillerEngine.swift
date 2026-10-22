// KillerEngine.swift
// The idea step of a refresh: two cloud AI calls. Pass 1 proposes 5 business ideas from the pain clusters,
// trends and items; pass 2 plays devil's advocate and scores them. Code then applies the evidence rules
// and keeps up to 3 survivors, which DigestService saves as KillerIdeas. Also the "flesh out" prompt
// for a killer idea.

import Foundation

/// Turns the trends and pain clusters into business product ideas, then has a second,
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
        var pitch: String
        var buyer: String
        var pricing: String
        var whyNow: String
        var oneWeekTest: String
        /// 1-based numbers of the items cited as evidence.
        var evidenceNumbers: [Int]
        /// The exact title of an existing leaderboard idea this repeats, or "" if new.
        var sameAs: String
        /// The manual task or costly workaround it replaces.
        var replaces = ""
    }

    /// The devil's advocate's verdict on one candidate. Scores are clamped to 0–5 when parsed.
    struct Review: Equatable, Sendable {
        var title: String
        /// Whether it's still worth a one-week test after the objections.
        var survives: Bool
        var objection: String
        var competitors: String
        var verdict: String
        /// How badly the buyer needs it (1–5). The other scores: willingness to pay, why now, gap, fit for the user.
        var pain: Int
        var willingToPay: Int
        var timing: Int
        var gap: Int
        var fit: Int
        /// The one fact that would most raise the score.
        var evidenceNeeded = ""
    }

    /// A surviving idea with its (evidence-capped) review.
    struct Result: Equatable, Sendable {
        var candidate: Candidate
        var review: Review
        /// Average of the five scores: the killer score.
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
    /// - Throws: Errors from either AI call or the parsers.
    /// - Note: `onCritique` is called between the two passes.
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

    /// Pass 1 instructions: business buyers only, at most 1 developer tool, at least 2 in the focus industry,
    /// each replacing a named manual task, with a one-week test. Field names must match `candidateSchema`.
    static let generateInstructions = """
    You are a sharp B2B product strategist hunting for a "killer" business software idea: one with real pain, \
    a specific business buyer with a budget, a reason it is possible now, a clear gap, and a good fit for the person described.
    Using the pain clusters, trends and numbered projects (items tagged Demand show need: "Pain points" are people \
    complaining or asking for tools that don't exist, "App Store complaints" are 1-2 star reviews of business apps \
    people pay for, "AusTender" is government IT spending, and "My business challenges" are the user's own observations from \
    work, which are strong evidence; "Y Combinator" are business startups investors just funded and "App Store top paid" are apps \
    people pay for, so both show what buyers already pay for; "AI research" shows new capabilities that explain why now), \
    propose 5 distinct product ideas. Rules:
    - The buyer must be a business: small and medium businesses are the main market (software they would pay \
    $20 to $500 a month for), plus larger companies in the focus industry. Never hobbyists or consumers.
    - At most 1 of the 5 may be a tool for software developers.
    - At least 2 of the 5 must be aimed at the focus industry given below.
    - Each must replace a named manual task, spreadsheet or costly workaround that the buyer does today.
    - Each must be a concrete product someone could start building this month, not a trend summary.
    Prefer ideas that solve a pain cluster and are supported by several projects. Cite at least one Demand item for each idea. Only propose ideas you would genuinely back; \
    quality matters more than variety.
    For each idea give: a short memorable title; a one-sentence pitch; the buyer (a specific role in a specific \
    type of business); pricing (model and price per customer per month); replaces (the manual task or workaround \
    it replaces and roughly what that costs the buyer today); why now (what recently became possible); a one-week \
    test (the cheapest way to check demand in 7 days, with a pass mark); the numbers of the projects that are \
    evidence for it; and same_as: if the idea is essentially the same as one on the existing leaderboard, copy \
    that title exactly, otherwise an empty string. Write everything in English.
    """ + Prompts.untrustedData

    /// Pass 1: asks for 5 candidate ideas (feature "Killer ideas", medium effort).
    /// - Throws: Errors from the AI call or the parser.
    func generate(_ context: Context) async throws -> [Candidate] {
        let data = try await llm.client.complete(system: Self.generateInstructions, prompt: Self.generatePrompt(context),
                                                 schema: Self.candidateSchema, effort: "medium", feature: "Killer ideas")
        return try Self.parseCandidates(data)
    }

    /// The pass 1 prompt: profile, focus industry, pain clusters, trends with variants, numbered items
    /// (160 characters of detail) and the existing leaderboard.
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
                        "replaces": ["type": "string"],
                        "evidence_numbers": ["type": "array", "items": ["type": "integer"]], "same_as": ["type": "string"],
                    ],
                    "required": ["title", "pitch", "buyer", "pricing", "why_now", "one_week_test", "replaces", "evidence_numbers", "same_as"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["ideas"],
        "additionalProperties": false,
    ]

    /// - Returns: The candidates. `replaces` is optional so replies from older prompts still parse.
    static func parseCandidates(_ data: Data) throws -> [Candidate] {
        struct Out: Decodable {
            struct I: Decodable {
                let title, pitch, buyer, pricing, why_now, one_week_test, same_as: String
                let replaces: String?
                let evidence_numbers: [Int]
            }
            let ideas: [I]
        }
        return try JSONDecoder().decode(Out.self, from: try LLMSummarizer.extractJSON(data)).ideas.map {
            Candidate(title: $0.title, pitch: $0.pitch, buyer: $0.buyer, pricing: $0.pricing, whyNow: $0.why_now,
                      oneWeekTest: $0.one_week_test, evidenceNumbers: $0.evidence_numbers, sameAs: $0.same_as,
                      replaces: $0.replaces ?? "")
        }
    }

    // MARK: - Pass 2: devil's advocate

    /// Pass 2 instructions: try to kill each idea using its evidence, with a defined meaning for every
    /// score level; no invented competitor prices. Field names must match `reviewSchema`.
    static let critiqueInstructions = """
    You are a blunt, experienced B2B investor playing devil's advocate. For each product idea, read its cited \
    evidence and try hard to kill it: name competitors you are confident exist, question whether the business buyer \
    really has a budget for it, and check whether the person described could realistically build and sell it. \
    Give a competitor's price only if you are sure of it; otherwise say "price unknown". Don't invent facts.
    Score each 1-5 (be strict; 5 is rare):
    - pain: 1 nice-to-have; 3 a recurring problem people work around; 5 costly and frequent, shown in 2 or more independent evidence items
    - willing_to_pay: 1 no sign anyone spends money here; 3 businesses pay for nearby tools; 5 buyers already pay for a worse product or name a budget
    - timing: 1 could have been built years ago; 3 recent tools make it easier; 5 a new capability, rule or price makes it possible or required now
    - gap: 1 well served by existing products; 3 options exist but leave a clear segment unhappy; 5 no credible option
    - fit: 1 needs skills or access the person lacks; 3 unknown or neutral; 5 uses their domain experience or access
    Mark ideas down hard if there is no clear business buyer with a budget, or if the buyer is a consumer or hobbyist.
    Judge whether the one-week test would really show demand. survives is true only if the idea is still worth \
    a one-week test after your objections. Give the single strongest objection, the main competitors (or "none found"), \
    a one-sentence verdict, and evidence_needed: the one fact that would most raise the score. Copy each title exactly. \
    Write everything in English.
    """ + Prompts.untrustedData

    /// Pass 2: the devil's advocate (feature "Devil's advocate"). Uses high effort because judging is where
    /// quality matters most.
    /// - Throws: Errors from the AI call or the parser.
    func critique(_ candidates: [Candidate], items: [FetchedItem], aboutMe: String) async throws -> [Review] {
        let data = try await llm.client.complete(system: Self.critiqueInstructions,
                                                 prompt: Self.critiquePrompt(candidates, items: items, aboutMe: aboutMe),
                                                 schema: Self.reviewSchema, effort: "high", feature: "Devil's advocate")
        return try Self.parseReviews(data)
    }

    /// The pass 2 prompt: each idea with its pitch, buyer, price, what it replaces, why now, one-week test
    /// and its cited evidence (200 characters each), so the critic can check claims.
    static func critiquePrompt(_ candidates: [Candidate], items: [FetchedItem], aboutMe: String) -> String {
        var text = "About me: " + (aboutMe.isEmpty ? "(not provided)" : aboutMe) + "\n\nIdeas:"
        for c in candidates {
            text += "\n\nTitle: \(c.title)\nPitch: \(c.pitch)\nBuyer: \(c.buyer)\nPricing: \(c.pricing)"
            if !c.replaces.isEmpty { text += "\nReplaces: \(c.replaces)" }
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
                        "evidence_needed": ["type": "string"],
                    ],
                    "required": ["title", "survives", "objection", "competitors", "verdict", "pain", "willing_to_pay",
                                 "timing", "gap", "fit", "evidence_needed"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["reviews"],
        "additionalProperties": false,
    ]

    /// - Returns: Reviews with every score clamped to 0–5.
    static func parseReviews(_ data: Data) throws -> [Review] {
        struct Out: Decodable {
            struct R: Decodable {
                let title, objection, competitors, verdict: String
                let survives: Bool
                let pain, willing_to_pay, timing, gap, fit: Int
                let evidence_needed: String?
            }
            let reviews: [R]
        }
        return try JSONDecoder().decode(Out.self, from: try LLMSummarizer.extractJSON(data)).reviews.map {
            Review(title: $0.title, survives: $0.survives, objection: $0.objection, competitors: $0.competitors,
                   verdict: $0.verdict, pain: Ranking.clamp($0.pain), willingToPay: Ranking.clamp($0.willing_to_pay),
                   timing: Ranking.clamp($0.timing), gap: Ranking.clamp($0.gap), fit: Ranking.clamp($0.fit),
                   evidenceNeeded: $0.evidence_needed ?? "")
        }
    }

    /// Pairs each candidate with its review and keeps ideas that survived and have no weak spot
    /// (any measure below 2), after capping scores the evidence doesn't support. Best first, at most three.
    static func survivors(candidates: [Candidate], reviews: [Review], items: [FetchedItem] = []) -> [Result] {
        let byKey = Dictionary(reviews.map { (KillerIdea.key(for: $0.title), $0) }, uniquingKeysWith: { first, _ in first })
        return candidates.compactMap { candidate in
            guard let raw = byKey[KillerIdea.key(for: candidate.title)], raw.survives else { return nil }
            let review = capped(raw, evidence: evidence(for: candidate, in: items))
            guard [review.pain, review.willingToPay, review.timing, review.gap, review.fit].min() ?? 0 >= minimumSingleScore
            else { return nil }
            return Result(candidate: candidate, review: review)
        }
        .sorted { score($0.review) > score($1.review) }
        .prefix(maxPerDay)
        .map { $0 }
    }

    /// Sources that count as evidence of pain: complaints and the user's own business challenges.
    static let painEvidence: Set<SourceKind> = [.painPoints, .appReviews, .fieldNotes]
    /// Sources that count as evidence that people pay: complaints, funded startups, top paid apps, government contracts.
    static let payEvidence: Set<SourceKind> = [.painPoints, .appReviews, .ycombinator, .appStore, .ausTender]

    /// Caps pain at 3 without pain evidence, and willingness to pay at 3 without pay evidence. Enforced
    /// in code rather than trusted to the prompt, because models tend to score generously.
    /// - Returns: The review with capped scores.
    static func capped(_ review: Review, evidence: [FetchedItem]) -> Review {
        var r = review
        let sources = Set(evidence.map(\.source))
        if sources.isDisjoint(with: painEvidence) { r.pain = min(r.pain, unprovenCap) }
        if sources.isDisjoint(with: payEvidence) { r.willingToPay = min(r.willingToPay, unprovenCap) }
        return r
    }

    /// The killer score: the average of the five scores.
    static func score(_ r: Review) -> Double { Double(r.pain + r.willingToPay + r.timing + r.gap + r.fit) / 5 }
}

extension Prompts {
    /// A ready-to-paste prompt to turn a killer idea into a full plan in another AI tool.
    static func fleshOut(_ idea: KillerIdea) -> String {
        var lines = ["Act as an experienced product strategist and help me turn this idea into a plan.", ""]
        lines += ["Idea: \(idea.title)", "Pitch: \(idea.pitch)", "Buyer: \(idea.buyer)", "Pricing: \(idea.pricing)",
                  "Why now: \(idea.whyNow)", "Strongest objection so far: \(idea.objection)",
                  "Known competitors: \(idea.competitors)"]
        if !idea.replaces.isEmpty { lines.insert("Replaces: \(idea.replaces)", at: lines.count - 2) }
        let about = AppSettings.aboutMe
        if !about.isEmpty { lines.append("About me: \(about)") }
        if !idea.evidenceTitles.isEmpty {
            lines.append("Evidence:")
            lines += idea.evidence.map { "- \($0.title)" + ($0.url.map { " (\($0.absoluteString))" } ?? "") }
        }
        lines += ["", "Please produce:",
                  "1. A sharper positioning statement and the single best first customer segment",
                  "2. MVP features for a first version I could build in 4–6 weeks",
                  "3. How to answer the strongest objection",
                  "4. A landing-page headline and three customer interview questions",
                  "5. Pricing, and what would have to be true to reach 100 paying customers",
                  "Be specific and practical."]
        return lines.joined(separator: "\n")
    }
}
