// MarketFetchers.swift
// Sources that show what people pay for: the App Store's top paid iPhone apps. (Y Combinator was read here
// until 17 Nov 2026.)

import Foundation

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
