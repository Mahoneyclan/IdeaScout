// CodeAndAIFetchers.swift
// Sources for what's being built and what's newly possible: GitHub repositories, Hugging Face Spaces
// (AI demo apps) and Hugging Face daily papers (AI research). All keyless public APIs.

import Foundation

// MARK: - GitHub (search API, no key needed; 10 searches/minute)

/// New repositories (created in the window, 10+ stars) matching the user's topics, most starred first.
struct GitHubFetcher: ItemFetcher {
    /// Which source this is.
    let kind = SourceKind.github
    /// Unauthenticated GitHub search allows 10 searches a minute: 7 topics here, plus 2 for vibe-coded projects
    /// and 1 for games.
    static let maxTopics = 7

    /// One search per topic (up to `maxTopics`).
    /// - Parameters:
    ///   - since: Start of the look-back window.
    ///   - topics: The user's topics; the first `maxTopics` are searched.
    /// - Returns: Up to 10 repositories per topic, most starred first within each topic.
    /// - Throws: Network, HTTP (e.g. 403 when rate-limited) or decoding errors; one failed search fails the source.
    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
        // Sequential on purpose: searches share the 10-a-minute budget described at `maxTopics`.
        var results: [FetchedItem] = []
        for topic in topics.prefix(Self.maxTopics) {
            let term = topic.contains(" ") ? "\"\(topic)\"" : topic
            results += try await Self.search("\(term) created:>\(Self.day(since)) stars:>=10", as: .github)
        }
        return results
    }

    /// The date as yyyy-MM-dd for GitHub's `created:>` filter.
    /// - Parameter date: The window start.
    /// - Returns: The date in the Gregorian calendar, POSIX format.
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
    /// - Returns: The repositories as items.
    /// - Throws: Network, HTTP (e.g. 403 when rate-limited) or decoding errors.
    static func search(_ query: String, as kind: SourceKind, perPage: Int = 10) async throws -> [FetchedItem] {
        // Safe to unwrap: a constant, valid URL.
        var c = URLComponents(string: "https://api.github.com/search/repositories")!
        c.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "sort", value: "stars"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "per_page", value: String(perPage)),
        ]
        // Safe to unwrap: URLComponents percent-encodes the query (which includes the user's topics), so the URL is always valid.
        let data = try await HTTP.get(c.url!, headers: ["Accept": "application/vnd.github+json"])
        return try parse(data, as: kind)
    }

    private struct Response: Decodable {
        /// One repository.
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
    /// - Parameters:
    ///   - data: The search reply.
    ///   - kind: Source label for the items.
    /// - Returns: One item per repository with a valid link.
    /// - Throws: `DecodingError` if the reply's shape has changed.
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

// MARK: - Hugging Face trending Spaces (AI demo apps, no key needed)

/// The 40 trending AI demo apps (Spaces). Off by default (developer-focused).
struct HuggingFaceFetcher: ItemFetcher {
    /// Which source this is.
    let kind = SourceKind.huggingFace

    /// Reads the trending Spaces.
    /// - Parameters:
    ///   - since: Start of the look-back window.
    ///   - topics: The user's topics (not used by this source).
    /// - Returns: The 40 trending Spaces.
    /// - Throws: Network, HTTP or decoding errors.
    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
        // Safe to unwrap: a constant, valid URL.
        var c = URLComponents(string: "https://huggingface.co/api/spaces")!
        c.queryItems = [
            URLQueryItem(name: "sort", value: "trendingScore"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "40"),
            URLQueryItem(name: "full", value: "true"),
        ]
        // Safe to unwrap: a constant address with fixed query items always forms a valid URL.
        return try Self.parse(try await HTTP.get(c.url!))
    }

    private struct Space: Decodable {
        /// The Space's card data (title and short description).
        struct Card: Decodable { let title: String?; let short_description: String? }
        let id: String
        let likes: Int?
        /// Usually whole, but sometimes a decimal (e.g. 78.5, seen 10 Nov 2026).
        let trendingScore: Double?
        let createdAt: Date?
        let cardData: Card?
    }

    /// Turns Spaces into items; likes become the score.
    /// - Parameter data: The Spaces reply.
    /// - Returns: One item per Space; the trending score is used when present, otherwise likes.
    /// - Throws: `DecodingError` if the reply's shape has changed.
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
                               score: space.trendingScore.map { Int($0.rounded()) } ?? space.likes ?? 0, postedAt: space.createdAt ?? .distantPast)
        }
    }
}

// MARK: - Hugging Face daily papers (new AI capabilities: the "why now")

/// The 20 most upvoted AI papers from the window (Hugging Face daily papers): new capabilities that
/// explain "why now".
struct ResearchFetcher: ItemFetcher {
    /// Which source this is.
    let kind = SourceKind.research

    /// Reads the latest papers and keeps the window's 20 most upvoted.
    /// - Parameters:
    ///   - since: Start of the look-back window.
    ///   - topics: The user's topics (not used by this source).
    /// - Returns: Up to 20 papers published since `since`, most upvoted first.
    /// - Throws: Network, HTTP or decoding errors.
    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
        // Safe to unwrap: a constant, valid URL.
        let data = try await HTTP.get(URL(string: "https://huggingface.co/api/daily_papers?limit=40")!)
        return Array(try Self.parse(data).filter { $0.postedAt >= since }.sorted { $0.score > $1.score }.prefix(20))
    }

    private struct Entry: Decodable {
        /// The paper's details.
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
    /// - Parameter data: The daily-papers reply.
    /// - Returns: One item per paper; a paper without a date is dated now.
    /// - Throws: `DecodingError` if the reply's shape has changed.
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
