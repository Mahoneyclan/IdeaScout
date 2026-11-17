// UndercutTests.swift
// "Reimagine an app" (first "Undercut an app"): reading App Store links on the phone, keeping only research the web search really returned
// (never Apple's pages), the prompt block, and the three steps end to end with a scripted AI, web search and review
// feed (offline).

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

/// Serialized: the tests share `ReimagineStore.fileURL`.
@MainActor @Suite(.serialized)
struct UndercutServiceTests {
    private static let profile = #"{"what_it_does":"A to-do app.","who_its_for":"Mac users","plans":[{"name":"Things 3","plan":"Pro","price_per_month_usd":10,"url":"https://things.example/pricing"}],"likes":[{"text":"Looks lovely","who":"","url":"https://blog.example/a"}],"complaints":[{"text":"No shared lists for families","who":"Parents","url":"https://forum.example/t/1"},{"text":"Families can't share chores","who":"Parents","url":"https://forum.example/t/2"},{"text":"Made up","who":"","url":"https://invented.example/x"}],"alternatives":[],"already_built":[]}"#
    private static let directions = #"{"directions":[{"who":"Busy parents","job":"Share chores with the family","evidence_numbers":[1,2],"why_not_the_app":"Built for one person.","already_served_by":"Cozi","rough_price":"$2 a month","strength":"strong"},{"who":"Students","job":"Plan study","evidence_numbers":[1],"why_not_the_app":"w","already_served_by":"nobody found","rough_price":"$1","strength":"thin"}]}"#
    private static let group = #"{"app_plan":"","price_per_month_usd":0,"price_url":"","summary":"","findings":[{"kind":"paid_plan","title":"Cozi Gold is $4 a month","detail":"d","url":"https://cozi.example/pricing"}]}"#
    private static let idea = #"{"ideas":[{"title":"ChoreChart","pitch":"p","buyer":"Busy parents","pricing":"$3 a month","why_now":"w","one_week_test":"t","replaces":"Paper lists","channel":"App Store","evidence_numbers":[1,2],"same_as":"","one_job":"Share chores","keep_features":["Lists"],"leave_out_features":["Projects"],"competitors":[{"name":"Cozi","cheapest_plan":"Gold","price_per_month_usd":4,"is_free":false}],"fills_gap":false,"price_per_month_usd":3,"sales_model":"subscription","sales_model_reason":"r"}]}"#
    private static func review(survives: Bool) -> String {
        #"{"reviews":[{"title":"ChoreChart","survives":"# + "\(survives)" + #","objection":"Families already use Cozi.","competitors":"Cozi","verdict":"v","pain":5,"willing_to_pay":4,"timing":4,"gap":4,"fit":4,"buildability":4,"channel_score":4,"evidence_needed":"e"}]}"#
    }

    private func service(claude: Bool = true, survives: Bool = true) throws -> (DigestService, ModelContext) {
        let container = try ModelContainer(for: Digest.self, Theme.self, Item.self, Idea.self, KillerIdea.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let llm = ScriptedLLM(replies: ["Reimagine directions": .success(Self.directions), "Reimagine idea": .success(Self.idea),
                                        "Devil's advocate": .success(Self.review(survives: survives))])
        let found = WebSearchReply(text: "Things 3 research.", sources: ["https://forum.example/t/1", "https://forum.example/t/2",
                                                                          "https://things.example/pricing", "https://blog.example/a",
                                                                          "https://cozi.example/pricing"])
        let searcher = ScriptedPriceChecker(search: .success(found), formatted: Self.group, profile: Self.profile)
        let reviewsFeed = Data(#"{"feed":{"entry":[{"id":{"label":"r1"},"title":{"label":"Can't share"},"content":{"label":"No family sharing."},"im:rating":{"label":"1"},"updated":{"label":"2026-11-10T10:00:00-07:00"}}]}}"#.utf8)
        var deps = DigestService.Dependencies(
            makeFetchers: { [] }, makeSummarizer: { LLMSummarizer(client: llm) },
            freeSummarizer: { KeywordSummarizer(topics: []) }, access: { .unlocked }, isOverDailyCap: { false },
            needsConsent: { false }, notify: { _, _ in }, priceChecker: { claude ? searcher as (any WebSearchClient & LLMClient) : nil })
        deps.httpGet = { url in
            #expect(url.absoluteString.hasPrefix("https://itunes.apple.com/au/rss/customerreviews/"), "only Apple's review feed")
            return reviewsFeed
        }
        let service = DigestService(dependencies: deps)
        service.container = container
        return (service, container.mainContext)
    }

    /// Step 1 explains the app from real links plus its App Store reviews and the user's note; step 2 keeps only
    /// directions backed by two pages; step 3 builds one idea for the chosen direction, capped at 25%, and saves it.
    @Test func explainsTheAppThenBuildsOneIdeaForTheChosenDirection() async throws {
        ReimagineStore.fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("reimagine-\(UUID()).json")
        let (service, context) = try service()
        let target = try #require(Undercut.target(from: "https://apps.apple.com/au/app/things-3/id904237743"))
        let run = try await service.reimagineResearch(target, note: "I want to share lists with my kids")
        #expect(run.profile.whatItDoes == "A to-do app." && run.profile.complaints.count == 2, "the made-up link is dropped")
        #expect(run.items.first?.source == .fieldNotes && run.items.contains { $0.source == .appReviews })
        #expect(run.target.monthlyPrice == 10)

        let withDirections = try await service.reimagineDirections(run)
        #expect(withDirections.directions.map(\.who) == ["Busy parents"], "the one-source direction is dropped")
        #expect(ReimagineStore.load().first?.directions.count == 1, "saved so another direction costs no new research")

        let built = try await service.reimagineBuild(withDirections, direction: withDirections.directions[0])
        #expect(built.result.review.survives && built.result.price == 1, "25% of Cozi's $4")
        let idea = try service.saveReimagined(built, app: run.target.name)
        #expect(idea.title == "ChoreChart" && idea.undercutApp == "Things 3")
        #expect(try context.fetch(FetchDescriptor<KillerIdea>()).count == 1 && service.undercutStep.isEmpty)
        ReimagineStore.deleteAll()
    }

    /// A rejected idea is returned with its objection, not saved silently.
    @Test func rejectedIdeaIsNotSaved() async throws {
        ReimagineStore.fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("reimagine-\(UUID()).json")
        let (service, context) = try service(survives: false)
        let run = try await service.reimagineDirections(try await service.reimagineResearch(Undercut.Target(name: "Things 3"), note: ""))
        let built = try await service.reimagineBuild(run, direction: try #require(run.directions.first))
        #expect(!built.result.review.survives && built.result.review.objection == "Families already use Cozi.")
        #expect(try context.fetch(FetchDescriptor<KillerIdea>()).isEmpty)
        ReimagineStore.deleteAll()
    }

    /// Without Claude's web search, or without a name, it stops before any paid call.
    @Test func stopsBeforeAnyPaidCall() async throws {
        let (noClaude, _) = try service(claude: false)
        await #expect(throws: UndercutError.needsClaude) { _ = try await noClaude.reimagineResearch(Undercut.Target(name: "Things 3"), note: "") }
        await #expect(throws: UndercutError.noName) { _ = try await noClaude.reimagineResearch(Undercut.Target(name: " "), note: "") }
        #expect(noClaude.undercutStep.isEmpty)
    }

    /// The country comes from the App Store link, and only two plain letters are accepted.
    @Test func readsTheStoreCountry() {
        #expect(Undercut.target(from: "https://apps.apple.com/au/app/things-3/id904237743")?.country == "au")
        #expect(Undercut.target(from: "https://apps.apple.com/app/id123456")?.country == "us")
    }
}
