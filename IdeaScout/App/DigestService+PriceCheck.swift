// DigestService+PriceCheck.swift
// Step 5 of a refresh: the web price check on the day's kept ideas (at most 3), on Claude Haiku 5.5. Each idea gets
// a web search and a formatting call; the daily spending limit is checked before every paid call. A failure leaves
// the prices unconfirmed (as before the check existed) and adds one warning; it never stops the refresh.

import Foundation

@MainActor
extension DigestService {
    /// Checks each idea's competitor prices on the web, if a price checker is available.
    /// - Parameters:
    ///   - results: The kept ideas from the devil's advocate.
    ///   - onStart: Called when the check starts (shows the step in the progress row).
    /// - Returns: The ideas with confirmed prices where found, and a warning if the check stopped or failed.
    func checkPrices(_ results: [KillerEngine.Result],
                     onStart: () -> Void = {}) async -> (results: [KillerEngine.Result], warning: String?) {
        guard !results.isEmpty, let client = dependencies.priceChecker() else { return (results, nil) }
        onStart()
        var checked = results
        for index in checked.indices {
            do {
                if dependencies.isOverDailyCap() { throw SummarizerError.overDailyLimit }
                let r = checked[index]
                let reply = try await client.searchWeb(
                    system: PriceCheck.searchInstructions,
                    prompt: PriceCheck.searchPrompt(title: r.candidate.title, pitch: r.candidate.pitch, buyer: r.candidate.buyer,
                                                    known: r.competitors),
                    maxSearches: PriceCheck.maxSearches, feature: "Price check")
                guard !reply.sources.isEmpty else { continue }
                if dependencies.isOverDailyCap() { throw SummarizerError.overDailyLimit }
                let data = try await client.complete(system: PriceCheck.formatInstructions, prompt: PriceCheck.formatPrompt(reply),
                                                     schema: PriceCheck.formatSchema, effort: "low", feature: "Price check")
                let found = try PriceCheck.parse(data, sources: reply.sources)
                guard !found.isEmpty else { continue }
                checked[index].review.competitorsFound = PriceCheck.merge(existing: r.competitors, checked: found)
            } catch {
                if Self.isCancellation(error) || Task.isCancelled { return (checked, nil) }
                let failure = DigestWarning.describe(error)
                return (checked, DigestWarning.make("Some competitor prices weren't checked on the web: \(failure.message)",
                                                    details: failure.details))
            }
        }
        return (checked, nil)
    }
}
