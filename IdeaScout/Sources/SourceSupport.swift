// SourceSupport.swift
// Shared plumbing for every source: the ItemFetcher protocol, source errors, the HTTP helper, text
// cleaning, the "product-shaped" filter and date parsing. Individual sources live in the other files
// in this folder.

import Foundation

// MARK: - Shared fetcher plumbing

/// One source of items.
/// Threading: fetchers are `Sendable` values; `DigestService` runs all of them at once in a task group,
/// off the main actor. They make network calls only and never touch the database.
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
    /// The server answered with this non-2xx status code.
    case http(Int)
    /// A source needs a credential the user hasn't added. Currently unused: no remaining source needs one.
    case missingCredential(String)

    /// Plain-English message shown in warnings.
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
    /// - Parameters:
    ///   - url: The address to fetch.
    ///   - headers: Extra headers by name, e.g. `Accept`.
    /// - Returns: The body.
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
    /// - Parameters:
    ///   - html: Source text; `nil` or empty gives "".
    ///   - max: Longest result in characters, including the "…".
    /// - Returns: Plain text for prompts and the UI.
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
    /// - Parameters:
    ///   - text: Already-clean text.
    ///   - phrases: Phrases to centre on; the earliest match wins.
    ///   - max: Longest result in characters, including any "…".
    ///   - lead: Characters of context kept before the match.
    /// - Returns: The text unchanged if it fits, otherwise the excerpt with "…" where text was cut.
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

// MARK: - Product-shaped filter

/// Drops items that can't become a product people pay for (lists, dotfiles, coursework, personal sites).
enum ProductFilter {
    /// Words that mark non-products (or adult content), matched in title and description.
    static let noise = ["awesome-", "awesome list", "dotfiles", "homework", "tutorial", "course notes", "cheatsheet",
                        "cheat sheet", "interview questions", "leetcode", ".github.io", "my portfolio", "hall of fame",
                        "weekly digest", "uncensored", "nsfw", "hentai", "lewd", "18+", "porn"]

    /// Checks an item's title and description against `noise`.
    /// - Parameter item: The item to check.
    /// - Returns: `false` if the item contains any noise word.
    static func isProductShaped(_ item: FetchedItem) -> Bool {
        let text = "\(item.title) \(item.detail)".lowercased()
        return !noise.contains { text.contains($0) }
    }
}

// MARK: - Shared date parsing

/// Date parsing shared by sources whose dates vary in format.
enum ISODates {
    /// Parses ISO 8601 dates with or without fractional seconds and with any time-zone offset.
    /// - Parameter text: The date text from a feed.
    /// - Returns: The date, or `nil` if neither format matches.
    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// A JSON decoder that reads ISO 8601 dates in any of the formats above.
    /// - Returns: A new decoder; an unreadable date makes decoding throw `DecodingError.dataCorrupted`.
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
