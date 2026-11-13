// DigestService+Improve.swift
// "Improve this idea" on demand: a paid re-score of the original, then up to three rounds of a paid rewrite and a
// paid devil's-advocate review, never part of a refresh. Same rules as a starter kit: the trial or unlock, a cloud
// AI with a key and consent, the daily spending limit. The idea itself only changes when the user keeps a version; undo puts the original back.

import Foundation
import SwiftData

/// Why an improvement couldn't start (before any AI call, so nothing was charged).
enum ImproveError: LocalizedError, Equatable {
    /// An improvement is already running; a second tap would pay twice.
    case busy
    /// The trial hasn't started, or has ended without the unlock.
    case locked(trialStarted: Bool)
    /// No cloud AI is set up (or agreed to).
    case needsCloudAI

    var errorDescription: String? {
        switch self {
        case .busy: "An idea is already being improved."
        case .locked(let started): started
            ? "Your free trial has ended. Unlock IdeaScout to improve ideas."
            : "Start your free 7-day trial to improve ideas."
        case .needsCloudAI: "Improving an idea needs a cloud AI (for example Claude or ChatGPT) with its API key, and "
            + "your OK to share with it. See Settings → Advanced → AI & costs."
        }
    }
}

@MainActor
extension DigestService {
    /// Runs an improvement and saves each finished round on the idea (`improvement`); "Improve again" adds to the
    /// last run.
    /// The idea's own text and scores don't change.
    /// - Throws: `ImproveError` or `SummarizerError.overDailyLimit` before any call; otherwise errors from a call
    ///   or parser, with the rounds already finished kept.
    func improve(_ idea: KillerIdea) async throws {
        // Money: set before the first await, so a second tap can't start a second paid run.
        guard improvingIdea == nil else { throw ImproveError.busy }
        improvingIdea = idea.key
        defer { improvingIdea = nil; improveStep = "" }

        let access = await dependencies.access()
        guard access.canRefresh else { throw ImproveError.locked(trialStarted: access != .notStarted) }
        guard let llm = dependencies.makeSummarizer() as? LLMSummarizer else { throw ImproveError.needsCloudAI }
        if dependencies.isOverDailyCap() { throw SummarizerError.overDailyLimit }

        let title = idea.title, evidence = idea.evidenceTitles, aboutMe = AppSettings.aboutMe, tool = AppSettings.builderTool,
            appType = AppSettings.appType
        let client = llm.client
        let judge = dependencies.stepClient(.judging) ?? client
        // "Improve again" carries on from the version in use (or the best so far), capped by the idea as the scan
        // made it, before any kept round. A new run starts from the idea as it stands.
        let original = idea.originalVersion ?? IdeaVersion(idea)
        let previous = idea.improvement.flatMap { run in
            IdeaImprover.continueIndex(run) { version, index in version.isInUse(by: idea, isOriginal: index == 0) }
                .map { (run: run, from: $0) }
        }
        _ = try await IdeaImprover.run(
            from: previous == nil ? IdeaVersion(idea) : original, continuing: previous, bar: AppSettings.qualityBar,
            beforeCall: { if dependencies.isOverDailyCap() { throw SummarizerError.overDailyLimit } },
            rewrite: { version, round in
                improveStep = "Round \(round): rewriting the idea…"
                let data = try await client.complete(
                    system: IdeaImprover.rewriteInstructions,
                    prompt: IdeaImprover.rewritePrompt(version, title: title, evidence: evidence, aboutMe: aboutMe, tool: tool, appType: appType),
                    schema: IdeaImprover.rewriteSchema, effort: "medium", feature: "Improve idea")
                return try IdeaImprover.parseRewrite(data, from: version)
            },
            review: { version, step in
                improveStep = step == 0 ? "Re-scoring the original so the rounds compare fairly…"
                    : "Round \(step): the devil's advocate is judging it…"
                let data = try await judge.complete(
                    system: KillerEngine.critiqueInstructions,
                    prompt: IdeaImprover.reviewPrompt(version, title: title, evidence: evidence, aboutMe: aboutMe, tool: tool, appType: appType),
                    schema: KillerEngine.reviewSchema, effort: "high", feature: "Improve idea: devil's advocate")
                guard let review = try KillerEngine.parseReviews(data).first else {
                    throw SummarizerError.badResponse("the devil's advocate gave no review")
                }
                return review
            },
            onRound: { run in
                var saved = run
                saved.model = client.model
                idea.improvement = saved
                if let message = container?.mainContext.saveOrReport("the improved idea") { lastError = message }
            })
    }

    /// Replaces the idea's text and scores with a version from the last run, keeping the original for undo.
    /// The title, evidence, days seen and score history stay.
    func keep(_ version: IdeaVersion, for idea: KillerIdea) {
        if idea.originalVersion == nil { idea.originalVersion = IdeaVersion(idea) }
        version.apply(to: idea)
        idea.improvedAt = .now
        if let message = container?.mainContext.saveOrReport("the improved idea") { lastError = message }
    }

    /// Puts back the idea as it was before the first kept improvement.
    func undoImprovement(of idea: KillerIdea) {
        guard let original = idea.originalVersion else { return }
        original.apply(to: idea)
        idea.originalVersion = nil
        idea.improvedAt = nil
        if let message = container?.mainContext.saveOrReport("your change") { lastError = message }
    }
}
