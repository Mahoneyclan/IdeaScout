// DigestService+Undercut.swift
// "Undercut an app" on demand, never part of a refresh: web research on the named app (Claude Haiku with web search,
// kept off Apple's sites), then the usual idea step and devil's advocate with that research as evidence, then the
// web price check; the best idea is saved with the others and marked with the app's name. Same rules as a starter
// kit: the trial or unlock, consent, the daily spending limit before every paid call. Needs Claude, the only
// provider with web search here.

import Foundation
import SwiftData

/// Why "Undercut an app" stopped with nothing saved.
enum UndercutError: LocalizedError, Equatable {
    /// One is already running; a second tap would pay twice.
    case busy
    /// The trial hasn't started, or has ended without the unlock.
    case locked(trialStarted: Bool)
    /// Claude isn't set up (or agreed to); the research needs its web search.
    case needsClaude
    /// The link had no app name and none was typed.
    case noName
    /// The web research found nothing usable (charged, but nothing to build on).
    case nothingFound(String)
    /// The devil's advocate found no idea one person could build.
    case noIdea(String)

    var errorDescription: String? {
        switch self {
        case .busy: "IdeaScout is already working on an app."
        case .locked(let started): started
            ? "Your free trial has ended. Unlock IdeaScout to undercut apps."
            : "Start your free 7-day trial to undercut apps."
        case .needsClaude: "Undercutting an app needs Claude (it searches the web), with its API key and your OK to "
            + "share with Anthropic. See Settings → Advanced → AI & costs."
        case .noName: "Type the app's name first."
        case .nothingFound(let name): "The web search found too little about \(name) to work from. Check the name, "
            + "or try the name of its company."
        case .noIdea(let name): "No idea to undercut \(name) passed the devil's advocate: none was something one person "
            + "could build. Try again, or try a simpler app."
        }
    }
}

@MainActor
extension DigestService {
    /// Researches the app, makes and judges ideas to undercut it, and saves the best one.
    /// - Parameter target: The app, as read from the link or typed.
    /// - Returns: The saved idea.
    /// - Throws: `UndercutError` or `SummarizerError.overDailyLimit` (before any call, nothing is charged; later,
    ///   the calls made so far are charged and nothing is saved); otherwise errors from a call or parser.
    func undercut(_ target: Undercut.Target) async throws -> KillerIdea {
        // Money: set before the first await, so a second tap can't start a second paid run.
        guard undercutStep.isEmpty else { throw UndercutError.busy }
        let name = target.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw UndercutError.noName }
        undercutStep = "Starting…"
        defer { undercutStep = "" }

        let access = await dependencies.access()
        guard access.canRefresh else { throw UndercutError.locked(trialStarted: access != .notStarted) }
        guard let llm = dependencies.makeSummarizer() as? LLMSummarizer, llm.client.provider == .claude,
              let searcher = dependencies.priceChecker() else { throw UndercutError.needsClaude }
        if dependencies.isOverDailyCap() { throw SummarizerError.overDailyLimit }

        var named = target
        named.name = StarterKit.clean(name, Undercut.maxNameLength)
        undercutStep = "Searching the web for \(named.name)'s prices and complaints…"
        let reply = try await searcher.searchWeb(system: Undercut.searchInstructions,
                                                 prompt: Undercut.searchPrompt(named, interestArea: AppSettings.interestArea),
                                                 maxSearches: Undercut.maxSearches, blockedDomains: Undercut.blockedDomains,
                                                 feature: "Undercut an app")
        guard !reply.sources.isEmpty else { throw UndercutError.nothingFound(named.name) }
        if dependencies.isOverDailyCap() { throw SummarizerError.overDailyLimit }
        let data = try await searcher.complete(system: Undercut.formatInstructions, prompt: Undercut.formatPrompt(reply),
                                               schema: Undercut.formatSchema, effort: "low", feature: "Undercut an app")
        let research = try Undercut.parse(data, sources: reply.sources, target: named)
        guard !research.items.isEmpty else { throw UndercutError.nothingFound(named.name) }

        if dependencies.isOverDailyCap() { throw SummarizerError.overDailyLimit }
        undercutStep = "Writing ideas to undercut \(named.name)…"
        let service = self
        let writer = dependencies.stepClient(.writing).map { LLMSummarizer(client: $0) } ?? llm
        // The leaderboard isn't sent: these ideas answer one app, not the day's scan, so they shouldn't merge into it.
        let results = try await KillerEngine(llm: writer, judge: dependencies.stepClient(.judging), onCritique: {
            await MainActor.run { service.undercutStep = "The devil's advocate is judging them…" }
        }).run(.init(themes: [], items: research.items, aboutMe: AppSettings.aboutMe, leaderboard: [],
                     interestArea: AppSettings.interestArea, tool: AppSettings.builderTool, appType: AppSettings.appType,
                     target: research.target))
        guard var best = results.first else { throw UndercutError.noIdea(named.name) }
        if let app = Undercut.competitor(research.target) {
            best.review.competitorsFound = PriceCheck.merge(existing: best.competitors, checked: [app])
        }

        undercutStep = "Checking competitor prices on the web…"
        let checked = await checkPrices([best])
        guard let context = container?.mainContext else { throw UndercutError.noIdea(named.name) }
        mergeKillerIdeas(checked.results, items: research.items, context: context)
        let key = KillerIdea.key(for: best.candidate.title)
        let saved = try context.fetch(FetchDescriptor<KillerIdea>(predicate: #Predicate { $0.key == key })).first
        guard let saved else { throw UndercutError.noIdea(named.name) }
        saved.undercutApp = named.name
        saved.isDismissed = false
        if let message = context.saveOrReport("the new idea") { lastError = message }
        return saved
    }
}
