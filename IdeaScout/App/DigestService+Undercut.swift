// DigestService+Undercut.swift
// "Reimagine an app" on demand, in steps (owner, 16 Nov 2026; first built as "Undercut an app", so the code keeps
// that name): 1) research the app (Claude Haiku web search kept off Apple's and Replit's sites, plus the app's 1-2
// star reviews from Apple's public review feed when an App Store link was given) and explain it; 2) offer ways to
// reimagine it; 3) for the way the user picks, check that group on the web, write one idea, have the devil's advocate
// judge it and check prices. A backed idea is saved; a rejected one is shown and saved only if the user asks. Same
// rules as a starter kit: access, consent, the daily spending limit before every paid call. Needs Claude.

import Foundation
import SwiftData

/// Why a "Reimagine an app" step stopped.
enum UndercutError: LocalizedError, Equatable {
    /// A step is already running; a second tap would pay twice.
    case busy
    /// The trial hasn't started, or has ended without the unlock.
    case locked(trialStarted: Bool)
    /// Claude isn't set up (or agreed to); the research needs its web search.
    case needsClaude
    /// The link had no app name and none was typed.
    case noName
    /// The research found nothing usable (charged, but nothing to build on).
    case nothingFound(String)
    /// The idea step proposed nothing, or nothing one person could build.
    case noIdea(String)

    var errorDescription: String? {
        switch self {
        case .busy: "IdeaScout is already working on an app."
        case .locked(let started): started
            ? "Your free trial has ended. Unlock IdeaScout to reimagine apps."
            : "Start your free 7-day trial to reimagine apps."
        case .needsClaude: "Reimagining an app needs Claude (it searches the web), with its API key and your OK to "
            + "share with Anthropic. See Settings → Advanced → AI & costs."
        case .noName: "Type the app's name first."
        case .nothingFound(let name): "The web search found too little about \(name) to work from. If it's an iPhone "
            + "app, paste its App Store link (in the App Store: Share → Copy Link) so its reviews can be read, or check the name."
        case .noIdea(let name): "No idea for this direction beside \(name) could be built by one person. Try another direction."
        }
    }
}

/// Step 3's result: the judged idea and the evidence it cites, waiting to be saved.
struct ReimagineBuilt: Sendable {
    var result: KillerEngine.Result
    var items: [FetchedItem]
}

@MainActor
extension DigestService {
    /// Checks access and Claude, and marks a step as running. Call `defer { undercutStep = "" }` after it.
    private func startReimagineStep(_ first: String) async throws -> (writer: LLMSummarizer, searcher: any WebSearchClient & LLMClient) {
        // Money: set before the first await, so a second tap can't start a second paid run.
        guard undercutStep.isEmpty else { throw UndercutError.busy }
        undercutStep = first
        // If a check fails, clear the step here: the caller's `defer` only starts once this returns.
        do {
            let access = await dependencies.access()
            guard access.canRefresh else { throw UndercutError.locked(trialStarted: access != .notStarted) }
            guard let llm = dependencies.makeSummarizer() as? LLMSummarizer, llm.client.provider == .claude,
                  let searcher = dependencies.priceChecker() else { throw UndercutError.needsClaude }
            if dependencies.isOverDailyCap() { throw SummarizerError.overDailyLimit }
            return (dependencies.stepClient(.writing).map { LLMSummarizer(client: $0) } ?? llm, searcher)
        } catch {
            undercutStep = ""
            throw error
        }
    }

    /// Step 1: researches the app and saves the run on the device.
    /// - Parameters:
    ///   - target: The app, as read from the link or typed.
    ///   - note: What bugs the user about it, or who they'd build for; may be empty.
    /// - Returns: The run with the app's profile and numbered evidence.
    /// - Throws: `UndercutError`, `SummarizerError.overDailyLimit`, or errors from a call or parser.
    func reimagineResearch(_ target: Undercut.Target, note: String) async throws -> Reimagine.Run {
        let name = StarterKit.clean(target.name.trimmingCharacters(in: .whitespacesAndNewlines), Undercut.maxNameLength)
        guard !name.isEmpty else { throw UndercutError.noName }
        let (_, searcher) = try await startReimagineStep("Starting…")
        defer { undercutStep = "" }
        var run = Reimagine.Run(target: target, note: StarterKit.clean(note, Reimagine.maxNoteLength))
        run.target.name = name

        undercutStep = "Searching the web for what \(name) does, its prices and what people say about it…"
        let reply = try await searcher.searchWeb(system: Undercut.searchInstructions,
                                                 prompt: Undercut.searchPrompt(run.target, interestArea: AppSettings.interestArea),
                                                 maxSearches: Undercut.maxSearches, blockedDomains: Undercut.blockedDomains,
                                                 feature: "Reimagine an app")
        var items: [FetchedItem] = []
        if !reply.sources.isEmpty {
            if dependencies.isOverDailyCap() { throw SummarizerError.overDailyLimit }
            let data = try await searcher.complete(system: Reimagine.profileInstructions, prompt: Undercut.formatPrompt(reply),
                                                   schema: Reimagine.profileSchema, effort: "low", feature: "Reimagine an app")
            let parsed = try Reimagine.parseProfile(data, sources: reply.sources, target: run.target)
            run.profile = parsed.profile
            run.target = parsed.target
            items = parsed.items
        }
        if !run.target.appID.isEmpty {
            undercutStep = "Reading \(name)'s App Store reviews…"
            items = await appStoreReviews(run.target) + items
        }
        if let mine = Reimagine.noteItem(run.note, app: name) { items.insert(mine, at: 0) }
        guard items.contains(where: { KillerEngine.painEvidence.contains($0.source) }) || !run.profile.whatItDoes.isEmpty
        else { throw UndercutError.nothingFound(name) }
        run.evidence = items.map(Reimagine.Evidence.init)
        ReimagineStore.save(run)
        return run
    }

    /// The app's recent 1-2 star reviews from Apple's public review feed (owner, 16 Nov 2026: the feed the daily
    /// "App Store complaints" source uses; Apple's search and pages are never used). Free; a failure just means none.
    private func appStoreReviews(_ target: Undercut.Target) async -> [FetchedItem] {
        let id = String(target.appID.dropFirst(2))   // "id123" → "123"; checked numeric when the link was read
        guard let url = URL(string: "https://itunes.apple.com/\(target.country)/rss/customerreviews/page=1/id=\(id)/sortby=mostrecent/json"),
              let data = try? await dependencies.httpGet(url) else { return [] }
        let app = AppReviewsFetcher.App(id: id, name: target.name, country: target.country, genre: "", rank: 0)
        let since = Date.now.addingTimeInterval(-365 * 86_400)
        let reviews = (try? AppReviewsFetcher.parseReviews(data, app: app, since: since,
                                                            context: "App Store, \(target.country.uppercased())")) ?? []
        return Array(reviews.prefix(Reimagine.maxReviews))
    }

    /// Step 2: ways to reimagine the app, each backed by at least two pages of evidence; saved with the run.
    /// - Parameter run: The researched run.
    /// - Returns: The run with its directions (empty means no clear gap was found).
    /// - Throws: `UndercutError`, `SummarizerError.overDailyLimit`, or errors from the call or parser.
    func reimagineDirections(_ run: Reimagine.Run) async throws -> Reimagine.Run {
        let (writer, _) = try await startReimagineStep("Looking for ways to reimagine \(run.target.name)…")
        defer { undercutStep = "" }
        let items = run.items
        let data = try await writer.client.complete(
            system: Reimagine.directionsInstructions,
            prompt: Reimagine.directionsPrompt(run, tool: AppSettings.builderTool, appType: AppSettings.appType,
                                               interestArea: AppSettings.interestArea),
            schema: Reimagine.directionsSchema, effort: "medium", feature: "Reimagine directions")
        var updated = run
        updated.directions = try Reimagine.parseDirections(data, items: items)
        updated.directionsMade = true
        ReimagineStore.save(updated)
        return updated
    }

    /// Step 3: checks the chosen group on the web, writes one idea for it, has it judged and checks prices.
    /// Nothing is saved here: a backed idea is saved by the screen at once, a rejected one only if the user asks.
    /// - Parameters:
    ///   - run: The researched run.
    ///   - direction: The way the user picked (or wrote).
    /// - Returns: The judged idea and its evidence.
    /// - Throws: `UndercutError`, `SummarizerError.overDailyLimit`, or errors from a call or parser.
    func reimagineBuild(_ run: Reimagine.Run, direction: Reimagine.Direction) async throws -> ReimagineBuilt {
        let (writer, searcher) = try await startReimagineStep("Checking who serves \(direction.who) now…")
        defer { undercutStep = "" }
        var items = run.items
        let reply = try await searcher.searchWeb(system: Reimagine.groupSearchInstructions,
                                                 prompt: Reimagine.groupSearchPrompt(direction, app: run.target.name),
                                                 maxSearches: Reimagine.groupSearches, blockedDomains: Undercut.blockedDomains,
                                                 feature: "Reimagine an app")
        if !reply.sources.isEmpty {
            if dependencies.isOverDailyCap() { throw SummarizerError.overDailyLimit }
            let data = try await searcher.complete(system: Undercut.formatInstructions, prompt: Undercut.formatPrompt(reply),
                                                   schema: Undercut.formatSchema, effort: "low", feature: "Reimagine an app")
            let known = Set(items.map(\.key))
            items += (try Undercut.parse(data, sources: reply.sources, target: run.target)).items.filter { !known.contains($0.key) }
        }

        if dependencies.isOverDailyCap() { throw SummarizerError.overDailyLimit }
        undercutStep = "Writing the idea…"
        let tool = AppSettings.builderTool, appType = AppSettings.appType
        let ideaData = try await writer.client.complete(
            system: Reimagine.ideaInstructions,
            prompt: Reimagine.ideaPrompt(run, direction: direction, items: items, aboutMe: AppSettings.aboutMe, tool: tool, appType: appType),
            schema: KillerEngine.candidateSchema, effort: "medium", feature: "Reimagine idea")
        guard let candidate = try KillerEngine.parseCandidates(ideaData).first else { throw UndercutError.noIdea(run.target.name) }

        if dependencies.isOverDailyCap() { throw SummarizerError.overDailyLimit }
        undercutStep = "The devil's advocate is judging it…"
        let reviews = try await KillerEngine(llm: writer, judge: dependencies.stepClient(.judging))
            .critique([candidate], items: items, aboutMe: AppSettings.aboutMe, tool: tool, appType: appType, target: run.target)
        guard let judged = KillerEngine.survivors(candidates: [candidate], reviews: reviews, items: items, tool: tool,
                                                  appType: appType).first else { throw UndercutError.noIdea(run.target.name) }

        undercutStep = "Checking competitor prices on the web…"
        let checked = await checkPrices([judged])
        return ReimagineBuilt(result: checked.results.first ?? judged, items: items)
    }

    /// Saves a step 3 idea with the others, marked with the app's name.
    /// - Returns: The saved idea.
    /// - Throws: `UndercutError.noIdea` if it couldn't be saved.
    func saveReimagined(_ built: ReimagineBuilt, app: String) throws -> KillerIdea {
        guard let context = container?.mainContext else { throw UndercutError.noIdea(app) }
        mergeKillerIdeas([built.result], items: built.items, context: context)
        let key = KillerIdea.key(for: built.result.candidate.title)
        guard let saved = try context.fetch(FetchDescriptor<KillerIdea>(predicate: #Predicate { $0.key == key })).first
        else { throw UndercutError.noIdea(app) }
        saved.undercutApp = app
        saved.isDismissed = false
        if let message = context.saveOrReport("the new idea") { lastError = message }
        return saved
    }
}
