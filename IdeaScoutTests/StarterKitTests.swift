// StarterKitTests.swift
// The starter kit: checking and cleaning the AI's reply, the schema and instructions agreeing, the shared text for
// each coding tool, the cost estimate, and the rules for making one (trial, cloud AI, spending limit, one at a
// time, no lost kit on failure). Offline: the AI is scripted and the database is in memory.

import Foundation
import Testing
import SwiftData
@testable import IdeaScout

/// Wraps kit JSON in Claude's reply format.
private func reply(_ json: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": json]], "stop_reason": "end_turn"])
}

/// A reply in the schema's shape, with the given spec and screens.
private func kitJSON(spec: String = "A tool that chases unpaid invoices.", screens: [String] = ["Invoices"],
                     leaveOut: [String] = ["Payments"]) -> String {
    let encoded: (Any) -> String = { value in
        (try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
    return """
    {"spec":\(encoded(spec)),"screens":\(encoded(screens.map { ["name": $0, "purpose": "See \($0)."] })),\
    "data_model":[{"entity":"Invoice","fields":["amount (number)"],"notes":"Belongs to a business."}],\
    "stack":[{"part":"Website","choice":"Next.js","why":"Free tier."}],"monthly_cost":"About $25.",\
    "leave_out":\(encoded(leaveOut)),"first_slice":"List overdue invoices.","done_when":["They're listed."],\
    "project_rules":["Keep keys out of the code."]}
    """
}

struct StarterKitParsingTests {
    @Test func replyIsCleanedAndCapped() throws {
        let kit = try StarterKit.parse(reply(kitJSON(
            spec: "Chases   invoices. See https://evil.example/x and www.evil.example now. " + String(repeating: "a", count: 2_000),
            screens: (1...12).map { "Screen \($0)" }, leaveOut: ["Payments", "   ", "Reports"])))
        #expect(!kit.spec.contains("evil.example"))
        #expect(kit.spec.hasPrefix("Chases invoices. See and now."))
        #expect(kit.spec.count == 900)
        #expect(kit.screens.count == StarterKit.maxScreens)
        #expect(kit.leaveOut == ["Payments", "Reports"])
    }

    @Test func emptyKitIsRejected() throws {
        #expect(throws: SummarizerError.self) { try StarterKit.parse(reply(kitJSON(spec: " "))) }
        #expect(throws: SummarizerError.self) { try StarterKit.parse(reply(kitJSON(screens: []))) }
    }

    /// Prompts and schemas move together: every field the schema requires is described in the instructions.
    @Test func schemaAndInstructionsAgree() throws {
        let properties = try #require(StarterKit.schema["properties"] as? [String: Any])
        #expect(Set(properties.keys) == Set(StarterKit.requiredFields))
        for field in StarterKit.requiredFields {
            #expect(StarterKitPrompts.instructions.contains("- \(field):"), "instructions should describe \(field)")
        }
    }

    @Test func savedKitReadsBack() throws {
        let idea = KillerIdea(key: "a", title: "A")
        #expect(idea.starterKit == nil)
        let kit = try StarterKit.parse(reply(kitJSON()))
        idea.starterKit = kit
        #expect(idea.starterKit == kit)
    }
}

struct StarterKitSharingTests {
    @Test(arguments: [(BuilderTool.claudeCode, "CLAUDE.md"), (.cursor, "Agent"), (.replit, "Replit Agent"), (.lovable, "Supabase")])
    func sharedKitIsWordedForTheTool(tool: BuilderTool, phrase: String) throws {
        let kit = try StarterKit.parse(reply(kitJSON()))
        let text = StarterKitPrompts.shareText(kit, title: "InvoiceChaser", tool: tool)
        #expect(text.hasPrefix(tool.opening))
        #expect(tool.opening.contains(phrase))
        #expect(text.contains(StarterKitPrompts.buildNotice))
        #expect(!text.contains(Prompts.pastedPromptNotice), "the paste notice forbids commands, which would stop the build")
        #expect(text.contains(kit.spec) && text.contains("List overdue invoices."))
    }

    /// Stored identifiers are permanent: the tool's raw values and its settings key.
    @Test func toolChoiceIsStoredUnderPermanentNames() {
        #expect(BuilderTool.allCases.map(\.rawValue) == ["claudeCode", "cursor", "replit", "lovable"])
        #expect(AppSettings.Keys.starterKitTool == "starterKit.tool")
    }

    @Test(arguments: [(ModelPrice(input: 2, output: 10), 0.065), (ModelPrice(input: 8, output: 40), 0.26)])
    func kitCostFollowsModelPrice(price: ModelPrice, dollars: Double) {
        #expect(abs(AppSettings.estimatedStarterKitCost(price: price) - dollars) < 0.0001)
    }
}

/// Making a kit through the service, with stand-ins for the trial, AI and spending limit.
@MainActor
struct StarterKitRuleTests {
    /// What blocks a kit before any AI call.
    enum Block: CaseIterable { case trialEnded, trialNotStarted, noCloudAI, overLimit }

    private func setUp(llm: ScriptedLLM?, access: StoreManager.Access = .unlocked,
                       overCap: Bool = false) throws -> (DigestService, KillerIdea) {
        let container = try ModelContainer(for: Digest.self, Theme.self, Item.self, Idea.self, KillerIdea.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let service = DigestService(dependencies: .init(
            makeFetchers: { [] },
            makeSummarizer: { llm.map { LLMSummarizer(client: $0) as any Summarizer } ?? KeywordSummarizer(topics: []) },
            freeSummarizer: { KeywordSummarizer(topics: []) },
            access: { access }, isOverDailyCap: { overCap }, needsConsent: { false }, notify: { _, _ in }))
        service.container = container
        let idea = KillerIdea(key: "invoicechaser", title: "InvoiceChaser")
        container.mainContext.insert(idea)
        return (service, idea)
    }

    @Test func kitIsMadeAndSaved() async throws {
        let (service, idea) = try setUp(llm: ScriptedLLM(replies: ["Starter kit": .success(kitJSON())]))
        try await service.makeStarterKit(for: idea)
        #expect(idea.starterKit?.firstSlice == "List overdue invoices.")
        #expect(idea.starterKitModel == "test-model")
        #expect(idea.starterKitMadeAt != nil)
        #expect(service.makingStarterKitFor == nil)
    }

    /// The scripted AI has no reply, so reaching it would throw a different error: each block happens first.
    @Test(arguments: Block.allCases)
    func blockedBeforeAnyPaidCall(block: Block) async throws {
        let llm = block == .noCloudAI ? nil : ScriptedLLM(replies: [:])
        let access: StoreManager.Access = switch block {
        case .trialEnded: .expired
        case .trialNotStarted: .notStarted
        default: .unlocked
        }
        let expected: Error = switch block {
        case .trialEnded: StarterKitError.locked(trialStarted: true)
        case .trialNotStarted: StarterKitError.locked(trialStarted: false)
        case .noCloudAI: StarterKitError.needsCloudAI
        case .overLimit: SummarizerError.overDailyLimit
        }
        let (service, idea) = try setUp(llm: llm, access: access, overCap: block == .overLimit)
        await #expect { try await service.makeStarterKit(for: idea) } throws: {
            $0.localizedDescription == expected.localizedDescription
        }
        #expect(idea.starterKit == nil)
        #expect(service.makingStarterKitFor == nil)
    }

    @Test func secondKitWhileOneIsBeingMadeIsRefused() async throws {
        let (service, idea) = try setUp(llm: ScriptedLLM(replies: ["Starter kit": .success(kitJSON())]))
        service.makingStarterKitFor = "another idea"
        await #expect(throws: StarterKitError.busy) { try await service.makeStarterKit(for: idea) }
        #expect(idea.starterKit == nil)
    }

    @Test func failedRemakeKeepsTheEarlierKit() async throws {
        let (service, idea) = try setUp(llm: ScriptedLLM(replies: ["Starter kit": .success(#"{"spec":"cut"#)]))
        let earlier = try StarterKit.parse(reply(kitJSON()))
        idea.starterKit = earlier
        await #expect(throws: (any Error).self) { try await service.makeStarterKit(for: idea) }
        #expect(idea.starterKit == earlier)
    }
}
