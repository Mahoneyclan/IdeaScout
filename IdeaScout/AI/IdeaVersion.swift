// IdeaVersion.swift
// One version of an idea for "Improve this idea": its text, the devil's advocate's review and the offer the five
// principles are worked out from, stored as JSON on KillerIdea. Split from IdeaImprover.swift, which keeps the run's
// rules and prompts.

import Foundation

/// One version of an idea: its text and the devil's advocate's review of it. Stored as JSON on `KillerIdea`.
struct IdeaVersion: Codable, Equatable, Sendable {
    var pitch, buyer, pricing, whyNow, oneWeekTest, replaces, channel: String
    /// What the rewrite changed and why, in one or two sentences; empty for the original.
    var changes = ""
    var survives = true
    var objection, competitors, verdict: String
    var evidenceNeeded = ""
    var pain, willingToPay, timing, gap, fit, buildability, channelScore: Int
    /// What the five principles are worked out from; `nil` for ideas found before them (and runs saved before).
    var offer: Offer?

    /// The job, features, prices and estimates behind the five principles.
    struct Offer: Codable, Equatable, Sendable {
        var oneJob = ""
        var keepFeatures: [String] = []
        var leaveOutFeatures: [String] = []
        var monthlyPrice: Double = 0
        var fillsGap = false
        var competitors: [Competitor] = []
        var buildDays = 0
        var likelyCustomers = 0
        var toolRaw = BuilderTool.claudeCode.rawValue
        var followRisk = ""
        var copyRisk = ""
        var keepPaying = ""
        /// Cited items that show people paying; a rewrite adds no evidence, so this is carried over unchanged.
        var payEvidence = 0
        /// How it's sold and what it costs to run; `nil` for ideas judged before sales plans.
        var salesPlan: SalesPlan?
        /// The kind of app (`BuilderTool.AppType` raw value); empty uses the tool's.
        var appTypeRaw = ""

        init(oneJob: String = "", keepFeatures: [String] = [], leaveOutFeatures: [String] = [], monthlyPrice: Double = 0,
             fillsGap: Bool = false, competitors: [Competitor] = [], buildDays: Int = 0, likelyCustomers: Int = 0,
             toolRaw: String = BuilderTool.claudeCode.rawValue, followRisk: String = "", copyRisk: String = "",
             keepPaying: String = "", payEvidence: Int = 0, salesPlan: SalesPlan? = nil, appTypeRaw: String = "") {
            self.oneJob = oneJob; self.keepFeatures = keepFeatures; self.leaveOutFeatures = leaveOutFeatures
            self.monthlyPrice = monthlyPrice; self.fillsGap = fillsGap; self.competitors = competitors
            self.buildDays = buildDays; self.likelyCustomers = likelyCustomers; self.toolRaw = toolRaw
            self.followRisk = followRisk; self.copyRisk = copyRisk; self.keepPaying = keepPaying
            self.payEvidence = payEvidence; self.salesPlan = salesPlan; self.appTypeRaw = appTypeRaw
        }

        /// Tolerant decoding: keys added later may be missing from runs saved earlier (stored data is permanent).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(oneJob: try c.decodeIfPresent(String.self, forKey: .oneJob) ?? "",
                      keepFeatures: try c.decodeIfPresent([String].self, forKey: .keepFeatures) ?? [],
                      leaveOutFeatures: try c.decodeIfPresent([String].self, forKey: .leaveOutFeatures) ?? [],
                      monthlyPrice: try c.decodeIfPresent(Double.self, forKey: .monthlyPrice) ?? 0,
                      fillsGap: try c.decodeIfPresent(Bool.self, forKey: .fillsGap) ?? false,
                      competitors: try c.decodeIfPresent([Competitor].self, forKey: .competitors) ?? [],
                      buildDays: try c.decodeIfPresent(Int.self, forKey: .buildDays) ?? 0,
                      likelyCustomers: try c.decodeIfPresent(Int.self, forKey: .likelyCustomers) ?? 0,
                      toolRaw: try c.decodeIfPresent(String.self, forKey: .toolRaw) ?? BuilderTool.claudeCode.rawValue,
                      followRisk: try c.decodeIfPresent(String.self, forKey: .followRisk) ?? "",
                      copyRisk: try c.decodeIfPresent(String.self, forKey: .copyRisk) ?? "",
                      keepPaying: try c.decodeIfPresent(String.self, forKey: .keepPaying) ?? "",
                      payEvidence: try c.decodeIfPresent(Int.self, forKey: .payEvidence) ?? 0,
                      salesPlan: try c.decodeIfPresent(SalesPlan.self, forKey: .salesPlan),
                      appTypeRaw: try c.decodeIfPresent(String.self, forKey: .appTypeRaw) ?? "")
        }
    }

    /// The five principles; empty for older ideas.
    var principles: [TestOutcome] {
        guard let offer else { return [] }
        let tool = BuilderTool(rawValue: offer.toolRaw) ?? .claudeCode
        return KillerEngine.outcomes(
            review: KillerEngine.Review(title: "", survives: survives, objection: "", competitors: "", verdict: "",
                                        pain: pain, willingToPay: willingToPay, timing: timing, gap: gap, fit: fit,
                                        buildability: buildability, channelScore: channelScore,
                                        buildDays: offer.buildDays, likelyCustomers: offer.likelyCustomers),
            price: offer.monthlyPrice, competitors: offer.competitors,
            tool: tool, payEvidence: offer.payEvidence, salesPlan: offer.salesPlan)
    }

    /// The killer score: the five principles' average, or the older weighted score for older ideas.
    var score: Double {
        offer == nil
            ? KillerIdea.killerScore(pain: pain, willingToPay: willingToPay, timing: timing, gap: gap, fit: fit,
                                     buildability: buildability, channel: channelScore)
            : FiveTests.score(principles)
    }

    /// Whether it can be kept: vibe-codable for ideas judged on the five principles (a version the devil's advocate
    /// rejected can still be kept, labelled and ranked low; owner, 12 Nov 2026); for older ideas, the devil's advocate
    /// kept it and it has no weak spot (the daily scan's rule then).
    var passes: Bool {
        if offer != nil { return buildability >= FiveTests.minimumVibeCodable }
        guard survives else { return false }
        return [pain, willingToPay, timing, gap, fit, buildability, channelScore].min() ?? 0 >= KillerEngine.minimumSingleScore
    }
}

extension IdeaVersion {
    /// The idea as it stands now. The saved verdict may end with "Evidence that would raise the score: …", which
    /// is split back out so the rewrite can answer it.
    init(_ idea: KillerIdea) {
        let marker = " Evidence that would raise the score: "
        let parts = idea.verdict.components(separatedBy: marker)
        self.init(pitch: idea.pitch, buyer: idea.buyer, pricing: idea.pricing, whyNow: idea.whyNow,
                  oneWeekTest: idea.oneWeekTest, replaces: idea.replaces, channel: idea.channel,
                  survives: !idea.criticRejected, objection: idea.objection, competitors: idea.competitors, verdict: parts[0],
                  evidenceNeeded: parts.count > 1 ? parts.dropFirst().joined(separator: marker) : "",
                  pain: idea.pain, willingToPay: idea.willingToPay, timing: idea.timing, gap: idea.gap, fit: idea.fit,
                  buildability: idea.buildability, channelScore: idea.channelScore,
                  offer: idea.engineVersion >= 1 ? Offer(
                    oneJob: idea.oneJob, keepFeatures: idea.keepFeatures, leaveOutFeatures: idea.leaveOutFeatures,
                    monthlyPrice: idea.monthlyPrice, fillsGap: idea.fillsGap, competitors: idea.competitorList,
                    buildDays: idea.buildDays, likelyCustomers: idea.likelyCustomers, toolRaw: idea.builderTool.rawValue,
                    followRisk: idea.followRisk, copyRisk: idea.copyRisk, keepPaying: idea.keepPaying,
                    payEvidence: idea.payEvidenceCount, salesPlan: idea.salesPlan, appTypeRaw: idea.appTypeRaw) : nil)
    }

    /// Whether this version is the one the idea uses now: the original until a version is kept, then the kept
    /// version (matched by its text, since a kept version's text is copied onto the idea).
    /// - Parameters:
    ///   - idea: The idea.
    ///   - isOriginal: Whether this is the run's first version (the idea before improving).
    /// - Returns: `true` if the idea shows this version.
    func isInUse(by idea: KillerIdea, isOriginal: Bool) -> Bool {
        if isOriginal { return idea.improvedAt == nil }
        return idea.improvedAt != nil && pitch == idea.pitch && buyer == idea.buyer && pricing == idea.pricing
    }

    /// Copies this version's text and scores onto the idea (the title, evidence and history stay).
    func apply(to idea: KillerIdea) {
        idea.pitch = pitch; idea.buyer = buyer; idea.pricing = pricing; idea.whyNow = whyNow
        idea.oneWeekTest = oneWeekTest; idea.replaces = replaces; idea.channel = channel
        idea.objection = objection; idea.competitors = competitors
        idea.verdict = evidenceNeeded.isEmpty ? verdict : "\(verdict) Evidence that would raise the score: \(evidenceNeeded)"
        idea.pain = pain; idea.willingToPay = willingToPay; idea.timing = timing; idea.gap = gap; idea.fit = fit
        idea.buildability = buildability; idea.channelScore = channelScore
        if let offer {
            idea.oneJob = offer.oneJob; idea.keepFeatures = offer.keepFeatures; idea.leaveOutFeatures = offer.leaveOutFeatures
            idea.monthlyPrice = offer.monthlyPrice; idea.fillsGap = offer.fillsGap; idea.competitorList = offer.competitors
            idea.buildDays = offer.buildDays; idea.likelyCustomers = offer.likelyCustomers; idea.builderToolRaw = offer.toolRaw
            idea.followRisk = offer.followRisk; idea.copyRisk = offer.copyRisk; idea.keepPaying = offer.keepPaying
            idea.criticRejected = !survives
            idea.salesPlan = offer.salesPlan; idea.appTypeRaw = offer.appTypeRaw
        }
    }

    /// Takes the devil's advocate's review of this version's text.
    func reviewed(by r: KillerEngine.Review) -> IdeaVersion {
        var v = self
        v.survives = r.survives; v.objection = r.objection; v.competitors = r.competitors; v.verdict = r.verdict
        v.evidenceNeeded = r.evidenceNeeded
        v.pain = r.pain; v.willingToPay = r.willingToPay; v.timing = r.timing; v.gap = r.gap; v.fit = r.fit
        v.buildability = r.buildability; v.channelScore = r.channelScore
        if var offer = v.offer {
            offer.buildDays = r.buildDays; offer.likelyCustomers = r.likelyCustomers
            if !r.competitorsFound.isEmpty { offer.competitors = r.competitorsFound }
            offer.followRisk = r.followRisk; offer.copyRisk = r.copyRisk; offer.keepPaying = r.keepPaying
            if let plan = r.salesPlan { offer.salesPlan = plan }
            v.offer = offer
        }
        return v
    }
}
