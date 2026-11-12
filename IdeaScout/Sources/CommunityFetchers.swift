// CommunityFetchers.swift
// Sources from developer communities: Hacker News (Show HN), Hacker News pain points (complaints and
// requests in comments), vibe-coded projects, DEV #showdev and Lobsters. All keyless public APIs.

import Foundation

// MARK: - Hacker News (Algolia API, no key needed)

/// Show HN posts from the window, most upvoted first.
struct HackerNewsFetcher: ItemFetcher {
    /// Which source this is.
    let kind = SourceKind.hackerNews

    /// 60 Show HN posts.
    /// - Parameters:
    ///   - since: Start of the look-back window.
    ///   - topics: The user's topics (not used by this source).
    /// - Returns: Up to 60 Show HN posts from the window, most upvoted first.
    /// - Throws: Network, HTTP or decoding errors.
    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
        let data = try await HTTP.get(Self.searchURL(tags: "show_hn", query: nil, since: since, hits: 60))
        return try Self.parse(data, as: .hackerNews)
    }

    /// Uses Algolia's popularity-ranked search, so a multi-day window returns the most upvoted posts.
    /// - Parameters:
    ///   - tags: Algolia tags, e.g. "show_hn", "story", "comment", "ask_hn", "launch_hn".
    ///   - query: Optional search text.
    ///   - since: Only items created after this.
    ///   - hits: How many results.
    /// - Returns: The search address.
    static func searchURL(tags: String, query: String?, since: Date, hits: Int) -> URL {
        // Safe to unwrap: a constant, valid URL.
        var c = URLComponents(string: "https://hn.algolia.com/api/v1/search")!
        c.queryItems = [
            URLQueryItem(name: "tags", value: tags),
            URLQueryItem(name: "numericFilters", value: "created_at_i>\(Int(since.timeIntervalSince1970))"),
            URLQueryItem(name: "hitsPerPage", value: String(hits)),
        ]
        if let query { c.queryItems?.append(URLQueryItem(name: "query", value: query)) }
        // Safe to unwrap: query items are percent-encoded by URLComponents, so the URL is always valid.
        return c.url!
    }

    private struct Response: Decodable {
        /// One search result (story or comment).
        struct Hit: Decodable {
            let objectID: String
            let title: String?
            let url: String?
            let points: Int?
            let created_at_i: Int
            let story_text: String?
            let comment_text: String?
            let story_title: String?
        }
        let hits: [Hit]
    }

    /// The Hacker News discussion page for an item ID, or `nil` if the ID can't form a valid link.
    /// - Parameter objectID: The item ID from Algolia.
    /// - Returns: The `news.ycombinator.com/item` link, or `nil`.
    static func discussionURL(_ objectID: String) -> URL? {
        var c = URLComponents(string: "https://news.ycombinator.com/item")
        c?.queryItems = [URLQueryItem(name: "id", value: objectID)]
        return c?.url
    }

    /// Turns Algolia hits into items. Stories use their title (minus "Show HN:"); comments have no title, so
    /// the comment text becomes the title and "In thread: …" the detail.
    /// - Parameters:
    ///   - data: The Algolia reply.
    ///   - kind: Source label for the items (Hacker News search is shared by several sources).
    ///   - phrases: For comments, phrases to centre the title on (so a long comment keeps the complaint).
    /// - Returns: One item per usable hit; hits without a title or comment text are skipped.
    /// - Throws: `DecodingError` if the reply's shape has changed.
    static func parse(_ data: Data, as kind: SourceKind, around phrases: [String] = []) throws -> [FetchedItem] {
        try JSONDecoder().decode(Response.self, from: data).hits.compactMap { hit in
            // Robustness: the discussion link is built from data the API supplies; skip the hit if it's malformed.
            guard let discussion = Self.discussionURL(hit.objectID) else { return nil }
            // Comments have no title: use the part of the comment around the phrase, with the thread as detail.
            if hit.title == nil, let comment = hit.comment_text {
                let text = TextCleaner.snippet(TextCleaner.clean(comment, max: 5000), around: phrases, max: 220)
                guard !text.isEmpty else { return nil }
                return FetchedItem(key: "hn-\(hit.objectID)", source: kind, title: text,
                                   detail: hit.story_title.map { "In thread: \($0)" } ?? "",
                                   url: discussion,
                                   score: hit.points ?? 0,
                                   postedAt: Date(timeIntervalSince1970: TimeInterval(hit.created_at_i)))
            }
            guard let rawTitle = hit.title, !rawTitle.isEmpty else { return nil }
            let title = rawTitle.replacingOccurrences(of: "^Show HN:\\s*", with: "", options: .regularExpression)
            let url = hit.url.flatMap(URL.init(string:)) ?? discussion
            return FetchedItem(key: "hn-\(hit.objectID)", source: kind, title: title,
                               detail: TextCleaner.clean(hit.story_text), url: url, score: hit.points ?? 0,
                               postedAt: Date(timeIntervalSince1970: TimeInterval(hit.created_at_i)))
        }
    }
}

// MARK: - Pain points (people asking for tools that don't exist yet)

/// Hacker News comments where people complain or ask for a tool (10 per phrase), plus Ask HN posts.
struct PainPointsFetcher: ItemFetcher {
    /// Which source this is.
    let kind = SourceKind.painPoints

    /// Exact phrases searched in comments. "is there a tool" was dropped (almost no hits); "too expensive",
    /// "switched from" and "alternative to" find far more real complaints, though noisier (the AI filters them).
    static let phrases = ["\"I wish there was\"", "\"I would pay for\"", "\"I'd pay for\"", "\"looking for a tool\"",
                          "\"why is there no\"", "\"too expensive\"", "\"switched from\"", "\"alternative to\""]

    /// The phrases without quotes, used to cut each comment to the part around the complaint.
    static var plainPhrases: [String] { phrases.map { $0.replacingOccurrences(of: "\"", with: "") } }

    /// One search per phrase, plus Ask HN; throws only if every search failed.
    /// - Parameters:
    ///   - since: Start of the look-back window.
    ///   - topics: The user's topics (not used by this source).
    /// - Returns: Up to 10 comments per phrase plus 15 Ask HN posts.
    /// - Throws: The first error, only if every search failed and nothing was found.
    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
        var results: [FetchedItem] = []
        var firstError: Error?
        for phrase in Self.phrases {
            do {
                let data = try await HTTP.get(HackerNewsFetcher.searchURL(tags: "comment", query: phrase, since: since, hits: 10))
                results += try HackerNewsFetcher.parse(data, as: .painPoints, around: Self.plainPhrases)
            } catch { firstError = firstError ?? error }
        }
        do {
            let data = try await HTTP.get(HackerNewsFetcher.searchURL(tags: "ask_hn", query: nil, since: since, hits: 15))
            results += try HackerNewsFetcher.parse(data, as: .painPoints)
        } catch { firstError = firstError ?? error }
        if results.isEmpty, let firstError { throw firstError }
        return results
    }
}

// MARK: - Hacker News on the interest area

/// Recent Hacker News stories and comments that mention the user's interest area. The interest area is the only
/// user text sent anywhere by a source (to Hacker News search, run by Algolia); see the privacy policy.
struct AreaDiscussionFetcher: ItemFetcher {
    /// Which source this is.
    let kind = SourceKind.areaDiscussion
    /// The interest area from Settings (not empty; the source is skipped when it is).
    let area: String
    /// Stories and comments read per scan.
    static let hits = 40

    /// The search address: stories and comments matching the interest area, most upvoted first.
    /// - Parameters:
    ///   - area: The interest area.
    ///   - since: Start of the window.
    /// - Returns: The Algolia search address.
    static func searchURL(area: String, since: Date) -> URL {
        HackerNewsFetcher.searchURL(tags: "(story,comment)", query: TextCleaner.clean(area, max: 100), since: since, hits: hits)
    }

    /// One search for the interest area.
    /// - Parameters:
    ///   - since: Start of the look-back window (the longer complaints window).
    ///   - topics: The user's topics (not used by this source).
    /// - Returns: Up to `hits` stories and comments, each comment cut to the part around the area's words.
    /// - Throws: Network, HTTP or decoding errors.
    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
        let data = try await HTTP.get(Self.searchURL(area: area, since: since))
        return try HackerNewsFetcher.parse(data, as: .areaDiscussion, around: AreaFocus.words(in: area))
    }
}

// MARK: - Vibe-coded projects (mentions of AI app builders on HN and GitHub)

/// Projects built with AI app builders: Hacker News stories mentioning them, and GitHub repos that say
/// they were vibe-coded or built with Lovable or Replit.
struct VibeCodeFetcher: ItemFetcher {
    /// Which source this is.
    let kind = SourceKind.vibeCode

    /// Search terms for Hacker News (15 stories each).
    static let hnQueries = ["lovable", "bolt.new", "v0.dev", "vibe coded", "vibe coding", "replit agent", "made with replit", "built with cursor"]
    /// GitHub searches (2 of the 10-per-minute budget, which the GitHub, Games and this source fill exactly, so add
    /// terms with OR rather than as new searches). Replit's own Gallery and forum can't be read: its terms forbid
    /// scraping (checked 11 Nov 2026), so Replit-built apps are found here and on Hacker News instead.
    static let githubQueries = ["\"vibe coded\" in:description,readme",
                                "\"built with lovable\" OR \"built with replit\" in:description,readme"]

    /// HN searches, then GitHub searches; throws only if every search failed.
    /// - Parameters:
    ///   - since: Start of the look-back window.
    ///   - topics: The user's topics (not used by this source).
    /// - Returns: Up to 15 stories per HN term and 10 repositories per GitHub search.
    /// - Throws: The first error, only if every search failed and nothing was found.
    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
        var results: [FetchedItem] = []
        var firstError: Error?
        for query in Self.hnQueries {
            do {
                let data = try await HTTP.get(HackerNewsFetcher.searchURL(tags: "story", query: query, since: since, hits: 15))
                results += try HackerNewsFetcher.parse(data, as: .vibeCode)
            } catch { firstError = firstError ?? error }
        }
        for query in Self.githubQueries {
            do {
                results += try await GitHubFetcher.search("\(query) created:>\(GitHubFetcher.day(since))", as: .vibeCode, perPage: 10)
            } catch { firstError = firstError ?? error }
        }
        if results.isEmpty, let firstError { throw firstError }
        return results
    }
}

// MARK: - DEV.to #showdev (developers showing what they built, no key needed)

/// The 40 top #showdev posts for the window. Off by default (developer-focused).
struct DevToFetcher: ItemFetcher {
    /// Which source this is.
    let kind = SourceKind.devTo

    /// Reads the top #showdev posts for the window's length in days.
    /// - Parameters:
    ///   - since: Start of the look-back window.
    ///   - topics: The user's topics (not used by this source).
    /// - Returns: Up to 40 posts.
    /// - Throws: Network, HTTP or decoding errors.
    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
        let days = max(1, Int(Date.now.timeIntervalSince(since) / 86_400))
        // Safe to unwrap: `days` is an Int, so the address is always valid.
        let url = URL(string: "https://dev.to/api/articles?tag=showdev&top=\(days)&per_page=40")!
        return try Self.parse(try await HTTP.get(url))
    }

    private struct Article: Decodable {
        let id: Int
        let title: String
        let description: String?
        let url: String
        let positive_reactions_count: Int
        let published_at: Date
    }

    /// Turns articles into items; reactions become the score.
    /// - Parameter data: The articles reply.
    /// - Returns: One item per article with a valid link.
    /// - Throws: `DecodingError` if the reply's shape has changed.
    static func parse(_ data: Data) throws -> [FetchedItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Article].self, from: data).compactMap { a in
            guard let url = URL(string: a.url) else { return nil }
            return FetchedItem(key: "dev-\(a.id)", source: .devTo, title: a.title, detail: TextCleaner.clean(a.description),
                               url: url, score: a.positive_reactions_count, postedAt: a.published_at)
        }
    }
}

// MARK: - Lobsters "show" (developers presenting their projects)

/// Lobsters "show" posts from the window. Off by default (developer-focused).
struct LobstersFetcher: ItemFetcher {
    /// Which source this is.
    let kind = SourceKind.lobsters

    /// Reads the "show" tag and keeps posts from the window.
    /// - Parameters:
    ///   - since: Start of the look-back window.
    ///   - topics: The user's topics (not used by this source).
    /// - Returns: The posts from the tag's front page that were created since `since`.
    /// - Throws: Network, HTTP or decoding errors.
    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
        // Safe to unwrap: a constant, valid URL.
        let data = try await HTTP.get(URL(string: "https://lobste.rs/t/show.json")!)
        return try Self.parse(data).filter { $0.postedAt >= since }
    }

    private struct Story: Decodable {
        let short_id: String
        let title: String
        let url: String?
        let comments_url: String
        let score: Int?
        let created_at: Date
        let description_plain: String?
    }

    /// Turns stories into items; votes become the score.
    /// - Parameter data: The tag's JSON.
    /// - Returns: One item per story, linking to the project or, failing that, the discussion.
    /// - Throws: `DecodingError` if the reply's shape has changed.
    static func parse(_ data: Data) throws -> [FetchedItem] {
        try ISODates.decoder().decode([Story].self, from: data).compactMap { s in
            let link = (s.url?.isEmpty == false ? s.url : nil) ?? s.comments_url
            guard let url = URL(string: link) else { return nil }
            return FetchedItem(key: "lob-\(s.short_id)", source: .lobsters, title: s.title,
                               detail: TextCleaner.clean(s.description_plain), url: url, score: s.score ?? 0, postedAt: s.created_at)
        }
    }
}
