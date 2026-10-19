import Foundation

protocol ItemFetcher: Sendable {
    var kind: SourceKind { get }
    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem]
}

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

enum HTTP {
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

    static func get(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        return try await data(for: request)
    }
}

enum TextCleaner {
    /// Strips HTML tags/entities and trims to a maximum length.
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
}

// MARK: - Hacker News (Algolia API, no key needed)

struct HackerNewsFetcher: ItemFetcher {
    let kind = SourceKind.hackerNews

    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
        let data = try await HTTP.get(Self.searchURL(tags: "show_hn", query: nil, since: since, hits: 60))
        return try Self.parse(data, as: .hackerNews)
    }

    /// Uses Algolia's popularity-ranked search, so a week-long window returns the most upvoted posts.
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
        }
        let hits: [Hit]
    }

    static func parse(_ data: Data, as kind: SourceKind) throws -> [FetchedItem] {
        try JSONDecoder().decode(Response.self, from: data).hits.compactMap { hit in
            guard let rawTitle = hit.title, !rawTitle.isEmpty else { return nil }
            let title = rawTitle.replacingOccurrences(of: "^Show HN:\\s*", with: "", options: .regularExpression)
            let url = hit.url.flatMap(URL.init(string:))
                ?? URL(string: "https://news.ycombinator.com/item?id=\(hit.objectID)")!
            return FetchedItem(key: "hn-\(hit.objectID)", source: kind, title: title,
                               detail: TextCleaner.clean(hit.story_text), url: url, score: hit.points ?? 0,
                               postedAt: Date(timeIntervalSince1970: TimeInterval(hit.created_at_i)))
        }
    }
}

// MARK: - GitHub (search API, no key needed; 10 searches/minute)

struct GitHubFetcher: ItemFetcher {
    let kind = SourceKind.github
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

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

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

// MARK: - Product Hunt (GraphQL API, needs a free developer token)

struct ProductHuntFetcher: ItemFetcher {
    let kind = SourceKind.productHunt
    let token: String?

    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
        guard let token, !token.isEmpty else { throw FetchError.missingCredential("Product Hunt token") }
        var request = URLRequest(url: URL(string: "https://api.producthunt.com/v2/api/graphql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let query = """
        query($after: DateTime!) { posts(first: 20, order: VOTES, postedAfter: $after) {
          edges { node { id name tagline url votesCount createdAt } } } }
        """
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "variables": ["after": ISO8601DateFormatter().string(from: since)],
        ])
        return try Self.parse(try await HTTP.data(for: request))
    }

    private struct Response: Decodable {
        struct Node: Decodable {
            let id: String
            let name: String
            let tagline: String?
            let url: String
            let votesCount: Int
            let createdAt: Date
        }
        struct Edge: Decodable { let node: Node }
        struct Posts: Decodable { let edges: [Edge] }
        struct DataField: Decodable { let posts: Posts }
        let data: DataField
    }

    static func parse(_ data: Data) throws -> [FetchedItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data).data.posts.edges.compactMap { edge in
            let n = edge.node
            guard let url = URL(string: n.url) else { return nil }
            return FetchedItem(key: "ph-\(n.id)", source: .productHunt, title: n.name,
                               detail: TextCleaner.clean(n.tagline), url: url, score: n.votesCount, postedAt: n.createdAt)
        }
    }
}

// MARK: - Vibe-coded projects (mentions of AI app builders on HN and GitHub)

struct VibeCodeFetcher: ItemFetcher {
    let kind = SourceKind.vibeCode

    static let hnQueries = ["lovable", "bolt.new", "v0.dev", "vibe coded", "vibe coding", "replit agent", "built with cursor"]
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
    static let noise = ["awesome-", "awesome list", "dotfiles", "homework", "tutorial", "course notes", "cheatsheet",
                        "cheat sheet", "interview questions", "leetcode", ".github.io", "my portfolio", "hall of fame",
                        "weekly digest", "uncensored", "nsfw", "hentai", "lewd", "18+", "porn"]

    static func isProductShaped(_ item: FetchedItem) -> Bool {
        let text = "\(item.title) \(item.detail)".lowercased()
        return !noise.contains { text.contains($0) }
    }
}

// MARK: - Games (itch.io newest, Steam coming soon, and game searches on HN, GitHub and Hugging Face)

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
    struct Featured: Decodable {
        struct Section: Decodable { let items: [Entry] }
        struct Entry: Decodable { let id: Int; let name: String; let type: Int? }
        let coming_soon: Section?
        let new_releases: Section?
    }

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
