// MarketFetchers.swift
// Sources that show what people pay for: Y Combinator's newest B2B companies (plus Launch HN) and the
// App Store's top paid iPhone apps.

import Foundation

// MARK: - Y Combinator (latest funded B2B startups, plus Launch HN posts)

/// Business startups from the newest Y Combinator batch (via the unofficial yc-oss data), plus Launch HN posts.
struct YCombinatorFetcher: ItemFetcher {
    /// Which source this is.
    let kind = SourceKind.ycombinator
    /// Companies sent per day from the batch.
    static let perDay = 25

    /// The newest B2B batch (rotated), plus Launch HN; throws only if both failed.
    /// - Parameters:
    ///   - since: Start of the window; also the date given to the companies.
    ///   - topics: The user's topics (not used by this source).
    /// - Returns: About `perDay` companies plus up to 20 Launch HN posts.
    /// - Throws: The first error, only if both parts failed.
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

    // Safe to unwrap: a constant, valid URL.
    /// yc-oss's list of every B2B company (about 5 MB), refreshed daily by that project.
    static let b2bURL = URL(string: "https://yc-oss.github.io/api/industries/b2b.json")!
    /// A batch is only used once it has this many B2B companies (future batches start nearly empty).
    static let minimumBatchSize = 30

    /// Downloads the B2B list and keeps the newest full batch.
    private func latestBatch(since: Date) async throws -> [FetchedItem] {
        try Self.newestBatch(in: try await HTTP.get(Self.b2bURL), postedAt: since)
    }

    /// Business (B2B) companies from the newest batch that has at least `minimumBatchSize` of them.
    /// - Parameters:
    ///   - data: The yc-oss B2B list.
    ///   - postedAt: Date given to every company.
    /// - Returns: The batch's companies as items.
    /// - Throws: `DecodingError` if the list's shape has changed, or `FetchError.http(404)` if no batch is big enough.
    static func newestBatch(in data: Data, postedAt: Date) throws -> [FetchedItem] {
        let companies = try JSONDecoder().decode([Company].self, from: data)
        let counts = Dictionary(grouping: companies.compactMap(\.batch), by: { $0 }).mapValues(\.count)
        guard let batch = counts.filter({ $0.value >= minimumBatchSize }).keys.max(by: { batchOrder($0) < batchOrder($1) })
        else { throw FetchError.http(404) }
        return items(companies.filter { $0.batch == batch }, postedAt: postedAt)
    }

    /// "Fall 2026" → 20264. YC runs Winter, Spring, Summer and Fall batches.
    /// - Parameter batch: The batch name from yc-oss.
    /// - Returns: A sortable number; 0 for names it can't read.
    static func batchOrder(_ batch: String) -> Int {
        let parts = batch.split(separator: " ")
        guard parts.count == 2, let year = Int(parts[1]) else { return 0 }
        let season = ["winter": 1, "spring": 2, "summer": 3, "fall": 4][parts[0].lowercased()] ?? 0
        return year * 10 + season
    }

    /// The same batch is sent every day, so rotate through it ~25 companies at a time.
    /// - Parameters:
    ///   - items: The batch's companies.
    ///   - day: Day of the year, which picks today's slice.
    /// - Returns: Up to `perDay` companies, wrapping round the batch.
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
    /// - Parameters:
    ///   - data: A yc-oss company list.
    ///   - postedAt: Date given to every company.
    /// - Returns: One item per company with a valid link.
    /// - Throws: `DecodingError` if the reply's shape has changed.
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
    /// Which source this is.
    let kind = SourceKind.appStore

    /// Reads the US top-paid chart.
    /// - Parameters:
    ///   - since: Start of the look-back window.
    ///   - topics: The user's topics (not used by this source).
    /// - Returns: The 25 apps, dated at the start of the window.
    /// - Throws: Network, HTTP or decoding errors.
    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
        // Safe to unwrap: a constant, valid URL.
        let url = URL(string: "https://rss.marketingtools.apple.com/api/v2/us/apps/top-paid/25/apps.json")!
        return try Self.parse(try await HTTP.get(url), postedAt: since)
    }

    private struct Response: Decodable {
        /// The feed wrapper.
        struct Feed: Decodable { let results: [App] }
        /// One app in the chart.
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
    /// - Parameters:
    ///   - data: The chart reply.
    ///   - postedAt: Date given to every app (charts have no useful date).
    /// - Returns: One item per app with a valid link.
    /// - Throws: `DecodingError` if the reply's shape has changed.
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
