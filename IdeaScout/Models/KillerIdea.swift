// KillerIdea.swift
// The saved killer idea (SwiftData) and its scoring: killer score, leaderboard order and days seen.
// Independent of digests, so it survives when the digest it came from is replaced or deleted.

import Foundation
import SwiftData

/// A money-making product idea proposed by the AI (shown as Killer, Near-miss or Rejected by the devil's advocate). Independent of digests.
/// Kept across days: when the same idea comes back, it's updated and climbs the leaderboard.
@Model final class KillerIdea {
    /// Normalised title (see `key(for:)`), so the same idea on another day updates this record.
    var key: String = ""
    /// Short, memorable name, as the AI wrote it.
    var title: String = ""
    /// One-sentence pitch.
    var pitch: String = ""
    /// Who pays: a role in a type of business, or a type of consumer.
    var buyer: String = ""
    /// Pricing model and monthly price per customer.
    var pricing: String = ""
    /// What recently made it possible.
    var whyNow: String = ""
    /// The cheapest way to test demand in a week, with a pass mark.
    var oneWeekTest: String = ""
    /// The manual task or costly workaround the product replaces.
    var replaces: String = ""
    /// Where a solo builder would find the first buyers (a marketplace, community or search phrase); empty
    /// for ideas found before sales channels were asked for.
    var channel: String = ""
    /// The devil's advocate's strongest objection.
    var objection: String = ""
    /// Competitors named by the devil's advocate, or "none found".
    var competitors: String = ""
    /// One-sentence verdict, plus "Evidence that would raise the score" when given.
    var verdict: String = ""
    /// Titles and links of the items cited as evidence (parallel arrays; SwiftData stores arrays of plain values).
    var evidenceTitles: [String] = []
    /// Links matching `evidenceTitles`, by position.
    var evidenceURLs: [String] = []
    // Scores 1–5 after the devil's-advocate review
    /// How badly the buyer needs it.
    var pain = 0
    /// How likely the buyer is to pay the stated price.
    var willingToPay = 0
    /// How strongly "why now" holds.
    var timing = 0
    /// How open the market is after competitors.
    var gap = 0
    /// How well it suits the user (from About me).
    var fit = 0
    /// Whether one person could build all of it with their AI coding tool (vibe-code it).
    /// 0 means not scored (ideas found before this score existed).
    var buildability = 0
    /// How reachable the buyers are through the sales channel without a sales team. 0 means not scored.
    var channelScore = 0
    /// The killer score each time the idea was proposed.
    var scoreHistory: [Double] = []
    /// When it was first proposed.
    var firstSeen: Date = Date.now
    /// When it was last proposed.
    var lastSeen: Date = Date.now
    /// On how many different days it was proposed (shown as "N days"; no ranking bonus since 13 Nov 2026).
    var timesSeen = 1
    /// Start of each day the idea was proposed.
    var daysSeen: [Date] = []
    /// Bookmarked by the user: listed in the Saved tab, and kept even if dismissed from the leaderboard.
    var isSaved = false
    /// When it was saved (Saved tab order), or `nil`.
    var savedAt: Date?
    /// Hidden from the leaderboard by the user. Cleared only if a later scan proposes it with evidence it didn't
    /// have before (owner's decision, 13 Nov 2026).
    var isDismissed = false
    /// It was dismissed, then came back because a scan cited new evidence; shown as "Back with new evidence" until
    /// the next scan that proposes it.
    var backWithNewEvidence = false
    /// The app the user named in "Reimagine an app" (first "Undercut an app", 13 Nov 2026; the stored name is
    /// permanent); empty for ideas from a daily scan. A later scan proposing the same idea leaves it set.
    var undercutApp: String = ""
    /// The starter kit as JSON (see `StarterKit` and `starterKit`), or empty when none has been made.
    var starterKitJSON: String = ""
    /// When the starter kit was made.
    var starterKitMadeAt: Date?
    /// The model ID that made the starter kit.
    var starterKitModel: String = ""
    /// The last "Improve this idea" run as JSON (see `IdeaImprover.Run` and `improvement`), or empty.
    var improvementJSON: String = ""
    /// The idea as it was before a kept improvement, as JSON (see `IdeaVersion`), for "Undo"; empty when not improved.
    var originalVersionJSON: String = ""
    /// When an improved version was kept; `nil` when the idea shows the AI's original.
    var improvedAt: Date?
    // Five principles (owner, 11 Nov 2026). Ideas found before have engineVersion 0 and keep their old score.
    /// 1 for ideas judged on the five principles; 0 for older ideas.
    var engineVersion = 0
    /// The one job the app does.
    var oneJob: String = ""
    /// Features to keep, compared with the competitors.
    var keepFeatures: [String] = []
    /// Features to leave out, compared with the competitors.
    var leaveOutFeatures: [String] = []
    /// Recommended price per customer per month, US dollars (0 = unknown).
    var monthlyPrice: Double = 0
    /// No app does this job yet.
    var fillsGap = false
    /// The competitors and their prices as JSON (see `Competitor` and `competitorList`).
    var competitorsJSON: String = ""
    /// Days one person would take to build it with their tool (the devil's advocate's estimate).
    var buildDays = 0
    /// Paying customers likely in the first year (the devil's advocate's estimate).
    var likelyCustomers = 0
    /// The tool the idea was judged for (`BuilderTool` raw value), for its build cost.
    var builderToolRaw: String = ""
    /// The devil's advocate's answers: would competitors follow, what stops copying, will customers keep paying.
    var followRisk: String = ""
    var copyRisk: String = ""
    var keepPaying: String = ""
    /// The devil's advocate judged it not worth a one-week test. Kept, labelled and ranked below the ideas it backed
    /// (owner's decision, 12 Nov 2026: only "not vibe-codable" drops an idea).
    var criticRejected = false
    /// How many cited items show people paying: with a paid competitor, the proof for "people will pay".
    var payEvidenceCount = 0
    /// How it's sold and what it costs to run, as JSON (see `SalesPlan` and `salesPlan`); empty for ideas judged before
    /// sales plans (owner, 12 Nov 2026), which keep the older build-cost-only payback until they come back.
    var salesPlanJSON: String = ""
    /// The kind of app it was judged as (`BuilderTool.AppType` raw value), for its yearly costs; empty uses the tool's.
    var appTypeRaw: String = ""

    /// Saves or unsaves the idea. The caller saves the database.
    func toggleSaved() {
        isSaved.toggle()
        savedAt = isSaved ? .now : nil
    }

    /// Creates an empty idea; DigestService fills in the rest from the AI's reply.
    /// - Parameters:
    ///   - key: `KillerIdea.key(for: title)`, so the same idea matches across days and devices.
    ///   - title: The AI's title.
    init(key: String, title: String) {
        self.key = key
        self.title = title
        pitch = ""; buyer = ""; pricing = ""; whyNow = ""; oneWeekTest = ""
        objection = ""; competitors = ""; verdict = ""
        firstSeen = .now
        lastSeen = .now
    }

    /// The killer score: the average of the five principles, or the older weighted score for older ideas.
    var killerScore: Double {
        engineVersion >= 1 ? FiveTests.score(principles)
            : Self.killerScore(pain: pain, willingToPay: willingToPay, timing: timing, gap: gap, fit: fit,
                               buildability: buildability, channel: channelScore)
    }

    /// The tool the idea was judged for.
    var builderTool: BuilderTool { BuilderTool(rawValue: builderToolRaw) ?? .claudeCode }

    /// The kind of app it was judged as.
    var appType: BuilderTool.AppType { BuilderTool.AppType(rawValue: appTypeRaw) ?? builderTool.defaultAppType }

    /// How it's sold and what it costs to run, or `nil` for ideas judged before sales plans.
    var salesPlan: SalesPlan? {
        get { Self.decode(salesPlanJSON) }
        set { salesPlanJSON = Self.encode(newValue) }
    }

    /// The price as the customer sees it: "$24 once" or "$3 a month".
    var priceText: String {
        PaybackSums.priceText(salesPlan?.model ?? .subscription, monthlyPrice: monthlyPrice)
    }

    /// The five principles, worked out from the stored scores and prices (empty for older ideas).
    var principles: [TestOutcome] {
        guard engineVersion >= 1 else { return [] }
        return FiveTests.outcomes(
            vibeCodable: buildability,
            willPay: FiveTests.willPay(score: willingToPay, competitors: competitorList, payEvidence: payEvidenceCount),
            pain: pain,
            cheaper: FiveTests.cheaper(price: monthlyPrice, competitors: competitorList, fillsGap: fillsGap),
            coversBuild: salesPlan.map {
                PaybackSums.coversBuild(plan: $0, monthlyPrice: monthlyPrice, customers: likelyCustomers, buildDays: buildDays,
                                        tool: builderTool, channelScore: channelScore)
            } ?? FiveTests.coversBuild(buildDays: buildDays, customers: likelyCustomers, price: monthlyPrice,
                                       tool: builderTool, channelScore: channelScore))
    }

    /// The competitors and their prices.
    var competitorList: [Competitor] {
        get { Self.decode(competitorsJSON) ?? [] }
        set { competitorsJSON = newValue.isEmpty ? "" : Self.encode(newValue) }
    }

    /// "Why now" counts half as much as the other scores: for a solo builder using AI tools, "AI makes it
    /// cheap to build" is true of almost every idea, so timing separates ideas less than buildability or a sales channel.
    static let timingWeight = 0.5

    /// The killer score: the single source of the weighting, used by `KillerEngine` and on screen.
    /// - Parameters:
    ///   - pain: 0–5, how painful the problem is.
    ///   - willingToPay: 0–5, evidence that buyers would pay.
    ///   - timing: 0–5, "why now"; weighted by `timingWeight`.
    ///   - gap: 0–5, how poorly existing products serve the need.
    ///   - fit: 0–5, how well it uses the user's skills, domain experience and access.
    ///   - buildability: 0–5; 0 together with `channel` 0 means an older idea scored before these existed.
    ///   - channel: 0–5, the sales-channel score.
    /// - Returns: 0–5. Older ideas keep their original score (the plain average of the first five), so they
    ///   aren't marked down for scores they were never given.
    static func killerScore(pain: Int, willingToPay: Int, timing: Int, gap: Int, fit: Int,
                            buildability: Int, channel: Int) -> Double {
        guard buildability > 0 || channel > 0 else { return Double(pain + willingToPay + timing + gap + fit) / 5 }
        let total = Double(pain + willingToPay + gap + fit + buildability + channel) + Double(timing) * timingWeight
        return total / (6 + timingWeight)
    }

    /// Leaderboard order: ideas judged on the five principles first (owner's default, 11 Nov 2026: older ideas rank
    /// below new ones until they come back), then ideas the devil's advocate backed before ones it rejected (owner,
    /// 12 Nov 2026), then by killer score. Coming back on more days earns no bonus (owner, 13 Nov 2026), so a
    /// returning idea can't push a stronger new one down.
    static func ranksAbove(_ a: KillerIdea, _ b: KillerIdea) -> Bool {
        if a.engineVersion != b.engineVersion { return a.engineVersion > b.engineVersion }
        if a.criticRejected != b.criticRejected { return !a.criticRejected }
        return a.killerScore > b.killerScore
    }

    /// Whether a dismissed idea may come back: only if the scan cites evidence it didn't have before.
    /// - Parameters:
    ///   - saved: The dismissed idea's evidence links.
    ///   - cited: The links the new proposal cites.
    /// - Returns: `true` if any cited link is new.
    static func returnsFromDismissal(saved: [String], cited: [String]) -> Bool { !Set(cited).subtracting(saved).isEmpty }

    /// Whether the idea was proposed on the given day. Ideas saved before days were recorded
    /// fall back to their first and last day.
    /// - Parameter day: Any moment in the day to check, in the phone's calendar.
    /// - Returns: `true` if it was proposed that day.
    func wasSeen(on day: Date) -> Bool {
        let calendar = Calendar.current
        if !daysSeen.isEmpty { return daysSeen.contains { calendar.isDate($0, inSameDayAs: day) } }
        return calendar.isDate(firstSeen, inSameDayAs: day) || calendar.isDate(lastSeen, inSameDayAs: day)
    }

    /// Adds the day (once) to the days this idea was seen.
    func recordSeen(on date: Date = .now) {
        let day = Calendar.current.startOfDay(for: date)
        if daysSeen.isEmpty {
            // Carry over what's known from before days were recorded (call before updating lastSeen).
            daysSeen = Array(Set([firstSeen, lastSeen].map { Calendar.current.startOfDay(for: $0) })).sorted()
        }
        if !daysSeen.contains(day) { daysSeen.append(day) }
    }

    /// Ideas proposed on a given day, best first.
    /// - Parameters:
    ///   - day: Any moment in the day.
    ///   - ideas: The ideas to filter.
    /// - Returns: The matching ideas in leaderboard order (`ranksAbove`).
    static func seen(on day: Date, in ideas: [KillerIdea]) -> [KillerIdea] {
        ideas.filter { $0.wasSeen(on: day) }.sorted(by: ranksAbove)
    }

    /// The evidence as title and link pairs.
    var evidence: [(title: String, url: URL?)] {
        zip(evidenceTitles, evidenceURLs).map { ($0, URL(string: $1)) }
    }

    /// Normalised key so the same idea matches across days: lowercase letters and digits only.
    /// - Parameter title: The AI's title.
    /// - Returns: The key; empty if the title has no letters or digits.
    static func key(for title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The last improvement run, if any.
    var improvement: IdeaImprover.Run? {
        get { Self.decode(improvementJSON) }
        set { improvementJSON = Self.encode(newValue) }
    }

    /// The idea before a kept improvement, if any.
    var originalVersion: IdeaVersion? {
        get { Self.decode(originalVersionJSON) }
        set { originalVersionJSON = Self.encode(newValue) }
    }

    private static func decode<T: Decodable>(_ json: String) -> T? {
        json.isEmpty ? nil : try? JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private static func encode<T: Encodable>(_ value: T?) -> String {
        value.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
