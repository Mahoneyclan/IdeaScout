// GamesFetchers.swift
// The optional Games source (off by default): itch.io, Steam, and game searches on Hacker News, GitHub
// and Hugging Face.

import Foundation

// MARK: - Games (itch.io newest, Steam coming soon, and game searches on HN, GitHub and Hugging Face)

/// New and upcoming games from five places. Off by default. Each part can fail independently.
struct GamesFetcher: ItemFetcher {
    /// Which source this is.
    let kind = SourceKind.games

    /// Collects every part; throws only if all failed.
    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
        var results: [FetchedItem] = []
        var firstError: Error?
        /// Adds one part's items, remembering the first error.
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

    /// Collects text inside the current element.
    func parser(_ parser: XMLParser, foundCharacters string: String) { current += string }

    /// Collects CDATA text inside the current element.
    func parser(_ parser: XMLParser, foundCDATA block: Data) { current += String(decoding: block, as: UTF8.self) }

    /// Stores a finished field, and finishes an item at </item>.
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
        /// One featured section.
        struct Section: Decodable { let items: [Entry] }
        /// One entry in the feed.
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
        /// The appdetails reply for one game.
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
