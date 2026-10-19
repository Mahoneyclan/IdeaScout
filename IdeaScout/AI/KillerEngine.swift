import Foundation

/// Turns the week's trends into one or two "killer" product ideas, then has a second,
/// sceptical pass try to kill them. Only ideas that survive are kept. Needs Claude:
/// Apple's on-device model is too small for this kind of reasoning.
struct KillerEngine {
    let claude: ClaudeSummarizer

    struct Candidate: Equatable, Sendable {
        var title: String
        var pitch: String
        var buyer: String
        var pricing: String
        var whyNow: String
        var oneWeekTest: String
        var evidenceNumbers: [Int]
        var sameAs: String
    }

    struct Review: Equatable, Sendable {
        var title: String
        var survives: Bool
        var objection: String
        var competitors: String
        var verdict: String
        var pain: Int
        var willingToPay: Int
        var timing: Int
        var gap: Int
        var fit: Int
    }

    struct Result: Equatable, Sendable {
        var candidate: Candidate
        var review: Review
    }

    /// Context passed in from the digest: the trends found, the numbered items, the user's profile
    /// and the current leaderboard (so a returning idea reuses its title).
    struct Context: Sendable {
        var themes: [ThemeBuilder.Built]
        var items: [FetchedItem]
        var aboutMe: String
        var leaderboard: [String]
    }

    func run(_ context: Context) async throws -> [Result] {
        let candidates = try await generate(context)
        guard !candidates.isEmpty else { return [] }
        let reviews = try await critique(candidates, aboutMe: context.aboutMe)
        return Self.survivors(candidates: candidates, reviews: reviews)
    }

    // MARK: - Pass 1: generate

    static let generateInstructions = """
    You are a sharp product strategist hunting for a "killer" product idea: one with real pain, a specific \
    buyer who will pay, a reason it is possible now, a clear gap, and a good fit for the person described.
    Using the trends and numbered projects (projects tagged "Pain points" are people asking for tools that \
    don't exist), propose 3 distinct product ideas. Each must be a concrete product someone could start \
    building this month, not a trend summary. Prefer ideas supported by several projects and by pain points.
    For each idea give: a short memorable title; a one-sentence pitch; the buyer (a specific type of person \
    or company); pricing (model and rough price); why now (what recently became possible); a one-week test \
    (the cheapest way to check demand in 7 days); the numbers of the projects that are evidence for it; and \
    same_as: if the idea is essentially the same as one on the existing leaderboard, copy that title exactly, \
    otherwise an empty string. Write everything in English.
    """

    func generate(_ context: Context) async throws -> [Candidate] {
        let body = ClaudeSummarizer.requestBody(system: Self.generateInstructions, prompt: Self.generatePrompt(context),
                                                schema: Self.candidateSchema)
        return try Self.parseCandidates(try await claude.send(body, feature: "Killer ideas"))
    }

    static func generatePrompt(_ context: Context) -> String {
        var parts: [String] = []
        parts.append("About me: " + (context.aboutMe.isEmpty ? "(not provided)" : context.aboutMe))
        let trends = context.themes.filter { !$0.isCatchAll }.map { theme in
            "- \(theme.title): \(theme.summary)" + (theme.opportunities.isEmpty ? "" : " Variants: " + theme.opportunities.joined(separator: " | "))
        }
        parts.append("Trends this week:\n" + trends.joined(separator: "\n"))
        parts.append("Projects:\n" + Prompts.itemList(context.items, detailLimit: 160))
        parts.append("Existing leaderboard:\n" + (context.leaderboard.isEmpty ? "(empty)" : context.leaderboard.map { "- \($0)" }.joined(separator: "\n")))
        return parts.joined(separator: "\n\n")
    }

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
                        "evidence_numbers": ["type": "array", "items": ["type": "integer"]], "same_as": ["type": "string"],
                    ],
                    "required": ["title", "pitch", "buyer", "pricing", "why_now", "one_week_test", "evidence_numbers", "same_as"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["ideas"],
        "additionalProperties": false,
    ]

    static func parseCandidates(_ data: Data) throws -> [Candidate] {
        struct Out: Decodable {
            struct I: Decodable {
                let title, pitch, buyer, pricing, why_now, one_week_test, same_as: String
                let evidence_numbers: [Int]
            }
            let ideas: [I]
        }
        return try JSONDecoder().decode(Out.self, from: try ClaudeSummarizer.extractJSON(data)).ideas.map {
            Candidate(title: $0.title, pitch: $0.pitch, buyer: $0.buyer, pricing: $0.pricing, whyNow: $0.why_now,
                      oneWeekTest: $0.one_week_test, evidenceNumbers: $0.evidence_numbers, sameAs: $0.same_as)
        }
    }

    // MARK: - Pass 2: devil's advocate

    static let critiqueInstructions = """
    You are a blunt, experienced investor playing devil's advocate. For each product idea, try hard to kill it: \
    name existing competitors, question whether the buyer would really pay, and check whether the person \
    described could realistically build and sell it. Then score each 1-5 (be strict; 5 is rare):
    - pain: how badly the buyer needs this
    - willing_to_pay: how likely they are to pay the stated price
    - timing: how strongly "why now" holds
    - gap: how open the market is after considering competitors
    - fit: how well it suits the person described (3 if nothing is known about them)
    survives is true only if the idea is still worth a one-week test after your objections. Give the single \
    strongest objection, the main competitors (or "none found"), and a one-sentence verdict. Copy each title exactly. \
    Write everything in English.
    """

    func critique(_ candidates: [Candidate], aboutMe: String) async throws -> [Review] {
        let body = ClaudeSummarizer.requestBody(system: Self.critiqueInstructions,
                                                prompt: Self.critiquePrompt(candidates, aboutMe: aboutMe),
                                                schema: Self.reviewSchema)
        return try Self.parseReviews(try await claude.send(body, feature: "Devil's advocate"))
    }

    static func critiquePrompt(_ candidates: [Candidate], aboutMe: String) -> String {
        var text = "About me: " + (aboutMe.isEmpty ? "(not provided)" : aboutMe) + "\n\nIdeas:"
        for c in candidates {
            text += "\n\nTitle: \(c.title)\nPitch: \(c.pitch)\nBuyer: \(c.buyer)\nPricing: \(c.pricing)\nWhy now: \(c.whyNow)"
        }
        return text
    }

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
                    ],
                    "required": ["title", "survives", "objection", "competitors", "verdict", "pain", "willing_to_pay",
                                 "timing", "gap", "fit"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["reviews"],
        "additionalProperties": false,
    ]

    static func parseReviews(_ data: Data) throws -> [Review] {
        struct Out: Decodable {
            struct R: Decodable {
                let title, objection, competitors, verdict: String
                let survives: Bool
                let pain, willing_to_pay, timing, gap, fit: Int
            }
            let reviews: [R]
        }
        return try JSONDecoder().decode(Out.self, from: try ClaudeSummarizer.extractJSON(data)).reviews.map {
            Review(title: $0.title, survives: $0.survives, objection: $0.objection, competitors: $0.competitors,
                   verdict: $0.verdict, pain: Ranking.clamp($0.pain), willingToPay: Ranking.clamp($0.willing_to_pay),
                   timing: Ranking.clamp($0.timing), gap: Ranking.clamp($0.gap), fit: Ranking.clamp($0.fit))
        }
    }

    /// Pairs each candidate with its review, keeps survivors, best first, at most two.
    static func survivors(candidates: [Candidate], reviews: [Review]) -> [Result] {
        let byKey = Dictionary(reviews.map { (KillerIdea.key(for: $0.title), $0) }, uniquingKeysWith: { first, _ in first })
        return candidates.compactMap { candidate in
            guard let review = byKey[KillerIdea.key(for: candidate.title)], review.survives else { return nil }
            return Result(candidate: candidate, review: review)
        }
        .sorted { score($0.review) > score($1.review) }
        .prefix(2)
        .map { $0 }
    }

    static func score(_ r: Review) -> Double { Double(r.pain + r.willingToPay + r.timing + r.gap + r.fit) / 5 }
}

extension Prompts {
    /// A ready-to-paste prompt to turn a killer idea into a full plan in another AI tool.
    static func fleshOut(_ idea: KillerIdea) -> String {
        var lines = ["Act as an experienced product strategist and help me turn this idea into a plan.", ""]
        lines += ["Idea: \(idea.title)", "Pitch: \(idea.pitch)", "Buyer: \(idea.buyer)", "Pricing: \(idea.pricing)",
                  "Why now: \(idea.whyNow)", "Strongest objection so far: \(idea.objection)",
                  "Known competitors: \(idea.competitors)"]
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
