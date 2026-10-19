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
        let data = try await HTTP.get(Self.searchURL(tags: "show_hn", query: nil, since: since, hits: 100))
        return Array(try Self.parse(data, as: .hackerNews).sorted { $0.score > $1.score }.prefix(30))
    }

    static func searchURL(tags: String, query: String?, since: Date, hits: Int) -> URL {
        var c = URLComponents(string: "https://hn.algolia.com/api/v1/search_by_date")!
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

    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
        // New repos rarely gain stars within a day, so look back a week; the
        // digest service skips repos already shown in recent digests.
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: since) ?? since
        var results: [FetchedItem] = []
        for topic in topics.prefix(4) {
            let term = topic.contains(" ") ? "\"\(topic)\"" : topic
            results += try await Self.search("\(term) created:>\(Self.day(weekAgo)) stars:>=5", as: .github)
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
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: since) ?? since
        for query in Self.githubQueries {
            do {
                results += try await GitHubFetcher.search("\(query) created:>\(GitHubFetcher.day(weekAgo))", as: .vibeCode, perPage: 8)
            } catch { firstError = firstError ?? error }
        }
        if results.isEmpty, let firstError { throw firstError }
        return results
    }
}
