// DigestService+StarterKit.swift
// Makes a starter kit for one idea on demand: one paid cloud AI call, never part of a refresh. Follows the same
// rules as a refresh: the trial or unlock, consent, a cloud AI with a key, and the daily spending limit.

import Foundation
import SwiftData

/// Why a starter kit couldn't be made (before any AI call, so nothing was charged).
enum StarterKitError: LocalizedError, Equatable {
    /// A kit is already being made; a second tap would pay twice.
    case busy
    /// The trial hasn't started, or has ended without the unlock.
    case locked(trialStarted: Bool)
    /// No cloud AI is set up (or agreed to); Apple's on-device model and keyword mode can't make kits.
    case needsCloudAI

    var errorDescription: String? {
        switch self {
        case .busy: "A starter kit is already being made."
        case .locked(let started): started
            ? "Your free trial has ended. Unlock IdeaScout to make new starter kits."
            : "Start your free 7-day trial to make starter kits."
        case .needsCloudAI: "Starter kits need a cloud AI (for example Claude or ChatGPT) with its API key, and your OK "
            + "to share with it. See Settings → Advanced → AI & costs."
        }
    }
}

@MainActor
extension DigestService {
    /// Makes the idea's starter kit and saves it on the idea, replacing any earlier kit.
    /// - Parameter idea: The idea.
    /// - Throws: `StarterKitError` or `SummarizerError.overDailyLimit` before any call (nothing charged);
    ///   otherwise errors from the AI call or `StarterKit.parse`, and the idea keeps its earlier kit.
    func makeStarterKit(for idea: KillerIdea) async throws {
        // Money: set before the first await, so a second tap can't start a second paid call.
        guard makingStarterKitFor == nil else { throw StarterKitError.busy }
        makingStarterKitFor = idea.key
        defer { makingStarterKitFor = nil }

        let access = await dependencies.access()
        guard access.canRefresh else { throw StarterKitError.locked(trialStarted: access != .notStarted) }
        guard let llm = dependencies.makeSummarizer() as? LLMSummarizer else { throw StarterKitError.needsCloudAI }
        if dependencies.isOverDailyCap() { throw SummarizerError.overDailyLimit }

        let request = StarterKitPrompts.Request(idea, aboutMe: AppSettings.aboutMe, tool: AppSettings.builderTool,
                                                  appType: AppSettings.appType)
        let data = try await llm.client.complete(system: StarterKitPrompts.instructions, prompt: StarterKitPrompts.prompt(request),
                                                 schema: StarterKit.schema, effort: "medium", feature: "Starter kit")
        idea.starterKit = try StarterKit.parse(data)
        idea.starterKitMadeAt = .now
        idea.starterKitModel = llm.client.model
        if let message = container?.mainContext.saveOrReport("the starter kit") { lastError = message }
    }
}
