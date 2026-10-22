// Fetchers.swift
// The supply and timing sources (Hacker News, GitHub, vibe-coded projects, Hugging Face, DEV, games,
// Y Combinator, App Store top paid, AI research, Lobsters), the Hacker News pain-point source, and the
// shared HTTP, text-cleaning and date helpers. Demand sources are in DemandFetchers.swift.
//
// Every fetcher is keyless, read-only and uses public APIs. Each returns FetchedItems for the window
// starting at `since`; DigestService runs them in parallel and turns a thrown error into a warning.

import Foundation

// MARK: - Shared fetcher plumbing

/// One source of items.
protocol ItemFetcher: Sendable {
    /// Which source this is (used in warnings and to pick the window).
    var kind: SourceKind { get }
    /// Fetches the source's items for the window.
    /// - Parameters:
    ///   - since: Start of the look-back window.
    ///   - topics: The user's topics (only GitHub uses them).
    /// - Returns: Items, in the source's own order.
    /// - Throws: Network, HTTP or decoding errors; sources with several feeds only throw if all of them fail.
    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem]
}

/// Errors from source requests, worded for the user.
enum FetchError: LocalizedError {
    case http(Int)
    case missingCredential(String)

    var errorDescription: String? {
        switch self {
        case .http(let code): "Server returned error \(code)"
        case .missingCredential(let name): "Add a \(name) in Settings"
        }
    }
}

/// Plain GET requests for sources: a 30-second timeout, an honest "IdeaScout" User-Agent, and an error
/// for any non-2xx status.
enum HTTP {
    /// Sends a request.
    /// - Returns: The body.
    /// - Throws: `FetchError.http` for non-2xx replies, or network errors.
    static func data(for request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 30
        request.setValue("IdeaScout", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError.http(http.statusCode)
        }
        return data
    }

    /// GET with optional extra headers.
    /// - Throws: As `data(for:)`.
    static func get(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        return try await data(for: request)
    }
}

/// Turns HTML or long text from sources into short plain text for prompts and the UI.
enum TextCleaner {
    /// Strips HTML tags, decodes common entities, collapses whitespace and trims to `max` characters (with "…").
    static func clean(_ html: String?, max: Int = 220) -> String {
        guard var s = html, !s.isEmpty else { return "" }
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, char) in ["&#x27;": "'", "&#39;": "'", "&quot;": "\"", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&#x2F;": "/"] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count > max ? String(s.prefix(max - 1)) + "…" : s
    }

    /// Up to `max` characters of already-clean text, starting a little before the first matching phrase
    /// (case-insensitive). Falls back to the start of the text when no phrase is found.
    static func snippet(_ text: String, around phrases: [String], max: Int = 220, lead: Int = 60) -> String {
        guard text.count > max else { return text }
        let lower = text.lowercased()
        let match = phrases.compactMap { lower.range(of: $0.lowercased()) }.min { $0.lowerBound < $1.lowerBound }
        guard let match else { return String(text.prefix(max - 1)) + "…" }
        let offset = lower.distance(from: lower.startIndex, to: match.lowerBound)
        let start = Swift.max(0, Swift.min(offset - lead, text.count - (max - 1)))
        let begin = text.index(text.startIndex, offsetBy: start)
        let body = String(text[begin...].prefix(max - (start > 0 ? 2 : 1)))
        return (start > 0 ? "…" : "") + body + (start + body.count < text.count ? "…" : "")
    }
}

// MARK: - Hacker News (Algolia API, no key needed)

/// Show HN posts from the window, most upvoted first.
struct HackerNewsFetcher: ItemFetcher {
    let kind = SourceKind.hackerNews

    /// 60 Show HN posts.
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
    static func searchURL(tags: String, query: String?, since: Date, hits: Int) -> URL {
        var c = URLComponents(string: "https://hn.algolia.com/api/v1/search")!
        c.queryItems = [
            URLQueryItem(name: "tags", value: tags),
            URLQueryItem(name: "numericFilters", value: "created_at_i>\(Int(since.timeIntervalSince1970))"),
            URLQueryItem(name: "hitsPerPage", value: String(hits)),
        ]
        if let query { c.queryItems?.append(URLQueryItem(name: "query", value: query)) }
        return c.url!
    }

    private struct Response: Decodable {
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

// MARK: - GitHub (search API, no key needed; 10 searches/minute)

/// New repositories (created in the window, 10+ stars) matching the user's topics, most starred first.
struct GitHubFetcher: ItemFetcher {
    let kind = SourceKind.github
    /// Unauthenticated GitHub search allows 10 searches a minute: 7 topics here, plus 2 for vibe-coded projects
    /// and 1 for games.
    static let maxTopics = 7

    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
        // Unauthenticated GitHub search allows 10 searches a minute; the vibe-code source uses 2.
        var results: [FetchedItem] = []
        for topic in topics.prefix(Self.maxTopics) {
            let term = topic.contains(" ") ? "\"\(topic)\"" : topic
            results += try await Self.search("\(term) created:>\(Self.day(since)) stars:>=10", as: .github)
        }
        return results
    }

    /// The date as yyyy-MM-dd for GitHub's `created:>` filter.
    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Runs one repository search, most stars first.
    /// - Parameters:
    ///   - query: GitHub search syntax.
    ///   - kind: Source label for the results (GitHub is shared by several sources).
    ///   - perPage: How many results.
    /// - Throws: Network, HTTP (e.g. 403 when rate-limited) or decoding errors.
    static func search(_ query: String, as kind: SourceKind, perPage: Int = 10) async throws -> [FetchedItem] {
        var c = URLComponents(string: "https://api.github.com/search/repositories")!
        c.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "sort", value: "stars"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "per_page", value: String(perPage)),
        ]
        let data = try await HTTP.get(c.url!, headers: ["Accept": "application/vnd.github+json"])
        return try parse(data, as: kind)
    }

    private struct Response: Decodable {
        struct Repo: Decodable {
            let id: Int
            let full_name: String
            let html_url: String
            let description: String?
            let stargazers_count: Int
            let created_at: Date
        }
        let items: [Repo]
    }

    /// Turns a search reply into items; stars become the score.
    static func parse(_ data: Data, as kind: SourceKind) throws -> [FetchedItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data).items.compactMap { repo in
            guard let url = URL(string: repo.html_url) else { return nil }
            return FetchedItem(key: "gh-\(repo.id)", source: kind, title: repo.full_name,
                               detail: TextCleaner.clean(repo.description), url: url,
                               score: repo.stargazers_count, postedAt: repo.created_at)
        }
    }
}

// MARK: - Vibe-coded projects (mentions of AI app builders on HN and GitHub)

/// Projects built with AI app builders: Hacker News stories mentioning them, and GitHub repos that say
/// they were vibe-coded or built with Lovable.
struct VibeCodeFetcher: ItemFetcher {
    let kind = SourceKind.vibeCode

    /// Search terms for Hacker News (15 stories each).
    static let hnQueries = ["lovable", "bolt.new", "v0.dev", "vibe coded", "vibe coding", "replit agent", "built with cursor"]
    /// GitHub searches (2 of the 10-per-minute budget).
    static let githubQueries = ["\"vibe coded\" in:description,readme", "\"built with lovable\" in:description,readme"]

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

// MARK: - Hugging Face trending Spaces (AI demo apps, no key needed)

/// The 40 trending AI demo apps (Spaces). Off by default (developer-focused).
struct HuggingFaceFetcher: ItemFetcher {
    let kind = SourceKind.huggingFace

    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
        var c = URLComponents(string: "https://huggingface.co/api/spaces")!
        c.queryItems = [
            URLQueryItem(name: "sort", value: "trendingScore"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "40"),
            URLQueryItem(name: "full", value: "true"),
        ]
        return try Self.parse(try await HTTP.get(c.url!))
    }

    private struct Space: Decodable {
        struct Card: Decodable { let title: String?; let short_description: String? }
        let id: String
        let likes: Int?
        let trendingScore: Int?
        let createdAt: Date?
        let cardData: Card?
    }

    /// Turns Spaces into items; likes become the score.
    static func parse(_ data: Data) throws -> [FetchedItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: text) ?? ISO8601DateFormatter().date(from: text) ?? .distantPast
        }
        return try decoder.decode([Space].self, from: data).compactMap { space in
            guard let url = URL(string: "https://huggingface.co/spaces/\(space.id)") else { return nil }
            let title = space.cardData?.title.flatMap { $0.isEmpty ? nil : $0 } ?? space.id
            return FetchedItem(key: "hf-\(space.id)", source: .huggingFace, title: title,
                               detail: TextCleaner.clean(space.cardData?.short_description), url: url,
                               score: space.trendingScore ?? space.likes ?? 0, postedAt: space.createdAt ?? .distantPast)
        }
    }
}

// MARK: - DEV.to #showdev (developers showing what they built, no key needed)

/// The 40 top #showdev posts for the window. Off by default (developer-focused).
struct DevToFetcher: ItemFetcher {
    let kind = SourceKind.devTo

    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
        let days = max(1, Int(Date.now.timeIntervalSince(since) / 86_400))
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

// MARK: - Product-shaped filter

/// Drops items that can't become a product people pay for (lists, dotfiles, coursework, personal sites).
enum ProductFilter {
    /// Words that mark non-products (or adult content), matched in title and description.
    static let noise = ["awesome-", "awesome list", "dotfiles", "homework", "tutorial", "course notes", "cheatsheet",
                        "cheat sheet", "interview questions", "leetcode", ".github.io", "my portfolio", "hall of fame",
                        "weekly digest", "uncensored", "nsfw", "hentai", "lewd", "18+", "porn"]

    /// - Returns: `false` if the item contains any noise word.
    static func isProductShaped(_ item: FetchedItem) -> Bool {
        let text = "\(item.title) \(item.detail)".lowercased()
        return !noise.contains { text.contains($0) }
    }
}

// MARK: - Games (itch.io newest, Steam coming soon, and game searches on HN, GitHub and Hugging Face)

/// New and upcoming games from five places. Off by default. Each part can fail independently.
struct GamesFetcher: ItemFetcher {
    let kind = SourceKind.games

    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
        var results: [FetchedItem] = []
        var firstError: Error?
        func collect(_ work: () async throws -> [FetchedItem]) async {
            do { results += try await work() } catch { firstError = firstError ?? error }
        }
        await collect { try ItchFeed.parse(try await HTTP.get(URL(string: "https://itch.io/games/newest.xml")!)) }
        await collect { try await SteamStore.upcoming() }
        await collect {
            let data = try await HTTP.get(HackerNewsFetcher.searchURL(tags: "show_hn", query: "game", since: since, hits: 20))
            return try HackerNewsFetcher.parse(data, as: .games)
        }
        await collect { try await GitHubFetcher.search("topic:game created:>\(GitHubFetcher.day(since)) stars:>=10", as: .games, perPage: 10) }
        await collect {
            var c = URLComponents(string: "https://huggingface.co/api/spaces")!
            c.queryItems = [URLQueryItem(name: "search", value: "game"), URLQueryItem(name: "sort", value: "trendingScore"),
                            URLQueryItem(name: "direction", value: "-1"), URLQueryItem(name: "limit", value: "15"),
                            URLQueryItem(name: "full", value: "true")]
            return try HuggingFaceFetcher.parse(try await HTTP.get(c.url!)).map { var item = $0; item.source = .games; return item }
        }
        if results.isEmpty, let firstError { throw firstError }
        return results
    }
}

/// Parses itch.io's RSS feeds (games have a title, link, description and creation date).
final class ItchFeed: NSObject, XMLParserDelegate {
    private var items: [FetchedItem] = []
    private var fields: [String: String] = [:]
    private var current = ""
    private var inItem = false

    /// Parses an itch.io RSS feed into items (no score; dated by creation date).
    static func parse(_ data: Data) throws -> [FetchedItem] {
        let feed = ItchFeed()
        let parser = XMLParser(data: data)
        parser.delegate = feed
        guard parser.parse() else { throw parser.parserError ?? FetchError.http(0) }
        return feed.items
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    /// XMLParserDelegate callbacks: collect each <item>'s fields, then build an item when it closes.
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if name == "item" { inItem = true; fields = [:] }
        current = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { current += string }

    func parser(_ parser: XMLParser, foundCDATA block: Data) { current += String(decoding: block, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard inItem else { return }
        if name == "item" {
            inItem = false
            let title = fields["plainTitle"] ?? fields["title"] ?? ""
            guard !title.isEmpty, let link = fields["link"], let url = URL(string: link) else { return }
            let date = (fields["createDate"] ?? fields["pubDate"]).flatMap { Self.dateFormatter.date(from: $0) } ?? .now
            items.append(FetchedItem(key: "itch-\(url.host() ?? "")\(url.path())", source: .games, title: title,
                                     detail: TextCleaner.clean(fields["description"]), url: url, score: 0, postedAt: date))
        } else {
            fields[name] = current.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// Steam's public store endpoints: featured "coming soon" and "new releases", plus a short description per game.
enum SteamStore {
    /// The featured-categories reply (only the two sections used).
    struct Featured: Decodable {
        struct Section: Decodable { let items: [Entry] }
        struct Entry: Decodable { let id: Int; let name: String; let type: Int? }
        let coming_soon: Section?
        let new_releases: Section?
    }

    /// Up to 20 featured "coming soon" and "new releases" games, each with its short description (one
    /// detail call per game, made in parallel; failures are skipped).
    static func upcoming() async throws -> [FetchedItem] {
        let data = try await HTTP.get(URL(string: "https://store.steampowered.com/api/featuredcategories?cc=us&l=english")!)
        let entries = try parseFeatured(data)
        return await withTaskGroup(of: FetchedItem?.self) { group in
            for entry in entries.prefix(20) {
                group.addTask { try? await details(for: entry) }
            }
            var items: [FetchedItem] = []
            for await item in group { if let item { items.append(item) } }
            return items
        }
    }

    /// Featured entries, de-duplicated, games only (type 0).
    static func parseFeatured(_ data: Data) throws -> [Featured.Entry] {
        let featured = try JSONDecoder().decode(Featured.self, from: data)
        var seen = Set<Int>()
        return ((featured.coming_soon?.items ?? []) + (featured.new_releases?.items ?? []))
            .filter { ($0.type ?? 0) == 0 && seen.insert($0.id).inserted }
    }

    private static func details(for entry: Featured.Entry) async throws -> FetchedItem {
        let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(entry.id)&filters=basic")!
        struct Wrapper: Decodable {
            struct Info: Decodable { let short_description: String? }
            let success: Bool
            let data: Info?
        }
        let response = try JSONDecoder().decode([String: Wrapper].self, from: try await HTTP.get(url))
        let detail = response.values.first?.data?.short_description
        return FetchedItem(key: "steam-\(entry.id)", source: .games, title: entry.name, detail: TextCleaner.clean(detail),
                           url: URL(string: "https://store.steampowered.com/app/\(entry.id)")!, score: 0, postedAt: .now)
    }
}

// MARK: - Pain points (people asking for tools that don't exist yet)

/// Hacker News comments where people complain or ask for a tool (10 per phrase), plus Ask HN posts.
struct PainPointsFetcher: ItemFetcher {
    let kind = SourceKind.painPoints

    /// Exact phrases searched in comments. "is there a tool" was dropped (almost no hits); "too expensive",
    /// "switched from" and "alternative to" find far more real complaints, though noisier (the AI filters them).
    static let phrases = ["\"I wish there was\"", "\"I would pay for\"", "\"I'd pay for\"", "\"looking for a tool\"",
                          "\"why is there no\"", "\"too expensive\"", "\"switched from\"", "\"alternative to\""]

    /// The phrases without quotes, used to cut each comment to the part around the complaint.
    static var plainPhrases: [String] { phrases.map { $0.replacingOccurrences(of: "\"", with: "") } }

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

// MARK: - Shared date parsing

/// Date parsing shared by sources whose dates vary in format.
enum ISODates {
    /// Parses ISO 8601 dates with or without fractional seconds and with any time-zone offset.
    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// A JSON decoder that reads ISO 8601 dates in any of the formats above.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = parse(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(text)"))
            }
            return date
        }
        return decoder
    }
}

// MARK: - Y Combinator (latest funded B2B startups, plus Launch HN posts)

/// Business startups from the newest Y Combinator batch (via the unofficial yc-oss data), plus Launch HN posts.
struct YCombinatorFetcher: ItemFetcher {
    let kind = SourceKind.ycombinator
    /// Companies sent per day from the batch.
    static let perDay = 25

    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
        var results: [FetchedItem] = []
        var firstError: Error?
        do {
            let companies = try await latestBatch(since: since)
            results += Self.rotation(companies, day: Calendar.current.ordinality(of: .day, in: .year, for: .now) ?? 0)
        } catch { firstError = error }
        do {
            let data = try await HTTP.get(HackerNewsFetcher.searchURL(tags: "launch_hn", query: nil, since: since, hits: 20))
            results += try HackerNewsFetcher.parse(data, as: .ycombinator)
        } catch { firstError = firstError ?? error }
        if results.isEmpty, let firstError { throw firstError }
        return results
    }

    /// yc-oss's list of every B2B company (about 5 MB), refreshed daily by that project.
    static let b2bURL = URL(string: "https://yc-oss.github.io/api/industries/b2b.json")!
    /// A batch is only used once it has this many B2B companies (future batches start nearly empty).
    static let minimumBatchSize = 30

    /// Downloads the B2B list and keeps the newest full batch.
    private func latestBatch(since: Date) async throws -> [FetchedItem] {
        try Self.newestBatch(in: try await HTTP.get(Self.b2bURL), postedAt: since)
    }

    /// Business (B2B) companies from the newest batch that has at least `minimumBatchSize` of them.
    static func newestBatch(in data: Data, postedAt: Date) throws -> [FetchedItem] {
        let companies = try JSONDecoder().decode([Company].self, from: data)
        let counts = Dictionary(grouping: companies.compactMap(\.batch), by: { $0 }).mapValues(\.count)
        guard let batch = counts.filter({ $0.value >= minimumBatchSize }).keys.max(by: { batchOrder($0) < batchOrder($1) })
        else { throw FetchError.http(404) }
        return items(companies.filter { $0.batch == batch }, postedAt: postedAt)
    }

    /// "Fall 2026" → 20264. YC runs Winter, Spring, Summer and Fall batches.
    static func batchOrder(_ batch: String) -> Int {
        let parts = batch.split(separator: " ")
        guard parts.count == 2, let year = Int(parts[1]) else { return 0 }
        let season = ["winter": 1, "spring": 2, "summer": 3, "fall": 4][parts[0].lowercased()] ?? 0
        return year * 10 + season
    }

    /// The same batch is sent every day, so rotate through it ~25 companies at a time.
    static func rotation(_ items: [FetchedItem], day: Int) -> [FetchedItem] {
        guard items.count > perDay else { return items }
        let start = (day * perDay) % items.count
        return (0..<perDay).map { items[(start + $0) % items.count] }
    }

    private struct Company: Decodable {
        let id: Int
        let name: String
        let one_liner: String?
        let url: String
        let industry: String?
        let subindustry: String?
        let batch: String?
    }

    /// Batches have no useful date, so items are dated at the start of the window (never "new").
    static func parse(_ data: Data, postedAt: Date) throws -> [FetchedItem] {
        items(try JSONDecoder().decode([Company].self, from: data), postedAt: postedAt)
    }

    private static func items(_ companies: [Company], postedAt: Date) -> [FetchedItem] {
        companies.compactMap { c in
            guard let url = URL(string: c.url) else { return nil }
            let area = c.subindustry?.replacingOccurrences(of: " -> ", with: ": ") ?? c.industry
            let extras = [area, c.batch.map { "YC \($0)" }].compactMap { $0 }.joined(separator: ", ")
            let detail = [c.one_liner ?? "", extras.isEmpty ? "" : "(\(extras))"].filter { !$0.isEmpty }.joined(separator: " ")
            return FetchedItem(key: "yc-\(c.id)", source: .ycombinator, title: c.name, detail: TextCleaner.clean(detail),
                               url: url, score: 0, postedAt: postedAt)
        }
    }
}

// MARK: - App Store top paid iPhone apps (what people pay for right now)

/// The 25 top paid iPhone apps in the US: evidence of what people pay for.
struct AppStoreFetcher: ItemFetcher {
    let kind = SourceKind.appStore

    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
        let url = URL(string: "https://rss.marketingtools.apple.com/api/v2/us/apps/top-paid/25/apps.json")!
        return try Self.parse(try await HTTP.get(url), postedAt: since)
    }

    private struct Response: Decodable {
        struct Feed: Decodable { let results: [App] }
        struct App: Decodable {
            struct Genre: Decodable { let name: String? }
            let id: String
            let name: String
            let artistName: String?
            let url: String
            let genres: [Genre]?
        }
        let feed: Feed
    }

    /// Rank becomes the score (number 1 scores highest).
    static func parse(_ data: Data, postedAt: Date) throws -> [FetchedItem] {
        let apps = try JSONDecoder().decode(Response.self, from: data).feed.results
        return apps.enumerated().compactMap { rank, app in
            guard let url = URL(string: app.url) else { return nil }
            let genre = app.genres?.compactMap(\.name).first
            var detail = "#\(rank + 1) top paid iPhone app"
            if let genre { detail += " in \(genre)" }
            if let artist = app.artistName { detail += ", by \(artist)" }
            return FetchedItem(key: "app-\(app.id)", source: .appStore, title: app.name, detail: detail, url: url,
                               score: apps.count - rank, postedAt: postedAt)
        }
    }
}

// MARK: - Hugging Face daily papers (new AI capabilities: the "why now")

/// The 20 most upvoted AI papers from the window (Hugging Face daily papers): new capabilities that
/// explain "why now".
struct ResearchFetcher: ItemFetcher {
    let kind = SourceKind.research

    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
        let data = try await HTTP.get(URL(string: "https://huggingface.co/api/daily_papers?limit=40")!)
        return Array(try Self.parse(data).filter { $0.postedAt >= since }.sorted { $0.score > $1.score }.prefix(20))
    }

    private struct Entry: Decodable {
        struct Paper: Decodable {
            let id: String
            let title: String
            let summary: String?
            let ai_summary: String?
            let upvotes: Int?
        }
        let paper: Paper
        let publishedAt: Date?
    }

    /// Turns papers into items; upvotes become the score; uses the AI summary when available.
    static func parse(_ data: Data) throws -> [FetchedItem] {
        try ISODates.decoder().decode([Entry].self, from: data).compactMap { entry in
            let p = entry.paper
            guard let url = URL(string: "https://huggingface.co/papers/\(p.id)") else { return nil }
            return FetchedItem(key: "paper-\(p.id)", source: .research, title: p.title,
                               detail: TextCleaner.clean(p.ai_summary ?? p.summary), url: url, score: p.upvotes ?? 0,
                               postedAt: entry.publishedAt ?? .now)
        }
    }
}

// MARK: - Lobsters "show" (developers presenting their projects)

/// Lobsters "show" posts from the window. Off by default (developer-focused).
struct LobstersFetcher: ItemFetcher {
    let kind = SourceKind.lobsters

    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
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
    static func parse(_ data: Data) throws -> [FetchedItem] {
        try ISODates.decoder().decode([Story].self, from: data).compactMap { s in
            let link = (s.url?.isEmpty == false ? s.url : nil) ?? s.comments_url
            guard let url = URL(string: link) else { return nil }
            return FetchedItem(key: "lob-\(s.short_id)", source: .lobsters, title: s.title,
                               detail: TextCleaner.clean(s.description_plain), url: url, score: s.score ?? 0, postedAt: s.created_at)
        }
    }
}
