import Foundation
import Testing
@testable import IdeaScout

private func item(_ key: String, _ source: SourceKind = .github, score: Int = 0, url: String? = nil, title: String = "Title") -> FetchedItem {
    FetchedItem(key: key, source: source, title: title, detail: "", url: URL(string: url ?? "https://example.com/\(key)")!,
                score: score, postedAt: .now)
}

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

    @Test func parsesProductHunt() throws {
        let json = """
        {"data":{"posts":{"edges":[{"node":{"id":"77","name":"Launchy","tagline":"Ship faster",
          "url":"https://www.producthunt.com/posts/launchy","votesCount":300,"createdAt":"2026-10-18T07:01:00Z"}}]}}}
        """
        let items = try ProductHuntFetcher.parse(Data(json.utf8))
        #expect(items.count == 1)
        #expect(items[0].key == "ph-77")
        #expect(items[0].detail == "Ship faster")
    }

    @Test func missingProductHuntTokenGivesClearError() async {
        await #expect(throws: FetchError.self) {
            _ = try await ProductHuntFetcher(token: nil).fetch(since: .now, topics: [])
        }
    }
}

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

    @Test func nextOccurrenceIsInTheFuture() {
        let now = Date.now
        let next = DigestService.nextOccurrence(ofHour: 7, after: now)
        #expect(next > now)
        #expect(Calendar.current.component(.hour, from: next) == 7)
    }
}

struct ClaudeTests {
    @Test func requestUsesModelSchemaAndFallback() throws {
        let body = ClaudeSummarizer.requestBody(system: "sys", prompt: "hi", schema: ClaudeSummarizer.themeSchema)
        #expect(body["model"] as? String == "claude-opus-5-5")
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
        let drafts = try ClaudeSummarizer.parseThemes(JSONSerialization.data(withJSONObject: response))
        #expect(drafts == [ThemeDraft(title: "Agents", summary: "S", opportunities: ["Do X"], itemNumbers: [1, 3])])
    }

    @Test func refusalThrows() throws {
        let response: [String: Any] = ["content": [], "stop_reason": "refusal"]
        let data = try JSONSerialization.data(withJSONObject: response)
        #expect(throws: SummarizerError.self) { try ClaudeSummarizer.parseThemes(data) }
    }

    @Test func promptIncludesNotes() {
        let text = Prompts.ideaText(IdeaBrief(title: "Tool", detail: "Does things", note: "For nurses"))
        #expect(text.contains("For nurses"))
    }
}

struct KeychainTests {
    @Test func roundTrip() {
        Keychain.set("test-value", for: .productHuntToken)
        #expect(Keychain.get(.productHuntToken) == "test-value")
        Keychain.set(nil, for: .productHuntToken)
        #expect(Keychain.get(.productHuntToken) == nil)
    }
}

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
        let draft = try #require(try ClaudeSummarizer.parseThemes(JSONSerialization.data(withJSONObject: response)).first)
        #expect((draft.novelty, draft.viability, draft.gap) == (4, 2, 5))
        #expect(draft.reasons.gap == "g")
    }
}

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
        #expect(prompt.contains("7. The next three concrete steps"))
    }
}

struct NewSourceTests {
    @Test func parsesHuggingFaceSpaces() throws {
        let json = """
        [{"id":"me/talkbot","likes":50,"trendingScore":221,"createdAt":"2026-10-14T23:23:19.000Z",
          "cardData":{"title":"Talk Bot","short_description":"Voice agent demo"}},
         {"id":"you/plain","likes":3,"createdAt":"2026-10-10T01:00:00.000Z"}]
        """
        let items = try HuggingFaceFetcher.parse(Data(json.utf8))
        #expect(items.count == 2)
        #expect(items[0].title == "Talk Bot")
        #expect(items[0].score == 221)
        #expect(items[0].url.absoluteString == "https://huggingface.co/spaces/me/talkbot")
        #expect(items[1].title == "you/plain")
        #expect(items[1].score == 3)
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
        #expect(list == "1. [DEV #showdev, score 12, new] Fresh")
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
