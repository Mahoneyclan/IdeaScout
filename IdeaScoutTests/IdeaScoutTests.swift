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
        #expect(built.map(\.title) == ["One", "Two", "Other new projects"])
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
        let inner = #"{"themes":[{"title":"Agents","summary":"S","opportunities":["Do X"],"item_numbers":[1,3]}]}"#
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
