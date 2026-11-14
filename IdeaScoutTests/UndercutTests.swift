// UndercutTests.swift
// "Reimagine an app" (first "Undercut an app"): reading App Store links on the phone, keeping only research the web search really returned
// (never Apple's pages), the prompt block, and the service end to end with a scripted AI and web search (offline).

import Foundation
import Testing
import SwiftData
@testable import IdeaScout

struct UndercutRuleTests {
    /// App Store links still resolve (owner, 14 Nov 2026), and any other web link or a typed name works too; the
    /// search gets the link, except Apple's.
    @Test(arguments: [
        ("https://apps.apple.com/au/app/things-3/id904237743", "Things 3", "App Store id904237743", ""),
        ("apps.apple.com/us/app/fantastical-calendar/id975937182?platform=iphone", "Fantastical Calendar", "App Store id975937182", ""),
        ("https://apps.apple.com/app/id123456", "", "App Store id123456", ""),          // no words: the user types the name
        ("https://github.com/usememos/memos?tab=readme", "Memos", "GitHub usememos/memos", "https://github.com/usememos/memos"),
        ("github.com/excalidraw/excalidraw", "Excalidraw", "GitHub excalidraw/excalidraw", "https://github.com/excalidraw/excalidraw"),
        ("https://www.notion.so/product?utm=x", "Notion", "www.notion.so", "https://www.notion.so/product"),
        ("app.todoist.com", "Todoist", "app.todoist.com", "https://app.todoist.com"),
        ("  Notion  ", "Notion", "", ""),                                              // typed names
        ("Things 3.0", "Things 3.0", "", ""),
    ])
    func readsTheAppFromTheLink(input: String, name: String, from: String, link: String) {
        let target = Undercut.target(from: input)
        #expect(target?.name == name && target?.from == from && target?.link == link)
    }

    @Test(arguments: ["", "ftp://example.com/x", "https://localhost/x", "https://github.com/usememos",
                      "https://apps.apple.com/au/developer/cultured-code/id1", "https://apps.apple.com/au/app/things-3"])
    func rejectsWhatIsNotAnAppLink(input: String) {
        #expect(Undercut.target(from: input) == nil)
    }

    /// Findings and the price are kept only with links the search returned; Apple's and Replit's pages are dropped
    /// even if returned; one item per page; apps solo builders already made become "Vibe-coded" competition.
    @Test func keepsOnlyRealLinks() throws {
        let json = #"{"app_plan":"Pro","price_per_month_usd":10,"price_url":"https://things.example/pricing","summary":"A to-do app.","findings":[{"kind":"complaint","title":"Too pricey for what it does","detail":"d","url":"https://forum.example/t/1"},{"kind":"complaint","title":"Same thread again","detail":"d","url":"https://forum.example/t/1/"},{"kind":"paid_plan","title":"Pro is $10 a month","detail":"d","url":"https://things.example/pricing"},{"kind":"complaint","title":"Made up","detail":"d","url":"https://invented.example/x"},{"kind":"complaint","title":"App Store review","detail":"d","url":"https://apps.apple.com/au/app/things-3/id1"},{"kind":"already_built","title":"TinyTasks, made with Lovable","detail":"d","url":"https://news.example/item/9"},{"kind":"already_built","title":"Replit gallery","detail":"d","url":"https://replit.com/gallery/x"}]}"#
        let data = try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": json]], "stop_reason": "end_turn"])
        let research = try Undercut.parse(data, sources: ["https://forum.example/t/1", "https://things.example/pricing/",
                                                          "https://apps.apple.com/au/app/things-3/id1",
                                                          "https://news.example/item/9", "https://replit.com/gallery/x"],
                                          target: Undercut.Target(name: "Things 3"))
        #expect(research.items.map(\.source) == [.webComplaints, .webPaying, .vibeCode])
        #expect(research.target.alreadyBuilt == ["TinyTasks, made with Lovable"])
        #expect(research.target.monthlyPrice == 10 && research.target.plan == "Pro")
        #expect(Undercut.competitor(research.target)?.confirmed == true)

        let unfound = try Undercut.parse(data, sources: ["https://forum.example/t/1"], target: Undercut.Target(name: "Things 3"))
        #expect(unfound.target.monthlyPrice == 0 && Undercut.competitor(unfound.target) == nil, "no price without its link")
    }

    /// The app, its price and what's already built reach both the idea step and the devil's advocate, whose
    /// instructions fail copies; the starter kit says not to copy it.
    @Test func promptNamesTheAppAndItsPrice() {
        let target = Undercut.Target(name: "Things 3", alreadyBuilt: ["TinyTasks"], plan: "Pro", monthlyPrice: 10, summary: "Too dear.")
        let block = Undercut.promptBlock(target)
        #expect(Undercut.searchPrompt(Undercut.Target(name: "Memos", link: "https://github.com/usememos/memos"), interestArea: "")
            .contains("https://github.com/usememos/memos"))
        #expect(block.contains("App the user named (find a gap beside it; don't copy it): Things 3")
                && block.contains("$10 a month") && block.contains("Too dear.") && block.contains("TinyTasks"))
        #expect(KillerEngine.generateInstructions.contains("don't compete with it head-on"))
        #expect(KillerEngine.critiqueInstructions.contains("survives is false for any idea that copies it"))
        #expect(KillerEngine.critiquePrompt([], items: [], aboutMe: "", target: target).contains("Things 3"))
        #expect(!KillerEngine.critiquePrompt([], items: [], aboutMe: "").contains("App the user named"))
        var request = StarterKitPrompts.Request(KillerIdea(key: "k", title: "TinyTodo"), aboutMe: "")
        #expect(!StarterKitPrompts.prompt(request).contains("don't copy"))
        request.reimaginedApp = "Things 3"
        #expect(StarterKitPrompts.prompt(request).contains("Found beside this app (don't copy it): Things 3"))
        #expect(ClaudeClient.searchBody(system: "s", messages: [], maxSearches: 5, blockedDomains: Undercut.blockedDomains, model: "m")
            .description.contains("replit.com"))
    }
}

@MainActor
struct UndercutServiceTests {
    private static let research = #"{"app_plan":"Pro","price_per_month_usd":10,"price_url":"https://things.example/pricing","summary":"A to-do app people find dear.","findings":[{"kind":"complaint","title":"Too pricey","detail":"d","url":"https://forum.example/t/1"},{"kind":"paid_plan","title":"Pro is $10 a month","detail":"d","url":"https://things.example/pricing"}]}"#
    private static let ideas = #"{"ideas":[{"title":"TinyTodo","pitch":"p","buyer":"b","pricing":"$3 once","why_now":"w","one_week_test":"t","replaces":"Things 3","channel":"App Store","evidence_numbers":[1,2],"same_as":""}]}"#
    private static let reviews = #"{"reviews":[{"title":"TinyTodo","survives":true,"objection":"o","competitors":"Things 3","verdict":"v","pain":5,"willing_to_pay":5,"timing":4,"gap":4,"fit":4,"buildability":4,"channel_score":4,"evidence_needed":"e"}]}"#

    private func service(claude: Bool) throws -> (DigestService, ModelContext) {
        let container = try ModelContainer(for: Digest.self, Theme.self, Item.self, Idea.self, KillerIdea.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let llm = ScriptedLLM(replies: ["Killer ideas": .success(Self.ideas), "Devil's advocate": .success(Self.reviews)])
        let found = WebSearchReply(text: "Things 3 Pro costs $10 a month; people say it's too pricey.",
                                   sources: ["https://forum.example/t/1", "https://things.example/pricing"])
        let searcher = ScriptedPriceChecker(search: .success(found), formatted: Self.research)
        let service = DigestService(dependencies: .init(
            makeFetchers: { [] }, makeSummarizer: { LLMSummarizer(client: llm) },
            freeSummarizer: { KeywordSummarizer(topics: []) }, access: { .unlocked }, isOverDailyCap: { false },
            needsConsent: { false }, notify: { _, _ in }, priceChecker: { claude ? searcher as (any WebSearchClient & LLMClient) : nil }))
        service.container = container
        return (service, container.mainContext)
    }

    /// The research becomes evidence, the app becomes a confirmed competitor, and the idea is saved and marked.
    @Test func makesAndSavesAnIdeaToUndercutTheApp() async throws {
        let (service, context) = try service(claude: true)
        let idea = try await service.undercut(Undercut.Target(name: "Things 3", appID: "id904237743"))
        #expect(idea.title == "TinyTodo" && idea.undercutApp == "Things 3")
        #expect(idea.evidenceURLs == ["https://forum.example/t/1", "https://things.example/pricing"])
        #expect(idea.pain == 4, "one complaint page allows 4, not the 5 asked for")
        #expect(idea.competitorList.contains { $0.name == "Things 3" && $0.confirmed && $0.monthlyPrice == 10 })
        #expect(try context.fetch(FetchDescriptor<KillerIdea>()).count == 1)
        #expect(service.undercutStep.isEmpty)
    }

    /// Without Claude's web search, or without a name, it stops before any paid call.
    @Test func stopsBeforeAnyPaidCall() async throws {
        let (noClaude, context) = try service(claude: false)
        await #expect(throws: UndercutError.needsClaude) { _ = try await noClaude.undercut(Undercut.Target(name: "Things 3")) }
        await #expect(throws: UndercutError.noName) { _ = try await noClaude.undercut(Undercut.Target(name: " ")) }
        #expect(try context.fetch(FetchDescriptor<KillerIdea>()).isEmpty && noClaude.undercutStep.isEmpty)
    }
}
