// DigestService+Ideas.swift
// The leaderboard side of a refresh: the top ideas sent to the idea step, and merging the step's survivors
// into saved ideas (a returning idea is updated and climbs the leaderboard).

import Foundation
import SwiftData

@MainActor
extension DigestService {
    /// The leaderboard's top ideas (including dismissed ones), best first. Sent to the idea step so a
    /// returning idea keeps its title.
    /// - Parameters:
    ///   - context: The database context.
    ///   - limit: How many to return.
    /// - Returns: Up to `limit` ideas, highest leaderboard score first; empty if the fetch fails.
    func topKillerIdeas(context: ModelContext, limit: Int) -> [KillerIdea] {
        let all = (try? context.fetch(FetchDescriptor<KillerIdea>())) ?? []
        return Array(all.sorted(by: KillerIdea.ranksAbove).prefix(limit))
    }

    /// Adds new killer ideas, or updates ones that came back (they climb the leaderboard). An idea matches an
    /// existing one by the AI's `same_as` title or by its own title. Coming back un-dismisses it and records the day,
    /// and the new text replaces any kept improvement.
    /// Two results with the same title in one batch become one idea (the later one updates the earlier), because the
    /// key is unique and a second insert would silently replace the first.
    func mergeKillerIdeas(_ results: [KillerEngine.Result], items: [FetchedItem], context: ModelContext) {
        // Only the ideas these results can match are loaded, not the whole history.
        let keys = Array(Set(results.flatMap { r in
            [KillerIdea.key(for: r.candidate.title), KillerIdea.key(for: r.candidate.sameAs)].filter { !$0.isEmpty }
        }))
        var all = (try? context.fetch(FetchDescriptor<KillerIdea>(predicate: #Predicate { keys.contains($0.key) }))) ?? []
        for result in results {
            let c = result.candidate, r = result.review
            let matchKey = KillerIdea.key(for: c.sameAs.isEmpty ? c.title : c.sameAs)
            let idea: KillerIdea
            if let existing = all.first(where: { $0.key == matchKey || $0.key == KillerIdea.key(for: c.title) }) {
                idea = existing
                if !Calendar.current.isDateInToday(existing.lastSeen) { idea.timesSeen += 1 }
            } else {
                idea = KillerIdea(key: KillerIdea.key(for: c.title), title: c.title)
                context.insert(idea)
                all.append(idea)
            }
            idea.pitch = c.pitch; idea.buyer = c.buyer; idea.pricing = c.pricing; idea.whyNow = c.whyNow
            idea.oneWeekTest = c.oneWeekTest; idea.replaces = c.replaces; idea.channel = c.channel
            idea.objection = r.objection; idea.competitors = r.competitors
            idea.verdict = r.evidenceNeeded.isEmpty ? r.verdict : "\(r.verdict) Evidence that would raise the score: \(r.evidenceNeeded)"
            idea.pain = r.pain; idea.willingToPay = r.willingToPay; idea.timing = r.timing; idea.gap = r.gap; idea.fit = r.fit
            idea.buildability = r.buildability; idea.channelScore = r.channelScore
            // The five principles: what they're worked out from.
            idea.engineVersion = 1
            idea.oneJob = c.oneJob; idea.keepFeatures = c.keepFeatures; idea.leaveOutFeatures = c.leaveOutFeatures
            idea.monthlyPrice = c.monthlyPrice; idea.fillsGap = c.fillsGap; idea.competitorList = result.competitors
            idea.buildDays = r.buildDays; idea.likelyCustomers = r.likelyCustomers; idea.builderToolRaw = result.tool.rawValue
            idea.followRisk = r.followRisk; idea.copyRisk = r.copyRisk; idea.keepPaying = r.keepPaying
            idea.criticRejected = !r.survives
            idea.payEvidenceCount = result.payEvidence
            idea.salesPlan = result.salesPlan; idea.appTypeRaw = result.appType.rawValue
            // The scan's new version replaces any kept improvement, so there's nothing left to undo.
            idea.improvedAt = nil
            idea.originalVersionJSON = ""
            idea.improvementJSON = ""   // its versions were scored for the old text, maybe on the older scale
            let evidence = c.evidenceNumbers.map { $0 - 1 }.filter { items.indices.contains($0) }.map { items[$0] }
            if !evidence.isEmpty {
                idea.evidenceTitles = evidence.map(\.title)
                idea.evidenceURLs = evidence.map(\.url.absoluteString)
            }
            idea.recordSeen(on: .now)
            idea.isDismissed = false   // proposed again, so it returns to the leaderboard
            idea.lastSeen = .now
            idea.scoreHistory.append(idea.killerScore)
        }
    }
}
