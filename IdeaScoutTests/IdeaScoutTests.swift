// IdeaScoutTests.swift
// Unit tests (Swift Testing). They run inside the app on a real iPhone (the simulator on the development
// Mac hangs) and make no network calls: every source parser and AI reply is tested against small
// hand-written samples of the real formats. Keychain tests use a separate test service so they never
// touch the user's saved keys.

import Foundation
import Testing
import SwiftData
@testable import IdeaScout

/// Hacker News, GitHub parsing.
struct SourceParsingTests {
    @Test func parsesShowHN() throws {
        let json = """
        {"hits":[
          {"objectID":"1","title":"Show HN: My agent","url":"https://a.dev","points":42,"created_at_i":1760000000,"story_text":"<p>Hello &amp; welcome</p>"},
          {"objectID":"2","title":"Show HN: No link","url":null,"points":null,"created_at_i":1760000000,"story_text":null},
          {"objectID":"3","title":null,"url":null,"points":1,"created_at_i":1760000000}
        ]}
        """
        let items = try HackerNewsFetcher.parse(Data(json.utf8), as: .hackerNews)
        #expect(items.count == 2)
        #expect(items[0].title == "My agent")
        #expect(items[0].detail == "Hello & welcome")
        #expect(items[0].score == 42)
        #expect(items[1].url.absoluteString == "https://news.ycombinator.com/item?id=2")
    }

    @Test func parsesGitHub() throws {
        let json = """
        {"items":[{"id":9,"full_name":"me/tool","html_url":"https://github.com/me/tool","description":"A tool",
                   "stargazers_count":120,"created_at":"2026-10-15T08:00:00Z"}]}
        """
        let items = try GitHubFetcher.parse(Data(json.utf8), as: .vibeCode)
        #expect(items == [FetchedItem(key: "gh-9", source: .vibeCode, title: "me/tool", detail: "A tool",
                                      url: URL(string: "https://github.com/me/tool")!, score: 120,
                                      postedAt: ISO8601DateFormatter().date(from: "2026-10-15T08:00:00Z")!)])
    }

}

/// Matching AI drafts to items, the catch-all, and keyword grouping.
struct ThemeBuilderTests {
    @Test func dropsBadNumbersAndDuplicatesAndCollectsLeftovers() {
        let items = [item("a"), item("b"), item("c"), item("d")]
        let drafts = [
            ThemeDraft(title: "One", summary: "s", opportunities: ["x"], itemNumbers: [1, 2, 99, 0]),
            ThemeDraft(title: "Two", summary: "s", opportunities: [], itemNumbers: [2, 3]),
            ThemeDraft(title: "Empty", summary: "s", opportunities: [], itemNumbers: [1]),
        ]
        let built = ThemeBuilder.assemble(drafts, items: items)
        #expect(built.map(\.title) == ["One", "Two", "Other projects"])
        #expect(built[0].items.map(\.key) == ["a", "b"])
        #expect(built[0].opportunities == ["x"])
        #expect(built[1].items.map(\.key) == ["c"])
        #expect(built[2].items.map(\.key) == ["d"])
    }

    @Test func keywordFallbackGroupsByTopic() async throws {
        let items = [item("a", title: "An MCP server"), item("b", title: "LLM router"), item("c", title: "Cat photos")]
        let drafts = try await KeywordSummarizer(topics: ["llm", "mcp"]).themes(for: items)
        #expect(drafts.map(\.title) == ["Llm", "Mcp"])
        #expect(drafts.map(\.itemNumbers) == [[2], [1]])
    }
}

/// De-duplication, per-source selection and background-refresh timing.
struct DigestSelectionTests {
    @Test func dedupesByKeyAndLink() {
        let items = [item("a"), item("a"), item("b", url: "https://x.com"), item("c", url: "https://X.com")]
        #expect(DigestService.dedupe(items).map(\.key) == ["a", "b"])
    }

    @Test func selectsTopItemsPerSourceInterleaved() {
        let items = [item("g1", .github, score: 1), item("g2", .github, score: 5), item("g3", .github, score: 3),
                     item("h1", .hackerNews, score: 10)]
        #expect(DigestService.select(items, perSource: 2).map(\.key) == ["g2", "h1", "g3"])
    }

    /// Within a source, items mentioning the interest area come first, then by score.
    @Test func itemsAboutTheInterestAreaAreReadFirst() {
        let items = [item("g1", .github, score: 9, title: "A chat bot"), item("g2", .github, score: 1, title: "Quote builder for electricians"),
                     item("g3", .github, score: 5, title: "Another bot")]
        let words = AreaFocus.words(in: "Electrician quoting")
        #expect(DigestService.select(items, perSource: 2, areaWords: words).map(\.key) == ["g2", "g1"])
        #expect(DigestService.select(items, perSource: 2).map(\.key) == ["g1", "g3"])
    }

    @Test(arguments: [("Electrician quoting", ["electrician", "quot"]), ("", []), ("Apps for small business", []),
                      ("Home cooks, home cooks!", ["home", "cook"])])
    func interestAreaWords(area: String, words: [String]) {
        #expect(AreaFocus.words(in: area) == words)
    }

    @Test func nextOccurrenceIsInTheFuture() {
        let now = Date.now
        let next = DigestService.nextOccurrence(ofHour: 7, after: now)
        #expect(next > now)
        #expect(Calendar.current.component(.hour, from: next) == 7)
    }
}

/// Claude request shape and parsing of trend replies, including refusals.
struct ClaudeTests {
    @Test func requestUsesModelSchemaAndFallback() throws {
        let body = ClaudeClient.requestBody(system: "sys", prompt: "hi", schema: LLMSummarizer.themeSchema)
        #expect(body["model"] as? String == "claude-sonnet-5-5")
        #expect(body["fallbacks"] as? String == "default")
        let config = try #require(body["output_config"] as? [String: Any])
        let format = try #require(config["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(JSONSerialization.isValidJSONObject(body))
    }

    @Test func parsesThemesFromTextBlock() throws {
        let inner = #"{"themes":[{"title":"Agents","summary":"S","opportunities":["Do X"],"item_numbers":[1,3],"novelty":0,"novelty_reason":"","viability":0,"viability_reason":"","opportunity_gap":0,"opportunity_gap_reason":""}]}"#
        let response: [String: Any] = [
            "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": inner]],
            "stop_reason": "end_turn",
        ]
        let drafts = try LLMSummarizer.parseThemes(JSONSerialization.data(withJSONObject: response))
        #expect(drafts == [ThemeDraft(title: "Agents", summary: "S", opportunities: ["Do X"], itemNumbers: [1, 3])])
    }

    @Test func refusalThrows() throws {
        let response: [String: Any] = ["content": [], "stop_reason": "refusal"]
        let data = try JSONSerialization.data(withJSONObject: response)
        #expect(throws: SummarizerError.self) { try LLMSummarizer.parseThemes(data) }
    }

    @Test func promptIncludesNotes() {
        let text = Prompts.ideaText(IdeaBrief(title: "Tool", detail: "Does things", note: "For nurses"))
        #expect(text.contains("For nurses"))
    }
}

/// Saving and removing a secret (in a test-only Keychain service).
struct KeychainTests {
    /// Uses a separate test-only Keychain area so running tests never touches the user's real keys.
    static let testService = "com.mahoney.IdeaScout.tests"

    @Test func roundTrip() {
        Keychain.set("test-value", for: .openaiAPIKey, service: Self.testService)
        #expect(Keychain.get(.openaiAPIKey, service: Self.testService) == "test-value")
        // Saving again replaces the entry in place.
        #expect(Keychain.set("newer-value", for: .openaiAPIKey, service: Self.testService))
        #expect(Keychain.get(.openaiAPIKey, service: Self.testService) == "newer-value")
        Keychain.set(nil, for: .openaiAPIKey, service: Self.testService)
        #expect(Keychain.get(.openaiAPIKey, service: Self.testService) == nil)
    }
}

/// Weighted overall scores, momentum and score clamping.
struct RankingTests {
    @Test func overallIsWeightedAndSkipsMissingScores() {
        let scores = ThemeScores(novelty: 5, momentum: 1, viability: 0, gap: 3)
        #expect(scores.overall(RankWeights()) == 3.0)                                  // (5+1+3)/3, viability unscored
        #expect(scores.overall(RankWeights(novelty: 2, momentum: 0, viability: 1, gap: 1)) == 13.0 / 3.0)
        #expect(ThemeScores().overall(RankWeights()) == nil)
    }

    @Test func momentumRewardsTopItemsWithinTheirSource() {
        let all = [item("a", .github, score: 100), item("b", .github, score: 10), item("c", .github, score: 1),
                   item("h", .hackerNews, score: 3)]
        let strong = Ranking.momentum(of: [all[0]], among: all)
        let weak = Ranking.momentum(of: [all[2]], among: all)
        #expect(strong.score > weak.score)
        #expect((1...5).contains(strong.score) && (1...5).contains(weak.score))
        #expect(strong.reason.contains("1 project"))
    }

    @Test func builderAddsScoresClampsAndMarksCatchAll() {
        let items = [item("a"), item("b")]
        let draft = ThemeDraft(title: "T", summary: "s", opportunities: [], itemNumbers: [1],
                               novelty: 9, viability: 3, gap: -1, reasons: ScoreReasons(novelty: "new"))
        let built = ThemeBuilder.assemble([draft], items: items)
        #expect(built[0].scores.novelty == 5)
        #expect(built[0].scores.gap == 0)
        #expect(built[0].scores.momentum > 0)
        #expect(!built[0].reasons.momentum.isEmpty)
        #expect(built[1].isCatchAll)
    }

    @Test func claudeParsesScores() throws {
        let inner = #"{"themes":[{"title":"A","summary":"S","opportunities":[],"item_numbers":[1],"novelty":4,"novelty_reason":"n","viability":2,"viability_reason":"v","opportunity_gap":5,"opportunity_gap_reason":"g"}]}"#
        let response: [String: Any] = ["content": [["type": "text", "text": inner]], "stop_reason": "end_turn"]
        let draft = try #require(try LLMSummarizer.parseThemes(JSONSerialization.data(withJSONObject: response)).first)
        #expect((draft.novelty, draft.viability, draft.gap) == (4, 2, 5))
        #expect(draft.reasons.gap == "g")
    }
}

/// The "flesh out" prompt for saved projects.
struct FleshOutPromptTests {
    @Test func includesIdeaNotesScoresAndExtensions() {
        let stored = Item(item("gh-1", .github, title: "me/mealbot"))
        let idea = Idea(from: stored)
        idea.note = "For nurses on night shifts"
        idea.novelty = 4
        idea.opportunityGap = 5
        idea.extensions = ["Sync with rosters"]
        let prompt = Prompts.fleshOut(idea)
        #expect(prompt.contains("Idea: me/mealbot"))
        #expect(prompt.contains("My angle / notes: For nurses on night shifts"))
        #expect(prompt.contains("Novelty 4/5, Opportunity gap 5/5"))
        #expect(prompt.contains("- Sync with rosters"))
        #expect(prompt.hasSuffix(Prompts.pastedPromptNotice))
        #expect(prompt.contains("7. The next three concrete steps"))
    }
}

/// Hugging Face, DEV, the product filter and item-list formatting.
struct NewSourceTests {
    @Test func parsesHuggingFaceSpaces() throws {
        let json = """
        [{"id":"me/talkbot","likes":50,"trendingScore":221,"createdAt":"2026-10-14T23:23:19.000Z",
          "cardData":{"title":"Talk Bot","short_description":"Voice agent demo"}},
         {"id":"you/plain","likes":3,"createdAt":"2026-10-10T01:00:00.000Z"},
         {"id":"they/half","likes":9,"trendingScore":78.5,"createdAt":"2026-11-09T01:00:00.000Z"}]
        """
        let items = try HuggingFaceFetcher.parse(Data(json.utf8))
        #expect(items.count == 3)
        #expect(items[0].title == "Talk Bot")
        #expect(items[0].score == 221)
        #expect(items[0].url.absoluteString == "https://huggingface.co/spaces/me/talkbot")
        #expect(items[1].title == "you/plain")
        #expect(items[1].score == 3)
        #expect(items[2].score == 79, "a decimal trending score (seen 10 Nov 2026) must not break the source")
    }

    @Test func parsesDevTo() throws {
        let json = """
        [{"id":5,"title":"I built a CRM for plumbers","description":"Side project","url":"https://dev.to/a/crm",
          "positive_reactions_count":131,"published_at":"2026-10-18T10:55:38Z"}]
        """
        let items = try DevToFetcher.parse(Data(json.utf8))
        #expect(items.map(\.key) == ["dev-5"])
        #expect(items[0].score == 131)
    }

    @Test func productFilterDropsNoise() {
        #expect(!ProductFilter.isProductShaped(item("a", title: "me/awesome-llm-list")))
        #expect(!ProductFilter.isProductShaped(item("b", title: "my dotfiles")))
        #expect(ProductFilter.isProductShaped(item("c", title: "Invoice agent for freelancers")))
    }

    @Test func promptMarksNewItemsAndScores() {
        let fresh = FetchedItem(key: "n", source: .devTo, title: "Fresh", detail: "", url: URL(string: "https://x.dev")!,
                                score: 12, postedAt: .now)
        let list = Prompts.itemList([fresh], detailLimit: 50)
        #expect(list == "1. [Supply · DEV #showdev, score 12, new] Fresh")
    }

    @Test func momentumRewardsFreshness() {
        let old = Date.now.addingTimeInterval(-6 * 86_400)
        func make(_ k: String, _ date: Date) -> FetchedItem {
            FetchedItem(key: k, source: .github, title: k, detail: "", url: URL(string: "https://x/\(k)")!, score: 10, postedAt: date)
        }
        let all = [make("a", .now), make("b", .now), make("c", old), make("d", old)]
        #expect(Ranking.momentum(of: [all[0], all[1]], among: all).score
                >= Ranking.momentum(of: [all[2], all[3]], among: all).score)
    }
}

/// itch.io and Steam parsing.
struct GamesSourceTests {
    @Test func parsesItchFeed() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>itch</title>
        <item><title>CellZ [Free]</title><plainTitle>CellZ</plainTitle><link>https://dev.itch.io/cellz</link>
        <description><![CDATA[<p>Eat molecules &amp; evolve.</p>]]></description>
        <createDate>Mon, 19 Oct 2026 11:39:19 GMT</createDate></item>
        </channel></rss>
        """
        let items = try ItchFeed.parse(Data(xml.utf8))
        #expect(items.count == 1)
        #expect(items[0].title == "CellZ")
        #expect(items[0].detail == "Eat molecules & evolve.")
        #expect(items[0].key == "itch-dev.itch.io/cellz")
        #expect(items[0].source == .games)
    }

    @Test func parsesSteamFeaturedAndSkipsDuplicatesAndNonGames() throws {
        let json = """
        {"coming_soon":{"items":[{"id":1,"name":"Reshine","type":0},{"id":2,"name":"Soundtrack","type":1}]},
         "new_releases":{"items":[{"id":1,"name":"Reshine","type":0},{"id":3,"name":"Sky Farm","type":0}]}}
        """
        #expect(try SteamStore.parseFeatured(Data(json.utf8)).map(\.name) == ["Reshine", "Sky Farm"])
    }
}

/// Idea and review parsing, survivor selection, prompts and the leaderboard bonus.
struct KillerEngineTests {
    private func wrap(_ json: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": json]], "stop_reason": "end_turn"])
    }

    @Test func parsesCandidatesAndReviews() throws {
        let c = try KillerEngine.parseCandidates(wrap(#"{"ideas":[{"title":"Shift Meals","pitch":"p","buyer":"nurses","pricing":"$5/mo","why_now":"w","one_week_test":"t","evidence_numbers":[1],"same_as":""}]}"#))
        #expect(c.first?.title == "Shift Meals")
        let r = try KillerEngine.parseReviews(wrap(#"{"reviews":[{"title":"Shift Meals","survives":true,"objection":"o","competitors":"none found","verdict":"v","pain":4,"willing_to_pay":9,"timing":3,"gap":4,"fit":0}]}"#))
        #expect(r.first?.willingToPay == 5)
        #expect(r.first?.fit == 0)
        // An older-shaped reply has no buildability or channel score: they become 0, a weak spot.
        #expect(r.first?.buildability == 0 && r.first?.channelScore == 0)
        let full = try KillerEngine.parseReviews(wrap(#"{"reviews":[{"title":"A","survives":true,"objection":"o","competitors":"c","verdict":"v","pain":4,"willing_to_pay":4,"timing":3,"gap":4,"fit":3,"buildability":7,"channel_score":4,"evidence_needed":"e"}]}"#))
        #expect(full.first?.buildability == 5 && full.first?.channelScore == 4)
        let withChannel = try KillerEngine.parseCandidates(wrap(#"{"ideas":[{"title":"T","pitch":"p","buyer":"b","pricing":"$9","why_now":"w","one_week_test":"t","replaces":"r","channel":"Shopify App Store","evidence_numbers":[],"same_as":""}]}"#))
        #expect(withChannel.first?.channel == "Shopify App Store")
        #expect(c.first?.channel == "")
    }

    @Test func keepsSurvivorsBestFirstMaxThree() {
        func cand(_ t: String) -> KillerEngine.Candidate {
            .init(title: t, pitch: "", buyer: "", pricing: "", whyNow: "", oneWeekTest: "", evidenceNumbers: [], sameAs: "")
        }
        func rev(_ t: String, _ s: Bool, _ score: Int) -> KillerEngine.Review {
            .init(title: t, survives: s, objection: "", competitors: "", verdict: "", pain: score, willingToPay: score,
                  timing: score, gap: score, fit: score, buildability: score, channelScore: score)
        }
        let out = KillerEngine.survivors(candidates: [cand("A"), cand("B"), cand("C"), cand("D"), cand("E"), cand("F")],
                                         reviews: [rev("a", true, 3), rev("B", false, 5), rev("C", true, 3), rev("D", true, 2),
                                                   rev("E", true, 3), rev("F", true, 1)])
        // The devil's advocate rejected B, so it ranks below the ideas it backed; F isn't vibe-codable. At most three.
        #expect(Set(out.map(\.candidate.title)) == ["A", "C", "E"])
        // When few ideas are left, a rejected idea is kept, last, whatever its score.
        let few = KillerEngine.survivors(candidates: [cand("B"), cand("D"), cand("F")],
                                         reviews: [rev("B", false, 5), rev("D", true, 3), rev("F", true, 1)])
        #expect(few.map(\.candidate.title) == ["D", "B"])
    }

    @Test func promptIncludesProfileAndLeaderboard() {
        let p = KillerEngine.generatePrompt(.init(themes: [], items: [], aboutMe: "iOS dev", leaderboard: ["Shift Meals: p"]))
        #expect(p.contains("About me: iOS dev"))
        #expect(p.contains("- Shift Meals: p"))
    }

    /// Returning on more days earns no ranking bonus (owner, 13 Nov 2026): a stronger new idea stays on top.
    @Test func returningIdeasGetNoRankingBonus() {
        let old = KillerIdea(key: "old", title: "Old"), new = KillerIdea(key: "new", title: "New")
        old.engineVersion = 1; new.engineVersion = 1
        old.pain = 3; old.willingToPay = 3; old.timing = 3; old.gap = 3; old.fit = 3; old.buildability = 3; old.channelScore = 3
        new.pain = 4; new.willingToPay = 4; new.timing = 4; new.gap = 4; new.fit = 4; new.buildability = 4; new.channelScore = 4
        old.timesSeen = 20
        #expect(KillerIdea.ranksAbove(new, old) == (new.killerScore > old.killerScore))
        #expect(!KillerIdea.ranksAbove(old, new) || old.killerScore > new.killerScore)
        #expect(KillerIdea.key(for: "Shift Meals!") == KillerIdea.key(for: "shift meals"))
    }

    /// A dismissed idea comes back only with evidence it didn't have before.
    @Test(arguments: [([String](), ["a"], true), (["a"], ["a"], false), (["a"], [String](), false), (["a"], ["a", "b"], true)])
    func dismissedIdeasNeedNewEvidence(saved: [String], cited: [String], returns: Bool) {
        #expect(KillerIdea.returnsFromDismissal(saved: saved, cited: cited) == returns)
    }

    /// The Improve screen marks the version in use: the original until one is kept, then the kept round.
    @Test func versionInUseFollowsWhatWasKept() {
        let idea = KillerIdea(key: "k", title: "T")
        idea.pitch = "old pitch"; idea.buyer = "b"; idea.pricing = "$2"
        let original = IdeaVersion(idea)
        var round = original
        round.pitch = "new pitch"
        #expect(original.isInUse(by: idea, isOriginal: true) && !round.isInUse(by: idea, isOriginal: false))
        round.apply(to: idea); idea.improvedAt = .now
        #expect(!original.isInUse(by: idea, isOriginal: true) && round.isInUse(by: idea, isOriginal: false))
    }

    /// iPad comparison: a row counts as changed only if the words differ (not spacing or case); empty fields are left
    /// out; the round shown first is the kept one, otherwise the best-scoring.
    @Test func comparisonMarksRealChangesAndStartsOnTheRightRound() {
        let idea = KillerIdea(key: "k", title: "T")
        idea.pitch = "Chases  unpaid invoices"; idea.buyer = "Trades"; idea.pricing = "$9 a month"
        let original = IdeaVersion(idea)
        var better = original, worse = original
        better.pitch = "chases unpaid invoices"; better.buyer = "Sole traders"; better.pain = 5; better.gap = 5
        worse.pricing = "$4 once"
        let rows = ComparisonRow.rows(original: original, round: better)
        #expect(rows.first { $0.label == "Pitch" }?.changed == false && rows.first { $0.label == "Who pays" }?.changed == true)
        #expect(!rows.contains { $0.label == "Where to find buyers" })
        let run = IdeaImprover.Run(versions: [original, better, worse], stop: nil)
        #expect(ComparisonRow.initialRound(run, inUse: { _, _ in false }) == (better.score >= worse.score ? 1 : 2))
        #expect(ComparisonRow.initialRound(run, inUse: { _, index in index == 2 }) == 2)
    }

    @Test func parsesPainPointComment() throws {
        let json = #"{"hits":[{"objectID":"9","title":null,"url":null,"points":null,"created_at_i":1760000000,"comment_text":"I wish there was a tool for rosters","story_title":"Ask HN: Nurses"}]}"#
        let items = try HackerNewsFetcher.parse(Data(json.utf8), as: .painPoints)
        #expect(items.first?.title == "I wish there was a tool for rosters")
        #expect(items.first?.detail == "In thread: Ask HN: Nurses")
    }
}

/// Token costs and spending summaries.
struct UsageTrackerTests {
    @Test func parsesUsageAndCost() throws {
        let data = try JSONSerialization.data(withJSONObject: ["usage": ["input_tokens": 1_000_000, "output_tokens": 100_000,
                                                                         "cache_read_input_tokens": 0]])
        let usage = try #require(UsageTracker.parseUsage(data))
        #expect(usage.calls == 1)
        #expect(abs(usage.cost - 6.0) < 0.0001)   // $4 in + $2 out
    }

    @Test func summarisesTodayMonthAndFeatures() {
        let now = ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z")!
        let ledger: UsageTracker.Ledger = [
            UsageTracker.dayKey(now): ["Trends": .init(input: 1_000_000, calls: 1)],
            "2026-10-01": ["Killer ideas": .init(output: 100_000, calls: 1)],
            "2026-09-30": ["Trends": .init(input: 1_000_000, calls: 1)],
        ]
        let s = UsageTracker.summary(ledger, now: now)
        #expect(abs(s.today.cost - 4) < 0.0001)
        #expect(abs(s.thisMonth.cost - 6) < 0.0001)
        #expect(abs(s.allTime.cost - 10) < 0.0001)
        #expect(s.byFeatureThisMonth.map(\.feature) == ["Trends", "Killer ideas"])
    }
}

/// Translations and the English-language filter.
struct EnglishOnlyTests {
    @Test func appliesClaudeTranslations() throws {
        let inner = #"{"themes":[],"translations":[{"number":2,"title":"Video generator","description":"Makes short videos"}]}"#
        let data = try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": inner]], "stop_reason": "end_turn"])
        let translations = try LLMSummarizer.parseTranslations(data)
        let items = Translations.apply(translations, to: [item("a", title: "English tool"), item("b", title: "视频生成器")])
        #expect(items.map(\.title) == ["English tool", "Video generator"])
        #expect(items[1].detail == "Makes short videos")
    }

    @Test func languageFilterDropsClearlyForeignAndKeepsEnglishOrShortNames() {
        func make(_ title: String, _ detail: String) -> FetchedItem {
            FetchedItem(key: title, source: .huggingFace, title: title, detail: detail, url: URL(string: "https://x.dev")!,
                        score: 0, postedAt: .now)
        }
        #expect(!LanguageFilter.isEnglishOrUnclear(make("视频生成", "这是一个可以根据文字描述自动生成短视频的人工智能工具")))
        #expect(LanguageFilter.isEnglishOrUnclear(make("Invoice agent", "Automatically chases unpaid invoices for freelancers")))
        #expect(LanguageFilter.isEnglishOrUnclear(make("CellZ", "")))
    }

    @Test func schemaRequiresTranslations() {
        let required = LLMSummarizer.themeSchema["required"] as? [String]
        #expect(required?.contains("translations") == true)
    }
}

/// Near-misses are kept, the principles rank rather than drop (only vibe-codable is a must), and trends hidden below the bar.
struct QualityBarTests {
    private func cand(_ t: String) -> KillerEngine.Candidate {
        .init(title: t, pitch: "", buyer: "", pricing: "", whyNow: "", oneWeekTest: "", evidenceNumbers: [], sameAs: "")
    }

    /// Owner's decision (11 Nov 2026): the five principles score and rank; only "vibe-codable" drops an idea.
    @Test func principlesRankButOnlyVibeCodableDrops() {
        let strong = KillerEngine.Review(title: "Strong", survives: true, objection: "", competitors: "", verdict: "",
                                         pain: 4, willingToPay: 4, timing: 4, gap: 4, fit: 4,
                                         buildability: 4, channelScore: 4)
        let average = KillerEngine.Review(title: "Average", survives: true, objection: "", competitors: "", verdict: "",
                                          pain: 3, willingToPay: 3, timing: 3, gap: 3, fit: 3,
                                          buildability: 3, channelScore: 3)
        let weakSpot = KillerEngine.Review(title: "Weak spot", survives: true, objection: "", competitors: "", verdict: "",
                                           pain: 5, willingToPay: 1, timing: 5, gap: 5, fit: 5,
                                           buildability: 5, channelScore: 5)
        var hard = strong
        hard.title = "Hard to build"
        hard.buildability = 2
        let out = KillerEngine.survivors(candidates: [cand("Strong"), cand("Average"), cand("Weak spot"), cand("Hard to build")],
                                         reviews: [strong, average, weakSpot, hard])
        #expect(Set(out.map(\.candidate.title)) == ["Strong", "Average", "Weak spot"], "a weak spot no longer drops an idea")
        #expect(out.first?.candidate.title == "Strong")
        // Without pain-point evidence, pain and willingness to pay are capped at 3.
        #expect(out[0].review.pain == 3 && out[0].review.willingToPay == 3)
    }

    @Test func themeClearsBar() {
        let good = Theme(title: "Good", summary: "", order: 0, opportunities: [])
        good.apply(ThemeScores(novelty: 4, momentum: 4, viability: 4, gap: 4), ScoreReasons())
        let weak = Theme(title: "Weak", summary: "", order: 1, opportunities: [])
        weak.apply(ThemeScores(novelty: 2, momentum: 3, viability: 3, gap: 2), ScoreReasons())
        let unscored = Theme(title: "Keyword", summary: "", order: 2, opportunities: [])
        let other = Theme(title: "Other", summary: "", order: 3, opportunities: [])
        other.isCatchAll = true
        #expect(good.clears(3.5, weights: RankWeights()))
        #expect(!weak.clears(3.5, weights: RankWeights()))
        #expect(unscored.clears(3.5, weights: RankWeights()))
        #expect(!other.clears(3.5, weights: RankWeights()))
        #expect(other.clears(0, weights: RankWeights()))
    }
}

/// App Store top paid, research papers and Lobsters.
struct MoreSourcesTests {
    @Test func parsesAppStoreTopPaid() throws {
        let json = """
        {"feed":{"results":[{"id":"932747118","name":"Shadowrocket","artistName":"Shadow Launch","url":"https://apps.apple.com/us/app/id932747118","genres":[]},
                            {"id":"2","name":"AnkiMobile","url":"https://apps.apple.com/us/app/id2","genres":[{"name":"Education"}]}]}}
        """
        let items = try AppStoreFetcher.parse(Data(json.utf8), postedAt: .now)
        #expect(items.map(\.score) == [2, 1])
        #expect(items[0].detail == "#1 top paid iPhone app, by Shadow Launch")
        #expect(items[1].detail == "#2 top paid iPhone app in Education")
    }

    @Test func parsesDailyPapers() throws {
        let json = """
        [{"paper":{"id":"2610.22697","title":"Securing Agentic Browsing","summary":"Long abstract","ai_summary":"Short summary","upvotes":12},
          "publishedAt":"2026-10-14T20:00:00.000Z"}]
        """
        let items = try ResearchFetcher.parse(Data(json.utf8))
        #expect(items.first?.detail == "Short summary")
        #expect(items.first?.url.absoluteString == "https://huggingface.co/papers/2610.22697")
        #expect(items.first?.score == 12)
    }

    @Test func parsesLobstersWithOffsetDates() throws {
        let json = """
        [{"short_id":"ireiaf","title":"DelightQL","url":"","comments_url":"https://lobste.rs/s/ireiaf","score":7,
          "created_at":"2026-10-14T13:41:38.972-05:00","description_plain":"A query language"}]
        """
        let items = try LobstersFetcher.parse(Data(json.utf8))
        #expect(items.first?.url.absoluteString == "https://lobste.rs/s/ireiaf")
        let expected = ISO8601DateFormatter().date(from: "2026-10-14T18:41:38Z")!.addingTimeInterval(0.972)
        #expect(abs((items.first?.postedAt ?? .distantPast).timeIntervalSince(expected)) < 0.001)
    }
}

/// Streaming, retries, digest replacement rules, the spending limit and reply length.
struct ReliabilityTests {
    @Test func rebuildsStreamedReplyAcrossBlocks() throws {
        let lines = [
            "event: message_start",
            #"data: {"type":"message_start","message":{"usage":{"input_tokens":1000,"output_tokens":1}}}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"{\"suggestions\":"}}"#,
            #"data: {"type":"content_block_start","index":2,"content_block":{"type":"fallback"}}"#,
            #"data: {"type":"content_block_start","index":3,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"[\"a\"]}"}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":500}}"#,
            #"data: {"type":"message_stop"}"#,
        ]
        var stream = StreamAssembler()
        for line in lines { try stream.consume(line) }
        let data = try stream.response()
        #expect(String(decoding: try LLMSummarizer.extractJSON(data), as: UTF8.self) == #"{"suggestions":["a"]}"#)
        let usage = try #require(UsageTracker.parseUsage(data))
        #expect(usage.input == 1000 && usage.output == 500)
    }

    @Test func streamErrorsAndEarlyEndsAreRetryable() throws {
        var stream = StreamAssembler()
        #expect(throws: StreamAssembler.StreamError.self) {
            try stream.consume(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        }
        #expect(throws: StreamAssembler.StreamError.self) { try StreamAssembler().response() }
        #expect(LLMRetry.isRetryable(StreamAssembler.StreamError(message: "x")))
    }

    /// Money: a server-side fallback is charged at the price of the model that actually answered.
    @Test func fallbackIsPricedAtTheServingModel() throws {
        var stream = StreamAssembler()
        for line in [#"data: {"type":"message_start","message":{"model":"claude-sonnet-5-5","usage":{"input_tokens":10}}}"#,
                     #"data: {"type":"content_block_start","index":0,"content_block":{"type":"fallback","from":{"model":"claude-sonnet-5-5"},"to":{"model":"claude-opus-4-8"}}}"#,
                     #"data: {"type":"message_stop"}"#] {
            try stream.consume(line)
        }
        #expect(stream.model == "claude-opus-4-8")
        let chosen = ModelPrice(input: 2, output: 10, cachedInput: 0.2)
        #expect(ClaudeClient.price(servedBy: stream.model, chosen: "claude-sonnet-5-5", chosenPrice: chosen) == ModelPrice(input: 5, output: 25))
        #expect(ClaudeClient.price(servedBy: "claude-sonnet-5-5", chosen: "claude-sonnet-5-5", chosenPrice: chosen) == chosen)
        #expect(ClaudeClient.price(servedBy: nil, chosen: "claude-sonnet-5-5", chosenPrice: chosen) == chosen)
        #expect(ClaudeClient.price(servedBy: "claude-unknown-9", chosen: "claude-sonnet-5-5", chosenPrice: chosen) == chosen)
    }

    /// Security: stored error details never keep key-like text.
    @Test func errorDetailsHideKeys() {
        let raw = #"{"error":{"message":"Incorrect API key provided: sk-proj-abc123XYZ789secret. Header Bearer eyJhbGciOiJIUzI1NiJ9.payload","code":"invalid_api_key"}}"#
        let shown = LLMHTTPError(status: 401, retryAfter: nil, detail: raw).technicalDetail
        #expect(!shown.contains("abc123XYZ789secret"))
        #expect(!shown.contains("eyJhbGciOiJIUzI1NiJ9"))
        #expect(shown.contains("HTTP 401"))
        #expect(shown.contains("invalid_api_key"))
        #expect(LLMHTTPError.redacted("key AIzaSyA1234567890abcdefXYZ here").contains("[hidden]"))
        #expect(LLMHTTPError.redacted("plain message") == "plain message")
    }

    @Test func retriesOnlyTemporaryProblems() {
        #expect(LLMRetry.isRetryable(URLError(.networkConnectionLost)))
        #expect(LLMRetry.isRetryable(URLError(.timedOut)))
        #expect(LLMRetry.isRetryable(LLMHTTPError(status: 529, retryAfter: nil, detail: "")))
        #expect(LLMRetry.isRetryable(LLMHTTPError(status: 503, retryAfter: nil, detail: "")))
        #expect(!LLMRetry.isRetryable(LLMHTTPError(status: 401, retryAfter: nil, detail: "")))
        #expect(!LLMRetry.isRetryable(LLMHTTPError(status: 400, retryAfter: nil, detail: "")))
        #expect(!LLMRetry.isRetryable(SummarizerError.refused))
        #expect(LLMRetry.retryDelay(attempt: 0, retryAfter: nil, jitter: 0) == 3)
        #expect(LLMRetry.retryDelay(attempt: 1, retryAfter: nil, jitter: 0) == 15)
        #expect(LLMRetry.retryDelay(attempt: 0, retryAfter: 120, jitter: 0) == 30)
    }

    /// An empty Anthropic account is a plain 400; the message must say "out of credit", not blame the model name.
    @Test func outOfCreditSaysSo() {
        let reply = #"{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits."},"request_id":"req_x"}"#
        let message = LLMHTTPError(status: 400, retryAfter: nil, detail: reply).errorDescription ?? ""
        #expect(message.contains("out of credit"))
        #expect(!message.contains("model name"))
        #expect(LLMHTTPError(status: 400, retryAfter: nil, detail: "bad field").errorDescription?.contains("out of credit") == false)
    }

    @Test func neverReplacesABetterDigest() {
        #expect(!DigestService.shouldReplace(existing: "Claude", with: "Keywords"))
        #expect(!DigestService.shouldReplace(existing: "Claude", with: "Apple on-device"))
        #expect(DigestService.shouldReplace(existing: "Keywords", with: "Claude"))
        #expect(DigestService.shouldReplace(existing: "Claude", with: "Claude"))
        #expect(DigestService.isCancellation(URLError(.cancelled)))
        #expect(!DigestService.isCancellation(URLError(.networkConnectionLost)))
    }

    @Test func dailySpendingCap() {
        #expect(AppSettings.overCap(spent: 0.41, cap: 0.40))
        #expect(!AppSettings.overCap(spent: 0.39, cap: 0.40))
        #expect(!AppSettings.overCap(spent: 5, cap: 0))   // 0 = no limit
    }

    /// Money: limits saved from the older $0.20–$2 choices move up onto $1–$10; "No limit" stays.
    @Test(arguments: [(0.0, 0.0), (0.2, 1.0), (0.6, 1.0), (1.0, 1.0), (2.0, 2.0), (4.0, 5.0), (25.0, 10.0)])
    func oldDailyLimitsMoveToCurrentChoices(saved: Double, expected: Double) {
        #expect(AppSettings.currentCapChoice(saved) == expected)
    }

    /// Money: "Suggest variants" shows an honest price before the paid request.
    @Test func suggestionCostEstimate() {
        // Claude Sonnet 5.5 ($2 in / $10 out per million): 1,500 × 2 + 1,500 × 10 = $0.018.
        let sonnet = AppSettings.estimatedSuggestionCost(price: ModelPrice(input: 2, output: 10))
        #expect(abs(sonnet - 0.018) < 0.000_001)
        #expect(AppSettings.approximateCostText(sonnet).contains("0.02"))
        #expect(AppSettings.approximateCostText(sonnet).hasPrefix("~"))
        // Very cheap models don't show a misleading "$0.00".
        #expect(AppSettings.approximateCostText(AppSettings.estimatedSuggestionCost(price: ModelPrice(input: 0.3, output: 1.2))) == "<$0.01")
        #expect(AppSettings.estimatedSuggestionCost(price: ModelPrice(input: 0, output: 0)) == 0)
    }

    /// Money: typed-in prices can't switch off the daily limit by going negative.
    @Test func customPricesCannotBeNegative() {
        #expect(AppSettings.sanitizedPrice(-3) == 0)
        #expect(AppSettings.sanitizedPrice(.nan) == 0)
        #expect(AppSettings.sanitizedPrice(.infinity) == 0)
        #expect(AppSettings.sanitizedPrice(1.25) == 1.25)
    }

    /// Accuracy: Claude prices match Anthropic's list (rechecked 11 Nov 2026: Sonnet 5.5's cache reads are $0.10), and
    /// labels compare with the default (Sonnet).
    @Test func claudePricesMatchAnthropicList() throws {
        let models = AIProvider.claude.models
        let sonnet = try #require(models.first { $0.id == "claude-sonnet-5-5" })
        let opus = try #require(models.first { $0.id == "claude-opus-5-5" })
        let fable = try #require(models.first { $0.id == "claude-fable-5-2" })
        #expect(sonnet.price == ModelPrice(input: 2, output: 10, cachedInput: 0.1))
        #expect(opus.price == ModelPrice(input: 4, output: 20, cachedInput: 0.2))
        #expect(fable.price == ModelPrice(input: 8, output: 40, cachedInput: 0.2))
        #expect(opus.label.contains("\(Int(opus.price.input / sonnet.price.input))× cost"))
        #expect(fable.label.contains("\(Int(fable.price.input / sonnet.price.input))× cost"))
    }

    @Test func requestsAllowLongReplies() {
        let body = ClaudeClient.requestBody(system: "s", prompt: "p", schema: [:])
        #expect(body["max_tokens"] as? Int == 32000)
    }
}

/// Evidence caps, the devil's-advocate prompt, days seen and complaint snippets.
struct BestIdeaTests {
    private func cand(_ t: String, evidence: [Int]) -> KillerEngine.Candidate {
        .init(title: t, pitch: "", buyer: "", pricing: "", whyNow: "", oneWeekTest: "check", evidenceNumbers: evidence, sameAs: "")
    }

    @Test func evidenceUnlocksHighPainAndPayScores() {
        let review = KillerEngine.Review(title: "A", survives: true, objection: "", competitors: "", verdict: "",
                                         pain: 5, willingToPay: 5, timing: 4, gap: 4, fit: 4,
                                         buildability: 4, channelScore: 4)
        let items = [item("p", .painPoints), item("y", .ycombinator), item("g", .github)]
        // One supporting item allows a 4; a 5 needs two different ones.
        let withPain = KillerEngine.survivors(candidates: [cand("A", evidence: [1])], reviews: [review], items: items)
        #expect(withPain.first?.review.pain == 4 && withPain.first?.review.willingToPay == 4)
        let twoItems = items + [item("p2", .appReviews)]
        let withTwo = KillerEngine.survivors(candidates: [cand("A", evidence: [1, 4])], reviews: [review], items: twoItems)
        #expect(withTwo.first?.review.pain == 5 && withTwo.first?.review.willingToPay == 5)
        let withYC = KillerEngine.survivors(candidates: [cand("A", evidence: [2])], reviews: [review], items: items)
        #expect(withYC.first?.review.pain == 3 && withYC.first?.review.willingToPay == 4)
        let supplyOnly = KillerEngine.survivors(candidates: [cand("A", evidence: [3, 99])], reviews: [review], items: items)
        #expect(supplyOnly.first?.review.pain == 3 && supplyOnly.first?.review.willingToPay == 3)
    }

    @Test func critiqueSeesEvidenceAndTest() {
        let items = [FetchedItem(key: "p", source: .painPoints, title: "Our rostering is a spreadsheet nightmare",
                                 detail: "In thread: Ask HN", url: URL(string: "https://x.dev")!, score: 0, postedAt: .now)]
        var c = cand("Roster AI", evidence: [1])
        c.replaces = "Weekly spreadsheet rostering"
        let prompt = KillerEngine.critiquePrompt([c], items: items, aboutMe: "")
        #expect(prompt.contains("- [Pain points] Our rostering is a spreadsheet nightmare"))
        #expect(prompt.contains("One-week test: check"))
        #expect(prompt.contains("Replaces: Weekly spreadsheet rostering"))
        #expect(KillerEngine.critiqueInstructions.contains("Give a price only if you are sure of it, otherwise 0"))
    }

    @Test func ideasAreListedOnEveryDayTheyWereSeen() {
        let cal = Calendar.current
        let monday = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 9))!
        let wednesday = cal.date(byAdding: .day, value: 2, to: monday)!
        let tuesday = cal.date(byAdding: .day, value: 1, to: monday)!
        let idea = KillerIdea(key: "a", title: "A")
        idea.firstSeen = monday; idea.lastSeen = monday
        // Before days were recorded: first and last day only.
        #expect(idea.wasSeen(on: monday) && !idea.wasSeen(on: wednesday))
        idea.recordSeen(on: wednesday)
        idea.lastSeen = wednesday
        idea.recordSeen(on: wednesday)   // same day twice is stored once
        #expect(idea.daysSeen.count == 2)
        #expect(idea.wasSeen(on: monday) && idea.wasSeen(on: wednesday) && !idea.wasSeen(on: tuesday))

        let strong = KillerIdea(key: "b", title: "B"); strong.firstSeen = wednesday; strong.lastSeen = wednesday; strong.pain = 5
        #expect(KillerIdea.seen(on: wednesday, in: [idea, strong]).map(\.key) == ["b", "a"])
        #expect(KillerIdea.seen(on: tuesday, in: [idea, strong]).isEmpty)
    }

    @Test func painCommentTitleKeepsTheComplaint() throws {
        let long = String(repeating: "Some unrelated context about my week. ", count: 10)
            + "Honestly QuickBooks is too expensive for what it does and I'd switch tomorrow."
        let json = try JSONSerialization.data(withJSONObject: ["hits": [["objectID": "1", "created_at_i": 1760000000,
                                                                         "comment_text": long, "story_title": "Ask HN"]]])
        let items = try HackerNewsFetcher.parse(json, as: .painPoints, around: PainPointsFetcher.plainPhrases)
        let title = try #require(items.first?.title)
        #expect(title.contains("too expensive"))
        #expect(title.count <= 220)
        #expect(!PainPointsFetcher.phrases.contains("\"is there a tool\""))
    }
}

/// Developer sources off by default and the money-making rules in the prompts.
struct BusinessFocusTests {
    @Test func developerSourcesOffByDefault() {
        #expect(!SourceKind.games.enabledByDefault)
        #expect(!SourceKind.devTo.enabledByDefault)
        #expect(!SourceKind.lobsters.enabledByDefault)
        #expect(!SourceKind.huggingFace.enabledByDefault)
        #expect(SourceKind.painPoints.enabledByDefault && SourceKind.wordpressReviews.enabledByDefault)
        // Builder-side sources and out-of-reach government contracts start off for a solo builder.
        #expect(!SourceKind.github.enabledByDefault && !SourceKind.hackerNews.enabledByDefault)
        #expect(!SourceKind.research.enabledByDefault && !SourceKind.ausTender.enabledByDefault)
        #expect(SourceKind.appReviews.enabledByDefault && !SourceKind.atlassian.enabledByDefault)
        #expect(SourceKind.consumerReviews.enabledByDefault && SourceKind.consumerReviews.signal == .demand)
        #expect(SourceKind.consumerReviews.rawValue == "consumerReviews", "stored in the database: never rename")
        #expect(SourceKind.vibeCode.enabledByDefault && SourceKind.fieldNotes.enabledByDefault)
    }

    /// Owner's decision (10 Nov 2026): buyers can be businesses or consumers, but the idea must make money.
    @Test func promptsAimAtBuyersWhoPay() {
        #expect(KillerEngine.generateInstructions.contains("At most 1 of the 5 may be a tool for software developers"))
        #expect(KillerEngine.generateInstructions.contains("Someone must pay for it"))
        #expect(KillerEngine.generateInstructions.contains("or a consumer"))
        #expect(KillerEngine.critiqueInstructions.contains("no clear buyer who would pay"))
        // Source labels in prompts must match SourceKind.label.
        for text in [KillerEngine.generateInstructions, Prompts.themeInstructions] {
            #expect(text.contains("\"\(SourceKind.consumerReviews.label)\"") && text.contains("\"\(SourceKind.wordpressReviews.label)\""))
            #expect(!text.contains("\"\(SourceKind.ycombinator.label)\""), "no longer read")
        }
        for text in [KillerEngine.generateInstructions, KillerEngine.critiqueInstructions, Prompts.themeInstructions] {
            #expect(!text.contains("Never hobbyists or consumers") && !text.contains("consumer novelties"))
        }
        let required = (((KillerEngine.candidateSchema["properties"] as? [String: Any])?["ideas"] as? [String: Any])?["items"] as? [String: Any])?["required"] as? [String]
        #expect(required?.contains("replaces") == true)
    }
}

/// Look-back windows and scan defaults.
struct ScanSettingsTests {
    @Test func windowsAndDefaults() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(DigestService.windowStart(days: 14, now: now) == now.addingTimeInterval(-14 * 86400))
        #expect(AppSettings.defaultTrendWindowDays == 7)
        #expect(AppSettings.defaultPainWindowDays == 14)
        #expect(AppSettings.defaultClaudeMaxItems == 300)
        let opus = AppSettings.refreshReferencePrice
        #expect(AppSettings.estimatedRefreshCost(items: 300, price: opus).lowerBound
                < AppSettings.estimatedRefreshCost(items: 500, price: opus).lowerBound)
    }

    /// The refresh estimate follows the chosen model's price, and a free refresh says so. Compares dollars,
    /// because the currency text depends on the device's region ("$0.45" or "USD 0.45").
    @Test(arguments: [
        (ModelPrice(input: 4, output: 20), 0.453),    // Claude Opus: the measured reference
        (ModelPrice(input: 2, output: 10), 0.2265),   // Claude Sonnet, GPT-6.1 Sol
        (ModelPrice(input: 10, output: 50), 1.1325),  // GPT-6 Astra
        (ModelPrice(input: 0, output: 0), 0),         // free-within-limits models
    ])
    func refreshEstimateFollowsModelPrice(price: ModelPrice, dollars: Double) {
        let high = AppSettings.estimatedRefreshCost(items: 300, price: price).upperBound
        #expect(abs(high - dollars) < 0.001)
        #expect(AppSettings.refreshCostText(items: 300, price: price) == AppSettings.approximateCostText(high))
    }

    @Test func refreshWithoutPaidModelIsFree() {
        #expect(AppSettings.refreshCostText(items: 300, price: nil) == "Free")
    }
}

/// iPad layout: lists keep the system margins until the window is wider than the readable column.
struct ReadableWidthTests {
    @Test(arguments: [(CGFloat(390), CGFloat(0)), (700, 0), (1032, 166), (1366, 333)])
    func listMarginCentresAReadableColumn(width: CGFloat, margin: CGFloat) {
        #expect(abs(ReadableListMargins.margin(for: width) - margin) < 0.001)
    }
}

/// Demand sources, signal-based selection, pain clusters and noise.
struct DemandSourceTests {
    @Test func fieldNotesBecomeDemandItems() {
        let items = FieldNotesFetcher.items(from: "Timesheets re-keyed into SAP\n\n  Meter data chased by email  ", postedAt: .now)
        #expect(items.map(\.title) == ["Timesheets re-keyed into SAP", "Meter data chased by email"])
        #expect(items.allSatisfy { $0.source == .fieldNotes && $0.source.signal == .demand })
        #expect(Set(items.map(\.key)).count == 2)
    }

    @Test func parsesTopGrossingChartAndRotatesApps() throws {
        let chart = """
        {"feed":{"entry":[{"im:name":{"label":"LinkedIn"},"id":{"label":"x","attributes":{"im:id":"1"}}},
                          {"im:name":{"label":"Xero"},"id":{"label":"x","attributes":{"im:id":"2"}}}]}}
        """
        let apps = try AppReviewsFetcher.parseChart(Data(chart.utf8), country: "au", genre: "Business")
        #expect(apps.map(\.name) == ["LinkedIn", "Xero"])
        #expect(apps[1].rank == 2)
    }

    @Test func keepsOnlyRecentLowStarReviews() throws {
        let json = """
        {"feed":{"entry":[
          {"id":{"label":"1"},"title":{"label":"Too expensive now"},"content":{"label":"Price doubled, moving to a spreadsheet"},"im:rating":{"label":"1"},"updated":{"label":"2026-10-20T10:00:00-07:00"}},
          {"id":{"label":"2"},"title":{"label":"Great"},"content":{"label":"Love it"},"im:rating":{"label":"5"},"updated":{"label":"2026-10-20T10:00:00-07:00"}},
          {"id":{"label":"3"},"title":{"label":"Old moan"},"content":{"label":"Bad"},"im:rating":{"label":"2"},"updated":{"label":"2025-01-01T10:00:00-07:00"}}]}}
        """
        let app = AppReviewsFetcher.App(id: "9", name: "Xero", country: "au", genre: "Business", rank: 7)
        let since = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!
        let items = try AppReviewsFetcher.parseReviews(Data(json.utf8), app: app, since: since)
        #expect(items.count == 1)
        #expect(items[0].title == "Xero: Too expensive now")
        #expect(items[0].detail.hasPrefix("★1 review (#7 top-grossing Business, AU): Price doubled"))
    }

    @Test func parsesAtlassianAddons() throws {
        let json = """
        {"_embedded":{"addons":[{"id":"5","name":"Daily Worklog","tagLine":"Log time fast","_links":{"alternate":{"href":"/apps/5/daily-worklog"}},
          "_embedded":{"categories":[{"name":"Time tracking"}],"distribution":{"totalInstalls":12}}}]}}
        """
        let items = try AtlassianFetcher.parse(Data(json.utf8), label: "new", postedAt: .now)
        #expect(items.first?.title == "Daily Worklog")
        #expect(items.first?.detail == "Log time fast (new Jira/Confluence app, 12 installs; Time tracking)")
        #expect(items.first?.url.absoluteString == "https://marketplace.atlassian.com/apps/5/daily-worklog")
    }

    @Test func keepsOnlyITContractsFromAusTender() throws {
        let json = """
        {"releases":[
          {"parties":[{"name":"Hays","roles":["supplier"]},{"name":"MDBA","roles":["procuringEntity"]}],
           "contracts":[{"id":"CN1","description":"Temporary personnel","items":[{"classification":{"id":"80111600"}}],"value":{"amount":"473917.25"}}]},
          {"parties":[{"name":"Acme IT","roles":["supplier"]},{"name":"Dept of Energy","roles":["procuringEntity"]}],
           "contracts":[{"id":"CN2","description":"Asset management software licences","dateSigned":"2026-10-21T23:23:09Z","items":[{"classification":{"id":"43231500"}}],"value":{"amount":"250000"}}]}],
         "links":{"next":"https://api.tenders.gov.au/next"}}
        """
        let page = try AusTenderFetcher.parse(Data(json.utf8))
        #expect(page.items.map(\.title) == ["Asset management software licences"])
        #expect(page.items[0].detail == "Dept of Energy paid AUD \(250000.formatted()) to Acme IT")
        #expect(page.items[0].score == 250)
        #expect(page.next?.absoluteString == "https://api.tenders.gov.au/next")
    }

    @Test func selectionReservesSharesBySignal() {
        let supply = (0..<200).map { item("s\($0)", .github) }
        let demand = (0..<50).map { item("d\($0)", .painPoints) }
        let timing = (0..<10).map { item("t\($0)", .ycombinator) }
        let notes = [item("n1", .fieldNotes)]
        let out = DigestService.selectBySignal(supply + demand + timing + notes, maxItems: 101)
        #expect(out.count == 101)
        #expect(out.first?.source == .fieldNotes)
        let bySignal = Dictionary(grouping: out.dropFirst(), by: \.source.signal).mapValues(\.count)
        // 100 slots: demand 40, supply 40, timing 20; timing has only 10, so the spare goes to demand first.
        #expect(bySignal[.demand] == 50)
        #expect(bySignal[.timing] == 10)
        #expect(bySignal[.supply] == 40)
    }

    @Test func clustersAndNoiseAreAssembled() throws {
        let inner = #"{"themes":[],"translations":[],"pain_clusters":[{"title":"Re-keying timesheets","buyer":"Payroll officer at a contractor firm","workaround":"Excel every Friday","pay_signals":"none seen","summary":"s","item_numbers":[1,2]}],"noise_numbers":[3]}"#
        let data = try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": inner]], "stop_reason": "end_turn"])
        let clusters = try LLMSummarizer.parseClusters(data)
        #expect(clusters.first?.isPainCluster == true)
        let built = ThemeBuilder.assemble(clusters, items: [item("a", .painPoints), item("b", .fieldNotes), item("c"), item("d")],
                                          noise: try LLMSummarizer.parseNoise(data))
        #expect(built.first?.isPainCluster == true && built.first?.buyer == "Payroll officer at a contractor firm")
        #expect(built.first?.scores == ThemeScores())
        #expect(built.last?.isCatchAll == true && built.last?.items.map(\.key) == ["d"])
        let required = LLMSummarizer.themeSchema["required"] as? [String]
        #expect(required == ["themes", "translations", "pain_clusters", "noise_numbers"])
    }

    @Test func complaintsUnlockPainAndPayScores() {
        let review = KillerEngine.Review(title: "A", survives: true, objection: "", competitors: "", verdict: "",
                                         pain: 5, willingToPay: 5, timing: 4, gap: 4, fit: 4,
                                         buildability: 4, channelScore: 4)
        let capped = KillerEngine.capped(review, evidence: [item("r", .appReviews), item("r2", .appReviews)])
        #expect(capped.pain == 5 && capped.willingToPay == 5)
        let tender = KillerEngine.capped(review, evidence: [item("t", .ausTender)])
        #expect(tender.pain == 3 && tender.willingToPay == 4)
    }

    @Test func demandItemsKeepMoreText() {
        let long = String(repeating: "x", count: 400)
        let d = FetchedItem(key: "d", source: .appReviews, title: "T", detail: long, url: URL(string: "https://x.dev")!, score: 0, postedAt: .distantPast)
        let s = FetchedItem(key: "s", source: .github, title: "T", detail: long, url: URL(string: "https://y.dev")!, score: 0, postedAt: .distantPast)
        let lines = Prompts.itemList([d, s], detailLimit: 200).split(separator: "\n")
        #expect(lines[0].hasPrefix("1. [Demand · App Store complaints] T"))
        #expect(lines[0].filter { $0 == "x" }.count == 300)
        #expect(lines[1].filter { $0 == "x" }.count == 140)
    }
}

/// Provider catalogue, OpenAI-style requests per model, reply conversion and costs.
struct ProviderChoiceTests {
    private let schema: [String: Any] = ["type": "object", "properties": ["a": ["type": "string"]], "required": ["a"],
                                         "additionalProperties": false]

    @Test func everyCloudProviderHasARecommendedModelKeyAndAddress() {
        for provider in AIProvider.allCases where provider.isCloud {
            #expect(!provider.recommendedModel.isEmpty)
            #expect(provider.keychainKey != nil)
            if provider != .claude { #expect(provider.chatURL != nil) }
        }
        #expect(AIProvider.claude.recommendedModel == ScanStep.mixedModel, "Mixed is the default (owner, 13 Nov 2026)")
        #expect(AIProvider.claude.models.map(\.id)
                == [ScanStep.mixedModel, "claude-sonnet-5-5", "claude-haiku-5-5", "claude-opus-5-5", "claude-fable-5-2"])
        #expect(AIProvider.openai.recommendedModel == "gpt-6.1-sol")
        #expect(Set(AIProvider.allCases.compactMap(\.keychainKey)).count == 9)
        #expect(AIProvider.grok.recommendedModel == "grok-4.3")
        #expect(AIProvider.deepseek.recommendedModel == "deepseek-flash")
        #expect(AIProvider.gemini.models.map(\.id).contains("gemma-4-31b-it"))
        #expect(AIProvider.kimi.country == "China" && AIProvider.claude.country == "USA")
    }

    @Test func strictSchemaRequestForOpenAIStyleProviders() throws {
        let body = OpenAICompatibleClient.requestBody(provider: .openai, model: "gpt-6.1-sol", system: "sys", prompt: "hi",
                                                      schema: schema, effort: "high")
        let format = try #require(body["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect((format["json_schema"] as? [String: Any])?["strict"] as? Bool == true)
        #expect(body["max_completion_tokens"] as? Int == 32000)
        #expect(body["reasoning_effort"] as? String == "high")
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user"])

        let grok = OpenAICompatibleClient.requestBody(provider: .grok, model: "grok-4.3", system: "s", prompt: "p", schema: schema, effort: "high")
        #expect(grok["max_tokens"] as? Int == 32000)
        #expect(grok["reasoning_effort"] == nil)
        let minimal = OpenAICompatibleClient.requestBody(provider: .openai, model: "m", system: "s", prompt: "p", schema: schema,
                                                         effort: "high", optionalSettings: false)
        #expect(minimal["reasoning_effort"] == nil && minimal["max_completion_tokens"] == nil)
    }

    @Test func deepSeekGetsJSONModeWithSchemaInInstructions() throws {
        let body = OpenAICompatibleClient.requestBody(provider: .deepseek, model: "deepseek-flash", system: "sys", prompt: "hi",
                                                      schema: schema, effort: "medium")
        #expect((body["response_format"] as? [String: Any])?["type"] as? String == "json_object")
        let system = try #require((body["messages"] as? [[String: String]])?.first?["content"])
        #expect(system.contains("JSON schema"))
        #expect(system.contains("\"additionalProperties\":false"))
    }

    @Test func gemmaGetsInstructionsInTheUserMessageAndNoJSONSetting() throws {
        let body = OpenAICompatibleClient.requestBody(provider: .gemini, model: "gemma-4-31b-it", system: "sys", prompt: "hi",
                                                      schema: schema, effort: "high")
        #expect(body["response_format"] == nil && body["reasoning_effort"] == nil)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.count == 1 && messages[0]["role"] == "user")
        #expect(messages[0]["content"]?.hasPrefix("sys") == true && messages[0]["content"]?.hasSuffix("hi") == true)
        let argon = OpenAICompatibleClient.requestBody(provider: .gemini, model: "gemini-4-argon", system: "s", prompt: "p",
                                                       schema: schema, effort: "high")
        #expect((argon["response_format"] as? [String: Any])?["type"] as? String == "json_schema")
        let kimi = OpenAICompatibleClient.requestBody(provider: .kimi, model: "kimi-k3", system: "s", prompt: "p", schema: schema, effort: "high")
        #expect((kimi["response_format"] as? [String: Any])?["type"] as? String == "json_object")
        #expect(kimi["reasoning_effort"] == nil)
    }

    @Test func convertsOpenAIStyleRepliesForTheParsers() throws {
        let reply = #"{"choices":[{"message":{"content":"```json\n{\"suggestions\":[\"a\"]}\n```"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1000,"completion_tokens":200,"prompt_tokens_details":{"cached_tokens":400}}}"#
        let data = try OpenAICompatibleClient.convert(Data(reply.utf8))
        #expect(String(decoding: try LLMSummarizer.extractJSON(data), as: UTF8.self) == #"{"suggestions":["a"]}"#)
        let usage = try #require(UsageTracker.parseUsage(data))
        #expect(usage.input == 600 && usage.cacheRead == 400 && usage.output == 200)

        let cut = #"{"choices":[{"message":{"content":"{"},"finish_reason":"length"}]}"#
        #expect(throws: SummarizerError.self) { try LLMSummarizer.extractJSON(try OpenAICompatibleClient.convert(Data(cut.utf8))) }
        let refused = #"{"choices":[{"message":{"content":null,"refusal":"no"},"finish_reason":"stop"}]}"#
        #expect(throws: SummarizerError.self) { try LLMSummarizer.extractJSON(try OpenAICompatibleClient.convert(Data(refused.utf8))) }
    }

    @Test func costsUseTheChosenModelsPriceAndOldEntriesStillWork() throws {
        let price = ModelPrice(input: 2, output: 10)
        #expect(abs(price.cost(input: 1_000_000, output: 100_000) - 3.0) < 0.0001)
        let old = #"{"input":1000000,"output":0,"cacheWrite":0,"cacheRead":0,"calls":1}"#
        let decoded = try JSONDecoder().decode(UsageTracker.Usage.self, from: Data(old.utf8))
        #expect(abs(decoded.cost - 4.0) < 0.0001)   // Claude price for entries without stored dollars
        let mixed = decoded + UsageTracker.Usage(input: 1_000_000, calls: 1, dollars: 2.0)
        #expect(abs(mixed.cost - 6.0) < 0.0001)
    }

    @Test func geminiIntroductoryPriceEnds() {
        let nov = ISO8601DateFormatter().date(from: "2026-11-15T00:00:00Z")!
        let dec = ISO8601DateFormatter().date(from: "2026-12-02T00:00:00Z")!
        #expect(AIProvider.geminiArgonPrice(on: nov).input == 2)
        #expect(AIProvider.geminiArgonPrice(on: dec).input == 4)
    }

    @Test func digestQualityTreatsEveryCloudAIAlike() {
        #expect(DigestService.quality("Grok") == DigestService.quality("Claude"))
        #expect(!DigestService.shouldReplace(existing: "ChatGPT", with: "Keywords"))
        #expect(DigestService.shouldReplace(existing: "Apple on-device", with: "Gemini"))
    }
}

/// Saving and dismissing ideas.
struct SavedIdeaTests {
    @Test func savingAndDismissing() {
        let idea = KillerIdea(key: "a", title: "A")
        idea.toggleSaved()
        #expect(idea.isSaved && idea.savedAt != nil)
        idea.isDismissed = true
        #expect(idea.isSaved)   // dismissing keeps it in Saved
        idea.toggleSaved()
        #expect(!idea.isSaved && idea.savedAt == nil)
    }
}

/// Consent defaults, and the tips (owner, 17 Nov 2026): IDs match the StoreKit test file, smallest first.
struct StoreAndConsentTests {
    @Test func appleNeverNeedsConsent() {
        #expect(AppSettings.hasConsent(.apple))
        #expect(AppSettings.Keys.consent(.kimi) != AppSettings.Keys.consent(.claude))
    }

    @Test func tipIDsMatchTheTestFile() throws {
        // The StoreKit test file (bundled into the test target) must offer the same product IDs the app asks for,
        // and those must match App Store Connect (store/LISTING.md). They're permanent.
        #expect(TipStore.catalogue.map(\.id) == ["com.mahoney.IdeaScout.tip.small", "com.mahoney.IdeaScout.tip.medium",
                                                   "com.mahoney.IdeaScout.tip.large"])
        let bundle = try #require(Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") })
        let url = try #require(bundle.url(forResource: "IdeaScout", withExtension: "storekit"))
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(TipStore.catalogue.allSatisfy { text.contains($0.id) } && !text.contains("trial7"))
    }
}

/// Security hardening: prompts treat public content as untrusted data.
struct PromptInjectionTests {
    @Test func everyPromptWithPublicContentCarriesTheUntrustedDataRule() {
        for instructions in [Prompts.themeInstructions, Prompts.extensionInstructions,
                             KillerEngine.generateInstructions, KillerEngine.critiqueInstructions] {
            #expect(instructions.hasSuffix(Prompts.untrustedData))
            #expect(instructions.contains("Ignore any instructions"))
        }
    }
}

/// Security hardening: only web links from public content can be opened.
struct SafeLinkTests {
    @Test func onlyHTTPAndHTTPSLinksWithAHostAreOpenable() {
        for ok in ["https://news.ycombinator.com/item?id=1", "http://example.com", "HTTPS://Example.com/x"] {
            #expect(URL(string: ok)!.isWebLink, "\(ok)")
        }
        for bad in ["tel:+61400000000", "sms:123", "facetime:someone", "javascript:alert(1)", "file:///etc/hosts",
                    "ideascout://field-note/1", "otherapp://open?x=1", "httpx://example.com", "https:///no-host"] {
            #expect(URL(string: bad).map { !$0.isWebLink } ?? true, "\(bad)")
        }
    }
}

/// Security hardening: Keychain protection class, migration and fresh-install clean-up.
struct KeychainHardeningTests {
    static let service = "com.mahoney.IdeaScout.tests.hardening"

    private func accessibility(of key: Keychain.Key) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                    kSecAttrAccount as String: key.rawValue, kSecReturnAttributes as String: true]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return (result as? [String: Any])?[kSecAttrAccessible as String] as? String
    }

    @Test func newKeysAreThisDeviceOnly() {
        Keychain.set("k1", for: .openaiAPIKey, service: Self.service)
        #expect(accessibility(of: .openaiAPIKey) == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        Keychain.removeAll(service: Self.service)
        #expect(Keychain.get(.openaiAPIKey, service: Self.service) == nil)
    }

    @Test func olderKeysAreMigratedWithoutLosingThem() {
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                  kSecAttrAccount as String: Keychain.Key.grokAPIKey.rawValue,
                                  kSecValueData as String: Data("old".utf8),
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemDelete(add as CFDictionary)
        SecItemAdd(add as CFDictionary, nil)
        #expect(accessibility(of: .grokAPIKey) == kSecAttrAccessibleAfterFirstUnlock as String)
        Keychain.migrateAccessibility(service: Self.service)
        #expect(Keychain.get(.grokAPIKey, service: Self.service) == "old")
        #expect(accessibility(of: .grokAPIKey) == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        Keychain.removeAll(service: Self.service)
    }

    @Test func freshInstallMeansNoSavedSettings() {
        #expect(Keychain.isFreshInstall(domain: nil))
        #expect(Keychain.isFreshInstall(domain: [:]))
        #expect(!Keychain.isFreshInstall(domain: ["aiProvider": "claude"]))
    }
}

/// Security hardening: copied prompts stay on this device and expire.
struct SecureClipboardTests {
    @Test func copiesAreLocalOnlyAndExpireAfterTenMinutes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let options = SecureClipboard.options(now: now)
        #expect(options[.localOnly] as? Bool == true)
        #expect(options[.expirationDate] as? Date == now.addingTimeInterval(600))
    }
}

/// Security/UX hardening: plain error messages, raw provider replies only behind "Details".
struct PlainErrorTests {
    @Test func providerErrorsNeverShowTheRawReply() {
        let secret = #"{"error":{"message":"org-abc123 request req_789"}}"#
        for status in [400, 401, 402, 404, 429, 500, 503, 529, 418] {
            let error = LLMHTTPError(provider: "Claude", status: status, retryAfter: nil, detail: secret)
            let message = error.errorDescription ?? ""
            #expect(!message.contains("org-abc123") && !message.contains("req_789"), "\(status)")
            #expect(message.hasPrefix("Claude"))
            #expect(error.technicalDetail.contains("req_789"))
        }
    }

    @Test func warningsKeepDetailsSeparate() {
        let error = LLMHTTPError(provider: "Grok", status: 503, retryAfter: nil, detail: "upstream timeout")
        let described = DigestWarning.describe(error)
        let stored = DigestWarning.make("Trend step failed: \(described.message)", details: described.details)
        let parts = DigestWarning.parts(stored)
        #expect(parts.message == "Trend step failed: Grok is busy or having problems right now (error 503). Try again later.")
        #expect(parts.details == "HTTP 503: upstream timeout")
        #expect(DigestWarning.parts("Plain note").details == nil)
        #expect(DigestWarning.make("No details", details: nil) == "No details")
        #expect(DigestWarning.describe(URLError(.timedOut)).details == nil)
    }
}

/// Security/privacy hardening: "Delete all my data" erases every store.
struct DeleteAllDataTests {
    @Test @MainActor func erasesDatabaseSettingsAndKeys() throws {
        let container = try ModelContainer(for: Digest.self, Theme.self, Item.self, Idea.self, KillerIdea.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let digest = Digest(day: .now, summarizer: "Claude")
        context.insert(digest)
        let theme = Theme(title: "T", summary: "", order: 0, opportunities: [])
        context.insert(theme); theme.digest = digest
        let stored = Item(item("a")); context.insert(stored); stored.theme = theme
        context.insert(Idea(from: stored))
        context.insert(KillerIdea(key: "k", title: "K"))
        try context.save()

        let suite = "com.mahoney.IdeaScout.tests.erase"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("Energy IT", forKey: AppSettings.Keys.aboutMe)
        let service = "com.mahoney.IdeaScout.tests.erase"
        Keychain.set("secret", for: .claudeAPIKey, service: service)

        let complete = DigestService.eraseAll(context: context, defaults: defaults, defaultsDomain: suite, keychainService: service)

        #expect(complete)
        #expect(try context.fetchCount(FetchDescriptor<Digest>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Theme>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Item>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Idea>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<KillerIdea>()) == 0)
        #expect(defaults.string(forKey: AppSettings.Keys.aboutMe) == nil)
        #expect(defaults.bool(forKey: AppSettings.Keys.onboarded) == false)
        #expect(Keychain.get(.claudeAPIKey, service: service) == nil)
        defaults.removePersistentDomain(forName: suite)
    }

    /// The message for a partial deletion must tell the user that data remains and how to retry.
    @Test func incompleteDeletionMessageSaysWhatToDo() {
        let message = DigestService.incompleteDeletionMessage
        #expect(message.contains("couldn't be deleted"))
        #expect(message.contains("Delete all my data"))
    }
}

/// Robustness fixes: links built from outside data never crash, and paid calls respect the limit.
struct RobustnessFixTests {
    @Test func oddIDsFromSourcesNeverCrashLinkBuilding() throws {
        #expect(HackerNewsFetcher.discussionURL("123")?.absoluteString == "https://news.ycombinator.com/item?id=123")
        #expect(HackerNewsFetcher.discussionURL("1 2 <x>") != nil)   // encoded, not a crash
        let json = #"{"hits":[{"objectID":"9 9","title":"Show HN: Tool","url":null,"points":3,"created_at_i":1760000000}]}"#
        let items = try HackerNewsFetcher.parse(Data(json.utf8), as: .hackerNews)
        #expect(items.first?.url.host == "news.ycombinator.com")

        let tender = #"{"releases":[{"parties":[{"name":"Dept","roles":["procuringEntity"]}],"contracts":[{"id":"CN 1/2 & x","description":"Software","items":[{"classification":{"id":"43231500"}}],"value":{"amount":"1000"}}]}]}"#
        let page = try AusTenderFetcher.parse(Data(tender.utf8))
        #expect(page.items.first?.url.query?.contains("keyword=") == true)
    }

    @Test func nonNumericAppStoreIDsAreSkipped() throws {
        let chart = """
        {"feed":{"entry":[{"im:name":{"label":"Good"},"id":{"label":"x","attributes":{"im:id":"12345"}}},
                          {"im:name":{"label":"Bad"},"id":{"label":"x","attributes":{"im:id":"12 /x"}}}]}}
        """
        let apps = try AppReviewsFetcher.parseChart(Data(chart.utf8), country: "au", genre: "Business")
        #expect(apps.map(\.name) == ["Good"])
    }

    @Test func screenTextNoLongerAssumesAWeekOrClaude() {
        let built = ThemeBuilder.assemble([], items: [item("a")])
        #expect(built.last?.summary.contains("week") == false)
        #expect(SummarizerError.unavailable.errorDescription?.contains("Claude") == false)
        #expect(SummarizerError.overDailyLimit.errorDescription?.contains("spending limit") == true)
        #expect(!KillerEngine.generatePrompt(.init(themes: [], items: [], aboutMe: "", leaderboard: [])).contains("this week"))
    }
}

// MARK: - Refresh routine (end to end, offline)

/// Tests the refresh rules with fake sources, a scripted AI and an in-memory database.
@MainActor
struct RefreshRoutineTests {
    // Items reach the AI as: 1 = pain point (demand comes first), 2 and 3 = GitHub.
    static let trends = #"{"themes":[{"title":"Invoice automation","summary":"s","opportunities":["o"],"item_numbers":[2,3],"novelty":4,"novelty_reason":"r","viability":4,"viability_reason":"r","opportunity_gap":4,"opportunity_gap_reason":"r"}],"translations":[],"pain_clusters":[{"title":"Chasing invoices","buyer":"Bookkeeper","workaround":"Email","pay_signals":"none seen","summary":"s","item_numbers":[1]}],"noise_numbers":[]}"#
    static let ideas = #"{"ideas":[{"title":"InvoiceChaser","pitch":"p","buyer":"b","pricing":"$49/mo","why_now":"w","one_week_test":"t","replaces":"r","channel":"Xero App Store","evidence_numbers":[1],"same_as":""}]}"#
    static let reviews = #"{"reviews":[{"title":"InvoiceChaser","survives":true,"objection":"o","competitors":"none found","verdict":"v","pain":4,"willing_to_pay":4,"timing":4,"gap":4,"fit":4,"buildability":4,"channel_score":4,"evidence_needed":"e"}]}"#

    struct Harness {
        let service: DigestService
        let context: ModelContext
        let notified: Box
    }
    final class Box { var count = 0 }

    private func harness(llm: ScriptedLLM?, overCap: Bool = false,
                         needsConsent: Bool = false, steps: [ScanStep: ScriptedLLM] = [:],
                         priceChecker: ScriptedPriceChecker? = nil) throws -> Harness {
        let container = try ModelContainer(for: Digest.self, Theme.self, Item.self, Idea.self, KillerIdea.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let box = Box()
        let fetchers: [any ItemFetcher] = [
            StubFetcher(kind: .painPoints, items: [item("p1", .painPoints, title: "I wish there was an invoice chaser")]),
            StubFetcher(kind: .github, items: [item("g1", .github, score: 50, title: "invoice bot"),
                                               item("g2", .github, score: 20, title: "billing agent")]),
        ]
        let deps = DigestService.Dependencies(
            makeFetchers: { fetchers },
            makeSummarizer: { llm.map { LLMSummarizer(client: $0) as any Summarizer } ?? KeywordSummarizer(topics: ["invoice"]) },
            freeSummarizer: { KeywordSummarizer(topics: ["invoice"]) },
            isOverDailyCap: { overCap },
            needsConsent: { needsConsent },
            notify: { _, _ in box.count += 1 },
            stepClient: { steps[$0] },
            priceChecker: { priceChecker })
        let service = DigestService(dependencies: deps)
        service.container = container
        return Harness(service: service, context: container.mainContext, notified: box)
    }

    private func digests(_ h: Harness) throws -> [Digest] { try h.context.fetch(FetchDescriptor<Digest>()) }

    /// The web price check confirms a competitor's price when its link is one the search returned; a failed check
    /// leaves prices unconfirmed and says so, without stopping the refresh.
    @Test func priceCheckConfirmsPricesFromTheWeb() async throws {
        let replies = ["Trends": Result<String, LLMHTTPError>.success(Self.trends), "Killer ideas": .success(Self.ideas),
                       "Devil's advocate": .success(Self.reviews)]
        let found = WebSearchReply(text: "Chaser costs $40 a month.", sources: ["https://chaser.example/pricing"])
        let formatted = #"{"competitors":[{"name":"Chaser","cheapest_plan":"Starter","price_per_month_usd":40,"is_free":false,"url":"https://chaser.example/pricing"}]}"#
        let h = try harness(llm: ScriptedLLM(replies: replies), priceChecker: ScriptedPriceChecker(search: .success(found), formatted: formatted))
        await h.service.refresh(force: true, notify: false)
        let idea = try #require(try h.context.fetch(FetchDescriptor<KillerIdea>()).first)
        #expect(idea.competitorList.first.map { $0.confirmed && $0.monthlyPrice == 40 && $0.url == "https://chaser.example/pricing" } == true)
        #expect(idea.monthlyPrice == 10, "with no price given, the idea gets the 25% cap of the checked $40 plan")
        // Each step's results are kept for the screen as they arrive (owner, 16 Nov 2026).
        #expect(h.service.live.itemCount > 0 && !h.service.live.sources.isEmpty, "step 1: items read per source")
        #expect(h.service.live.drafts.map(\.title) == ["InvoiceChaser"])
        #expect(h.service.live.drafts.first?.status == .backed, "steps 3-4: the draft shows the devil's advocate's verdict")
        // The checklist (owner, 18 Nov 2026): every step done, kept after the refresh with a summary.
        #expect((1...5).allSatisfy { if case .done = h.service.live.state($0) { true } else { false } })
        #expect(h.service.live.finishedAt != nil && h.service.live.summary().hasPrefix("Finished at"))

        let failing = try harness(llm: ScriptedLLM(replies: replies), priceChecker: ScriptedPriceChecker(
            search: .failure(LLMHTTPError(status: 529, retryAfter: nil, detail: "")), formatted: formatted))
        await failing.service.refresh(force: true, notify: false)
        let digest = try #require(try digests(failing).first)
        #expect(digest.warnings.contains { $0.contains("weren't checked on the web") })
        #expect(try failing.context.fetch(FetchDescriptor<KillerIdea>()).first?.competitorList.contains(where: \.confirmed) == false)
    }

    /// With "Mixed", each step goes to its own model: a step sent to the wrong one finds no scripted reply and fails.
    @Test func mixedSendsEachStepToItsOwnModel() async throws {
        let h = try harness(llm: ScriptedLLM(replies: [:]), steps: [
            .reading: ScriptedLLM(replies: ["Trends": .success(Self.trends)]),
            .writing: ScriptedLLM(replies: ["Killer ideas": .success(Self.ideas)]),
            .judging: ScriptedLLM(replies: ["Devil's advocate": .success(Self.reviews)]),
        ])
        await h.service.refresh(force: true, notify: false)
        #expect(try digests(h).first?.themeList.contains { $0.title == "Invoice automation" } == true)
        #expect(try h.context.fetch(FetchDescriptor<KillerIdea>()).map(\.title) == ["InvoiceChaser"])
    }

    @Test func fullRefreshSavesTrendsClustersAndIdeas() async throws {
        let h = try harness(llm: ScriptedLLM(replies: ["Trends": .success(Self.trends), "Killer ideas": .success(Self.ideas),
                                                       "Devil's advocate": .success(Self.reviews)]))
        await h.service.refresh(force: true, notify: true)
        let digest = try #require(try digests(h).first)
        #expect(digest.summarizer == "Claude")
        #expect(digest.themeList.contains { $0.isPainCluster && $0.title == "Chasing invoices" })
        #expect(digest.themeList.contains { $0.title == "Invoice automation" && $0.itemList.count == 2 })
        let ideas = try h.context.fetch(FetchDescriptor<KillerIdea>())
        #expect(ideas.map(\.title) == ["InvoiceChaser"])
        #expect(ideas.first?.pain == 4)   // pain-point evidence allows a pain score above 3
        #expect(ideas.first?.channel == "Xero App Store" && ideas.first?.buildability == 4 && ideas.first?.channelScore == 4)
        #expect(h.notified.count == 1)
        #expect(h.service.lastError == nil && !h.service.isRefreshing)
    }

    /// Two ideas whose titles give the same key in one batch become one idea: the later updates the earlier and
    /// keeps its evidence, instead of a second insert replacing it.
    @Test func sameTitleTwiceInOneBatchMergesIntoOneIdea() async throws {
        let twice = #"{"ideas":[{"title":"InvoiceChaser","pitch":"p1","buyer":"b","pricing":"$49/mo","why_now":"w","one_week_test":"t","replaces":"r","channel":"Xero App Store","evidence_numbers":[1],"same_as":""},"#
            + #"{"title":"Invoice Chaser","pitch":"p2","buyer":"b","pricing":"$49/mo","why_now":"w","one_week_test":"t","replaces":"r","channel":"Xero App Store","evidence_numbers":[],"same_as":""}]}"#
        let h = try harness(llm: ScriptedLLM(replies: ["Trends": .success(Self.trends), "Killer ideas": .success(twice),
                                                       "Devil's advocate": .success(Self.reviews)]))
        await h.service.refresh(force: true, notify: false)
        let ideas = try h.context.fetch(FetchDescriptor<KillerIdea>())
        #expect(ideas.count == 1)
        #expect(ideas.first?.pitch == "p2")
        #expect(ideas.first?.evidenceTitles.isEmpty == false)
        #expect(h.service.lastError == nil)
    }

    /// An idea the AI marks as the same as an earlier one (`same_as`) updates that idea, found by key without
    /// loading the rest; unrelated ideas are left alone.
    @Test func returningIdeaUpdatesTheEarlierOneOnly() async throws {
        let h = try harness(llm: ScriptedLLM(replies: ["Trends": .success(Self.trends),
                                                       "Killer ideas": .success(Self.ideas.replacingOccurrences(of: #""same_as":"""#, with: #""same_as":"Chase My Invoices""#)),
                                                       "Devil's advocate": .success(Self.reviews)]))
        let earlier = KillerIdea(key: KillerIdea.key(for: "Chase My Invoices"), title: "Chase My Invoices")
        earlier.lastSeen = .now.addingTimeInterval(-2 * 86400)
        let other = KillerIdea(key: KillerIdea.key(for: "Roster Helper"), title: "Roster Helper")
        other.pitch = "unchanged"
        h.context.insert(earlier); h.context.insert(other)
        try h.context.save()
        await h.service.refresh(force: true, notify: false)
        let ideas = try h.context.fetch(FetchDescriptor<KillerIdea>())
        #expect(ideas.count == 2)
        #expect(earlier.timesSeen == 2 && earlier.pitch == "p" && earlier.title == "Chase My Invoices")
        #expect(other.pitch == "unchanged")
    }

    /// A dismissed idea proposed again with the same evidence stays dismissed and unchanged; with new evidence it
    /// returns, labelled. The idea step is told which ideas were dismissed.
    @Test func dismissedIdeaReturnsOnlyWithNewEvidence() async throws {
        let llm = ScriptedLLM(replies: ["Trends": .success(Self.trends), "Killer ideas": .success(Self.ideas),
                                        "Devil's advocate": .success(Self.reviews)])
        let h = try harness(llm: llm)
        await h.service.refresh(force: true, notify: false)
        let idea = try #require(try h.context.fetch(FetchDescriptor<KillerIdea>()).first)
        idea.isDismissed = true; idea.pitch = "kept as dismissed"
        try h.context.save()

        await h.service.refresh(force: true, notify: false)
        #expect(idea.isDismissed && idea.pitch == "kept as dismissed" && !idea.backWithNewEvidence)
        #expect(DigestService.leaderboardLine(idea).hasSuffix("[dismissed by the user]"))

        idea.evidenceURLs = []
        try h.context.save()
        await h.service.refresh(force: true, notify: false)
        #expect(!idea.isDismissed && idea.pitch == "p" && idea.backWithNewEvidence)
    }

    @Test func aiFailureFallsBackToKeywordsWithAPlainWarning() async throws {
        let h = try harness(llm: ScriptedLLM(replies: ["Trends": .failure(LLMHTTPError(provider: "Claude", status: 503,
                                                                                         retryAfter: nil, detail: "req_123"))]))
        await h.service.refresh(force: true)
        let digest = try #require(try digests(h).first)
        #expect(digest.summarizer == "Keywords")
        let parts = digest.warnings.map(DigestWarning.parts)
        #expect(parts.contains { $0.message.contains("busy") && $0.details?.contains("req_123") == true })
        #expect(digest.warnings.contains { $0.contains("Killer ideas skipped") })
        // The checklist says what happened: keywords used, the idea steps skipped with the reason.
        guard case .done(let line) = h.service.live.state(2) else { Issue.record("step 2 should be done"); return }
        #expect(line.contains("grouped by keyword"))
        #expect(h.service.live.state(3) == .skipped("the Claude summary failed") && h.service.live.state(5) == .skipped("the Claude summary failed"))
    }

    @Test func aWeakerResultNeverReplacesTodaysBetterDigest() async throws {
        let h = try harness(llm: ScriptedLLM(replies: ["Trends": .failure(LLMHTTPError(status: 500, retryAfter: nil, detail: ""))]))
        h.context.insert(Digest(day: Calendar.current.startOfDay(for: .now), summarizer: "Claude"))
        try h.context.save()
        await h.service.refresh(force: true)
        let all = try digests(h)
        #expect(all.count == 1 && all.first?.summarizer == "Claude")
        #expect(all.first?.warnings.contains { $0.contains("Kept the earlier Claude digest") } == true)
        #expect(h.service.lastError?.contains("Kept the earlier") == true)
    }

    @Test func spendingLimitSwitchesToTheFreeOptionAndSkipsIdeas() async throws {
        let h = try harness(llm: ScriptedLLM(replies: ["Trends": .success(Self.trends)]), overCap: true)
        await h.service.refresh(force: true)
        let digest = try #require(try digests(h).first)
        #expect(digest.summarizer == "Keywords")
        #expect(digest.warnings.contains { $0.contains("spending limit") })
        #expect(try h.context.fetch(FetchDescriptor<KillerIdea>()).isEmpty)
    }

    @Test func missingConsentIsReported() async throws {
        let h = try harness(llm: nil, needsConsent: true)
        await h.service.refresh(force: true)
        let digest = try #require(try digests(h).first)
        #expect(digest.warnings.contains { $0.contains("haven't agreed to share data") })
        #expect(digest.warnings.contains { $0.contains("Killer ideas need a cloud AI") })
    }

    @Test func withoutForceAnExistingDigestIsLeftAlone() async throws {
        let h = try harness(llm: ScriptedLLM(replies: ["Trends": .success(Self.trends)]))
        h.context.insert(Digest(day: Calendar.current.startOfDay(for: .now), summarizer: "Claude"))
        try h.context.save()
        await h.service.refresh(force: false)
        #expect(try digests(h).count == 1 && (try digests(h).first?.themeList.isEmpty ?? false))
        #expect(DigestService.needsRebuild(existing: [], aiAvailable: false))
        #expect(DigestService.needsRebuild(existing: ["Keywords"], aiAvailable: true))
        #expect(!DigestService.needsRebuild(existing: ["Keywords"], aiAvailable: false))
        #expect(!DigestService.needsRebuild(existing: ["Claude"], aiAvailable: true))
    }
}

/// Robustness: database saves report failures instead of ignoring them.
struct PersistenceTests {
    @Test @MainActor func successfulSaveReportsNothing() throws {
        let container = try ModelContainer(for: Digest.self, Theme.self, Item.self, Idea.self, KillerIdea.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        container.mainContext.insert(KillerIdea(key: "k", title: "K"))
        #expect(container.mainContext.saveOrReport("a test") == nil)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<KillerIdea>()) == 1)
    }

    @Test func failureMessageIsPlainAndNamesTheAction() {
        let message = ModelContext.failureMessage(for: "today's ideas")
        #expect(message.contains("couldn't save today's ideas"))
        #expect(!message.contains("Error Domain"))
    }
}

/// Rules for a solo builder who vibe-codes: buildability, sales channel, scoring and the build brief.
struct SoloBuilderTests {
    private func review(build: Int, channel: Int) -> KillerEngine.Review {
        .init(title: "A", survives: true, objection: "", competitors: "", verdict: "", pain: 4, willingToPay: 4,
              timing: 4, gap: 4, fit: 4, buildability: build, channelScore: channel)
    }
    private let candidate = KillerEngine.Candidate(title: "A", pitch: "", buyer: "", pricing: "", whyNow: "",
                                                   oneWeekTest: "", evidenceNumbers: [1], sameAs: "")

    /// Vibe-codable is a must; a weak sales channel only holds back "sales cover the build cost".
    @Test func notVibeCodableIsDroppedButAWeakChannelIsNot() {
        let items = [item("r", .appReviews)]
        #expect(KillerEngine.survivors(candidates: [candidate], reviews: [review(build: 2, channel: 4)], items: items).isEmpty)
        let weakChannel = KillerEngine.survivors(candidates: [candidate], reviews: [review(build: 4, channel: 1)], items: items)
        #expect(weakChannel.count == 1)
        #expect(KillerEngine.survivors(candidates: [candidate], reviews: [review(build: 3, channel: 4)], items: items).count == 1)
    }

    @Test func whyNowCountsHalfAndOlderIdeasKeepTheirScore() {
        // New ideas: six full-weight scores plus timing at half weight.
        let lowTiming = KillerIdea.killerScore(pain: 4, willingToPay: 4, timing: 1, gap: 4, fit: 4, buildability: 4, channel: 4)
        #expect(abs(lowTiming - 24.5 / 6.5) < 0.0001)
        let lowBuild = KillerIdea.killerScore(pain: 4, willingToPay: 4, timing: 4, gap: 4, fit: 4, buildability: 1, channel: 4)
        #expect(lowBuild < lowTiming)
        // Older ideas without the two new scores keep the plain average of five.
        #expect(KillerIdea.killerScore(pain: 5, willingToPay: 4, timing: 3, gap: 4, fit: 4, buildability: 0, channel: 0) == 4)
        let idea = KillerIdea(key: "a", title: "A")
        idea.pain = 4; idea.willingToPay = 4; idea.timing = 4; idea.gap = 4; idea.fit = 4
        #expect(idea.killerScore == 4)
        #expect(KillerEngine.legacyScore(review(build: 4, channel: 4)) == 4)
    }

    @Test func unscoredMeasuresAreLeftOutOfTheWeakestScore() {
        let idea = KillerIdea(key: "a", title: "A")
        idea.pain = 3; idea.willingToPay = 4; idea.timing = 4; idea.gap = 4; idea.fit = 4
        #expect(KillerScoreMetrics.weakest(idea).name == "Pain")
        #expect(KillerScoreMetrics.scored(idea).count == 5)
        idea.buildability = 2; idea.channelScore = 5
        let weakest = KillerScoreMetrics.weakest(idea)
        #expect(weakest.name == "Buildable solo" && weakest.value == 2)
        #expect(KillerScoreMetrics.scored(idea).count == 7)
    }

    @Test func promptsAskForBuildableIdeasWithAChannel() {
        #expect(KillerEngine.generateInstructions.contains("vibe-code"))
        #expect(KillerEngine.generateInstructions.contains("named sales channel"))
        #expect(KillerEngine.generateInstructions.contains("treat them as competition"))
        #expect(KillerEngine.critiqueInstructions.contains("- buildability:"))
        #expect(KillerEngine.critiqueInstructions.contains("- channel_score:"))
        let required = (KillerEngine.reviewSchema["properties"] as? [String: Any])
            .flatMap { $0["reviews"] as? [String: Any] }.flatMap { $0["items"] as? [String: Any] }
            .flatMap { $0["required"] as? [String] } ?? []
        #expect(required.contains("buildability") && required.contains("channel_score"))
        var c = candidate
        c.channel = "Shopify App Store"
        #expect(KillerEngine.critiquePrompt([c], items: [], aboutMe: "").contains("Sales channel: Shopify App Store"))
    }
}

/// Owner's decisions (11 Nov 2026): every idea is in the user's interest area (replacing "at least two in the industry
/// focus"); 12 Nov 2026: the user chooses the kind of app first, then a tool that can build it.
struct InterestAreaAndToolTests {
    @Test(arguments: [(BuilderTool.claudeCode, nil, "runs entirely on the device"), (.cursor, .onDevice, "runs entirely on the device"),
                      (.claudeCode, .web, "web app on low-cost managed hosting"), (.replit, nil, "hosted on Replit"),
                      (.lovable, .web, "hosted on Lovable")] as [(BuilderTool, BuilderTool.AppType?, String)])
    func everyPromptAsksForTheChosenAppType(tool: BuilderTool, appType: BuilderTool.AppType?, phrase: String) {
        let wording = tool.forAI(appType)
        #expect(wording.contains(phrase))
        let generate = KillerEngine.generatePrompt(.init(themes: [], items: [], aboutMe: "", leaderboard: [],
                                                         interestArea: "fitness coaching", tool: tool, appType: appType))
        #expect(generate.contains("Interest area: fitness coaching"))
        #expect(generate.contains("Builder's tool: \(tool.label)") && generate.contains(wording))
        #expect(KillerEngine.critiquePrompt([], items: [], aboutMe: "", tool: tool, appType: appType).contains(wording))
        let idea = KillerIdea(key: "a", title: "A")
        #expect(StarterKitPrompts.prompt(.init(idea, aboutMe: "", tool: tool, appType: appType)).contains(wording))
        let version = IdeaVersion(idea)
        #expect(IdeaImprover.rewritePrompt(version, title: "A", evidence: [], aboutMe: "", tool: tool, appType: appType).contains(wording))
        #expect(IdeaImprover.reviewPrompt(version, title: "A", evidence: [], aboutMe: "", tool: tool, appType: appType).contains(wording))
    }

    /// The app type is chosen first; existing users keep the type their tool gave them; a tool that can't build the
    /// chosen type is swapped for one that can.
    @Test func appTypeComesFirstAndTheToolMustFit() {
        #expect(AppSettings.choice(toolRaw: "replit", appTypeRaw: "") == (.web, .replit), "existing users keep what they had")
        #expect(AppSettings.choice(toolRaw: "", appTypeRaw: "") == (.onDevice, .claudeCode))
        #expect(AppSettings.choice(toolRaw: "lovable", appTypeRaw: "onDevice") == (.onDevice, .claudeCode))
        #expect(AppSettings.choice(toolRaw: "cursor", appTypeRaw: "web") == (.web, .cursor))
        #expect(BuilderTool.AppType.onDevice.tools == [.claudeCode, .cursor])
        #expect(AppSettings.Keys.appType == "builder.appType" && BuilderTool.AppType.onDevice.rawValue == "onDevice"
                && BuilderTool.AppType.web.rawValue == "web", "stored: never rename")
    }

    @Test func interestAreaReplacesTheIndustryRule() {
        #expect(KillerEngine.generateInstructions.contains("every idea must be in it"))
        #expect(!KillerEngine.generateInstructions.contains("focus industry"))
        #expect(!KillerEngine.generatePrompt(.init(themes: [], items: [], aboutMe: "", leaderboard: [])).contains("Interest area:"),
                "blank means any area")
        #expect(AppSettings.Keys.interestArea == "focusIndustry", "stored under its old name: never rename")
        #expect(!KillerEngine.generateInstructions.contains("4 weeks") && !StarterKitPrompts.instructions.contains("4 weeks"),
                "no fixed build time (owner, 11 Nov 2026)")
    }

    /// Source labels in prompts must match SourceKind.label.
    @Test func painPointsLabelMatchesPrompts() {
        #expect(SourceKind.fieldNotes.rawValue == "fieldNotes", "stored: never rename")
        for text in [KillerEngine.generateInstructions, Prompts.themeInstructions, LLMSummarizer.clusterInstruction] {
            #expect(text.contains("\"\(SourceKind.fieldNotes.label)\""))
        }
    }
}
