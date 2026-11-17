// SourceFetchTests.swift
// End-to-end tests of each source's fetch: the request it builds, the reply handling and the "one part
// failed" rules. A stand-in for the network (`StubWeb`) answers every request from small samples of the
// real reply formats, so these tests never reach the internet. Parser details are tested in IdeaScoutTests.

import Foundation
import Testing
@testable import IdeaScout

// MARK: - Stand-in network

/// Answers requests made through `URLSession.shared` from canned replies, matched by the first route whose
/// text appears in the request's address. Unknown addresses get HTTP 599, so a test can never use the
/// real network by accident.
final class StubWeb: URLProtocol, @unchecked Sendable {
    /// One canned reply.
    struct Reply: Sendable { var status = 200; var body: String }

    // Shared by every request; guarded by `lock` because URLSession calls in from its own threads.
    nonisolated(unsafe) private static var routes: [(match: String, reply: Reply)] = []
    nonisolated(unsafe) private static var seen: [URLRequest] = []
    private static let lock = NSLock()

    /// Installs the stand-in and replaces the routes.
    /// - Parameter routes: (text in the address, reply) pairs, checked in order.
    static func serve(_ routes: [(String, Reply)]) {
        lock.withLock {
            Self.routes = routes.map { (match: $0.0, reply: $0.1) }
            seen = []
        }
        URLProtocol.registerClass(StubWeb.self)
    }

    /// Every request answered since the last `serve`.
    static var requests: [URLRequest] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let address = request.url?.absoluteString ?? ""
        let reply = Self.lock.withLock {
            Self.seen.append(request)
            return Self.routes.first { address.contains($0.match) }?.reply
        } ?? Reply(status: 599, body: "")
        // Safe to unwrap: `URLProtocol` is only started for requests that have an address.
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Small samples of each source's real reply format.
enum Samples {
    static let hn = #"{"hits":[{"objectID":"1","title":"Show HN: Invoice agent","url":"https://a.dev","points":42,"created_at_i":1760000000,"comment_text":"I wish there was a tool for invoices"}]}"#
    static let github = #"{"items":[{"id":9,"full_name":"me/tool","html_url":"https://github.com/me/tool","description":"A tool","stargazers_count":120,"created_at":"2026-10-15T08:00:00Z"}]}"#
    static let spaces = #"[{"id":"me/talkbot","likes":50,"trendingScore":221,"createdAt":"2026-10-14T23:23:19.000Z","cardData":{"title":"Talk Bot","short_description":"Voice agent demo"}}]"#
    static let papers = #"[{"paper":{"id":"1","title":"Recent","summary":"Long","ai_summary":"Short","upvotes":12},"publishedAt":"2099-01-01T00:00:00.000Z"},{"paper":{"id":"2","title":"Old","summary":"Long","ai_summary":"Short","upvotes":99},"publishedAt":"2000-01-01T00:00:00.000Z"}]"#
    static let devTo = #"[{"id":5,"title":"I built a CRM for plumbers","description":"Side project","url":"https://dev.to/a/crm","positive_reactions_count":131,"published_at":"2026-10-18T10:55:38Z"}]"#
    static let lobsters = #"[{"short_id":"new","title":"Fresh","url":"","comments_url":"https://lobste.rs/s/new","score":7,"created_at":"2099-01-01T00:00:00.000-05:00","description_plain":"x"},{"short_id":"old","title":"Old","url":"","comments_url":"https://lobste.rs/s/old","score":7,"created_at":"2000-01-01T00:00:00.000-05:00","description_plain":"x"}]"#
    static let topPaid = #"{"feed":{"results":[{"id":"2","name":"AnkiMobile","url":"https://apps.apple.com/us/app/id2","genres":[{"name":"Education"}]}]}}"#
    static let atlassian = #"{"_embedded":{"addons":[{"id":"5","name":"Daily Worklog","tagLine":"Log time fast","_links":{"alternate":{"href":"/apps/5/daily-worklog"}},"_embedded":{"categories":[{"name":"Time tracking"}],"distribution":{"totalInstalls":12}}}]}}"#
    static let itch = #"<?xml version="1.0"?><rss version="2.0"><channel><item><title>CellZ</title><plainTitle>CellZ</plainTitle><link>https://dev.itch.io/cellz</link><description>Evolve</description><createDate>Mon, 19 Oct 2026 11:39:19 GMT</createDate></item></channel></rss>"#
    static let steamFeatured = #"{"coming_soon":{"items":[{"id":1,"name":"Reshine","type":0}]},"new_releases":{"items":[{"id":3,"name":"Sky Farm","type":0}]}}"#
    static let steamDetails = #"{"1":{"success":true,"data":{"short_description":"A puzzle game"}}}"#

    /// A top-grossing chart of `count` apps (the daily pick reads ranks 26–100, or skips only the top 5 in a shorter chart).
    static func chart(count: Int) -> String {
        let entries = (1...count).map { #"{"im:name":{"label":"App \#($0)"},"id":{"label":"x","attributes":{"im:id":"\#($0)"}}}"# }
        return #"{"feed":{"entry":["# + entries.joined(separator: ",") + "]}}"
    }

    /// One recent one-star review.
    static var review: String {
        let day = ISO8601DateFormatter().string(from: .now.addingTimeInterval(-86_400))
        return #"{"feed":{"entry":[{"id":{"label":"1"},"title":{"label":"Too expensive"},"content":{"label":"Price doubled"},"im:rating":{"label":"1"},"updated":{"label":""# + day + #""}}]}}"#
    }

    /// One AusTender page with an IT contract, optionally pointing to a next page.
    static func tender(id: String, next: String?) -> String {
        let link = next.map { #","links":{"next":""# + $0 + #""}"# } ?? ""
        return #"{"releases":[{"parties":[{"name":"Acme IT","roles":["supplier"]},{"name":"Dept","roles":["procuringEntity"]}],"contracts":[{"id":""# + id
            + #"","description":"Software licences \#(id)","items":[{"classification":{"id":"43231500"}}],"value":{"amount":"250000"}}]}]"# + link + "}"
    }
}

// MARK: - Tests

/// Each source's fetch, run against the stand-in network. Serialized because the stand-in is shared.
@Suite(.serialized)
struct SourceFetchTests {
    private let since = Date.now.addingTimeInterval(-7 * 86_400)

    @Test func requestsNameTheAppAndAskForTheRightFeed() async throws {
        StubWeb.serve([("hn.algolia.com", .init(body: Samples.hn))])
        let items = try await HackerNewsFetcher().fetch(since: since, topics: [])
        #expect(items.map(\.title) == ["Invoice agent"])
        let request = try #require(StubWeb.requests.first)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "IdeaScout")
        #expect(request.url?.absoluteString.contains("tags=show_hn") == true)
    }

    @Test func errorStatusBecomesAPlainFetchError() async {
        StubWeb.serve([("hn.algolia.com", .init(status: 503, body: ""))])
        await #expect(throws: FetchError.self) { try await HackerNewsFetcher().fetch(since: since, topics: []) }
    }

    @Test func githubSearchesEachTopicUpToTheLimit() async throws {
        StubWeb.serve([("api.github.com", .init(body: Samples.github))])
        let topics = (1...9).map { "topic \($0)" }
        let items = try await GitHubFetcher().fetch(since: since, topics: topics)
        #expect(items.count == GitHubFetcher.maxTopics)
        let first = try #require(StubWeb.requests.first?.url?.absoluteString.removingPercentEncoding)
        #expect(first.contains("\"topic 1\" created:>\(GitHubFetcher.day(since))"))
        #expect(StubWeb.requests.first?.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    }

    @Test func aiAndResearchSources() async throws {
        StubWeb.serve([("huggingface.co/api/spaces", .init(body: Samples.spaces)),
                       ("huggingface.co/api/daily_papers", .init(body: Samples.papers))])
        #expect(try await HuggingFaceFetcher().fetch(since: since, topics: []).map(\.title) == ["Talk Bot"])
        // Papers older than the window are dropped, however many upvotes they have.
        #expect(try await ResearchFetcher().fetch(since: since, topics: []).map(\.score) == [12])
    }

    @Test func communitySources() async throws {
        StubWeb.serve([("dev.to/api/articles", .init(body: Samples.devTo)),
                       ("lobste.rs", .init(body: Samples.lobsters))])
        #expect(try await DevToFetcher().fetch(since: since, topics: []).map(\.key) == ["dev-5"])
        // Lobsters has no date filter, so posts older than the window are dropped here.
        #expect(try await LobstersFetcher().fetch(since: since, topics: []).map(\.title) == ["Fresh"])
    }

    @Test func painPointsKeepWhatWorkedWhenSomeSearchesFail() async throws {
        StubWeb.serve([("tags=ask_hn", .init(body: Samples.hn)), ("hn.algolia.com", .init(status: 500, body: ""))])
        let items = try await PainPointsFetcher().fetch(since: since, topics: [])
        #expect(!items.isEmpty && items.allSatisfy { $0.source == .painPoints })
        StubWeb.serve([("hn.algolia.com", .init(status: 500, body: ""))])
        await #expect(throws: FetchError.self) { try await PainPointsFetcher().fetch(since: since, topics: []) }
    }

    /// The interest area is the search text (stories and comments); items carry the area source's label.
    @Test func areaSearchSendsOnlyTheInterestArea() async throws {
        StubWeb.serve([("hn.algolia.com", .init(body: Samples.hn))])
        let items = try await AreaDiscussionFetcher(area: "invoice chasing").fetch(since: since, topics: ["secret topic"])
        let address = try #require(StubWeb.requests.first?.url?.absoluteString.removingPercentEncoding)
        #expect(address.contains("query=invoice chasing") && address.contains("tags=(story,comment)"))
        #expect(!address.contains("secret topic"))
        #expect(!items.isEmpty && items.allSatisfy { $0.source == .areaDiscussion })
    }

    @Test func vibeCodeCombinesHackerNewsAndGitHub() async throws {
        StubWeb.serve([("hn.algolia.com", .init(body: Samples.hn)), ("api.github.com", .init(body: Samples.github))])
        let items = try await VibeCodeFetcher().fetch(since: since, topics: [])
        #expect(items.count == VibeCodeFetcher.hnQueries.count + VibeCodeFetcher.githubQueries.count)
        #expect(items.allSatisfy { $0.source == .vibeCode })
    }

    @Test func appStoreTopPaid() async throws {
        StubWeb.serve([("rss.marketingtools.apple.com", .init(body: Samples.topPaid))])
        #expect(try await AppStoreFetcher().fetch(since: since, topics: []).map(\.title) == ["AnkiMobile"])
    }

    /// Business and consumer complaints share the reader; each reads its own genres and labels its own items.
    @Test(arguments: [(SourceKind.appReviews, "genre=6000"), (.consumerReviews, "genre=6013")])
    func appReviewsReadsChartsThenTodaysApps(kind: SourceKind, genreQuery: String) async throws {
        StubWeb.serve([("topgrossingapplications", .init(body: Samples.chart(count: 25))),
                       ("customerreviews", .init(body: Samples.review))])
        let fetcher = AppReviewsFetcher(kind: kind)
        let items = try await fetcher.fetch(since: since, topics: [])
        #expect(!items.isEmpty && items.allSatisfy { $0.source == kind })
        let charts = StubWeb.requests.compactMap { $0.url?.absoluteString }.filter { $0.contains("topgrossing") }
        #expect(charts.count == AppReviewsFetcher.countries.count * fetcher.genres.count)
        #expect(charts.contains { $0.contains(genreQuery) })
    }

    /// Every commercial tag is asked for; a plugin listed under several tags has its reviews read once.
    @Test func wordpressReadsTagsThenTodaysPluginReviews() async throws {
        StubWeb.serve([("wordpress.org/support/plugin/sliced-invoices/reviews/feed/",
                        .init(body: WordPressSamples.reviews(recent: .now.addingTimeInterval(-86_400)))),
                       ("api.wordpress.org/plugins/info/1.2/", .init(body: WordPressSamples.plugins))])
        let items = try await WordPressReviewsFetcher(areaWords: ["invoic"]).fetch(since: since, topics: [])
        #expect(items.map(\.title) == ["Sliced Invoices – WordPress Invoice Plugin: PDF broken after update"])
        let addresses = StubWeb.requests.compactMap { $0.url?.absoluteString }
        #expect(addresses.filter { $0.contains("query_plugins") }.count == WordPressReviewsFetcher.tags.count)
        #expect(addresses.filter { $0.contains("/reviews/feed/") }.count == 1)
        StubWeb.serve([])
        await #expect(throws: FetchError.self) { try await WordPressReviewsFetcher().fetch(since: since, topics: []) }
    }

    @Test func atlassianReadsTrendingAndNew() async throws {
        StubWeb.serve([("marketplace.atlassian.com", .init(body: Samples.atlassian))])
        let items = try await AtlassianFetcher().fetch(since: since, topics: [])
        #expect(items.count == 2)
        StubWeb.serve([])
        await #expect(throws: FetchError.self) { try await AtlassianFetcher().fetch(since: since, topics: []) }
    }

    @Test func ausTenderFollowsNextPages() async throws {
        StubWeb.serve([("/page2", .init(body: Samples.tender(id: "CN2", next: nil))),
                       ("api.tenders.gov.au", .init(body: Samples.tender(id: "CN1", next: "https://api.tenders.gov.au/page2")))])
        let items = try await AusTenderFetcher().fetch(since: since, topics: [])
        #expect(Set(items.map(\.title)) == ["Software licences CN1", "Software licences CN2"])
        #expect(StubWeb.requests.count == 2)
    }

    @Test func gamesCombineEveryPartAndSkipFailures() async throws {
        StubWeb.serve([("itch.io", .init(body: Samples.itch)),
                       ("featuredcategories", .init(body: Samples.steamFeatured)),
                       ("appdetails?appids=1", .init(body: Samples.steamDetails)),
                       ("hn.algolia.com", .init(body: Samples.hn)),
                       ("api.github.com", .init(body: Samples.github)),
                       ("huggingface.co", .init(body: Samples.spaces))])
        let items = try await GamesFetcher().fetch(since: since, topics: [])
        #expect(items.allSatisfy { $0.source == .games })
        // Sky Farm's details call fails (no route), so only Reshine comes from Steam.
        #expect(items.contains { $0.title == "Reshine" && $0.detail == "A puzzle game" })
        #expect(!items.contains { $0.title == "Sky Farm" })
        #expect(items.contains { $0.title == "CellZ" } && items.contains { $0.title == "Talk Bot" })
        StubWeb.serve([])
        await #expect(throws: FetchError.self) { try await GamesFetcher().fetch(since: since, topics: []) }
    }
}
