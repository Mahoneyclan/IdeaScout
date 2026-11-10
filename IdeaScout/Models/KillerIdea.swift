// KillerIdea.swift
// The saved killer idea (SwiftData) and its scoring: killer score, leaderboard bonus and days seen.
// Independent of digests, so it survives when the digest it came from is replaced or deleted.

import Foundation
import SwiftData

/// A business product idea proposed by the AI that survived the devil's-advocate check (shown as Killer or
/// Near-miss). Independent of digests.
/// Kept across days: when the same idea comes back, it's updated and climbs the leaderboard.
@Model final class KillerIdea {
    /// Normalised title (see `key(for:)`), so the same idea on another day updates this record.
    @Attribute(.unique) var key: String
    /// Short, memorable name, as the AI wrote it.
    var title: String
    /// One-sentence pitch.
    var pitch: String
    /// Who pays: a role in a type of business.
    var buyer: String
    /// Pricing model and monthly price per customer.
    var pricing: String
    /// What recently made it possible.
    var whyNow: String
    /// The cheapest way to test demand in a week, with a pass mark.
    var oneWeekTest: String
    /// The manual task or costly workaround the product replaces.
    var replaces: String = ""
    /// Where a solo builder would find the first buyers (a marketplace, community or search phrase); empty
    /// for ideas found before sales channels were asked for.
    var channel: String = ""
    /// The devil's advocate's strongest objection.
    var objection: String
    /// Competitors named by the devil's advocate, or "none found".
    var competitors: String
    /// One-sentence verdict, plus "Evidence that would raise the score" when given.
    var verdict: String
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
    /// Whether one person with AI coding tools could build a first version in about 4 weeks.
    /// 0 means not scored (ideas found before this score existed).
    var buildability = 0
    /// How reachable the buyers are through the sales channel without a sales team. 0 means not scored.
    var channelScore = 0
    /// The killer score each time the idea was proposed.
    var scoreHistory: [Double] = []
    /// When it was first proposed.
    var firstSeen: Date
    /// When it was last proposed.
    var lastSeen: Date
    /// On how many different days it was proposed; adds a leaderboard bonus.
    var timesSeen = 1
    /// Start of each day the idea was proposed.
    var daysSeen: [Date] = []
    /// Bookmarked by the user: listed in the Saved tab, and kept even if dismissed from the leaderboard.
    var isSaved = false
    /// When it was saved (Saved tab order), or `nil`.
    var savedAt: Date?
    /// Hidden from the leaderboard by the user. Cleared if the idea is proposed again.
    var isDismissed = false
    /// The starter kit as JSON (see `StarterKit` and `starterKit`), or empty when none has been made.
    var starterKitJSON: String = ""
    /// When the starter kit was made.
    var starterKitMadeAt: Date?
    /// The model ID that made the starter kit.
    var starterKitModel: String = ""

    /// Saves or unsaves the idea. The caller saves the database.
    func toggleSaved() {
        isSaved.toggle()
        savedAt = isSaved ? .now : nil
    }

    /// Creates an empty idea; DigestService fills in the rest from the AI's reply.
    /// - Parameters:
    ///   - key: `KillerIdea.key(for: title)`; unique, so the same idea matches across days.
    ///   - title: The AI's title.
    init(key: String, title: String) {
        self.key = key
        self.title = title
        pitch = ""; buyer = ""; pricing = ""; whyNow = ""; oneWeekTest = ""
        objection = ""; competitors = ""; verdict = ""
        firstSeen = .now
        lastSeen = .now
    }

    /// The weighted killer score of the review scores.
    var killerScore: Double {
        Self.killerScore(pain: pain, willingToPay: willingToPay, timing: timing, gap: gap, fit: fit,
                         buildability: buildability, channel: channelScore)
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

    /// Killer score plus a bonus for coming back on several days (up to +0.6).
    var leaderboardScore: Double { Self.leaderboardScore(killer: killerScore, timesSeen: timesSeen) }

    /// +0.15 for each extra day it was proposed, up to 4 extra days (+0.6), so ideas that keep coming
    /// back rise without outranking a clearly stronger idea.
    /// - Parameters:
    ///   - killer: The killer score (0–5).
    ///   - timesSeen: Days it has been proposed (1 or more).
    /// - Returns: The leaderboard score (0–5.6).
    static func leaderboardScore(killer: Double, timesSeen: Int) -> Double {
        killer + Double(min(max(timesSeen - 1, 0), 4)) * 0.15
    }

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
    /// - Returns: The matching ideas, highest killer score first.
    static func seen(on day: Date, in ideas: [KillerIdea]) -> [KillerIdea] {
        ideas.filter { $0.wasSeen(on: day) }.sorted { $0.killerScore > $1.killerScore }
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
}
