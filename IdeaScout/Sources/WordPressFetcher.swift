// WordPressFetcher.swift
// "WordPress plugin complaints": recent 1–2 star reviews of popular WordPress.org plugins in commercial categories
// (shops, bookings, invoices, memberships and so on). Plugins come from the public, keyless WordPress.org Plugins API;
// reviews from each plugin's public reviews feed. Terms checked 17 Nov 2026 (see docs/source-terms.md).

import Foundation

/// Reads popular plugins in a few commercial tags, picks today's handful (those about the interest area first), then
/// keeps their recent low-star reviews. The interest area is matched on the phone and never sent to WordPress.org.
struct WordPressReviewsFetcher: ItemFetcher {
    /// Which source this is.
    let kind = SourceKind.wordpressReviews
    /// The interest area's words (`AreaFocus.words`): plugins that mention them are read first.
    var areaWords: [String] = []

    /// Plugin directory tags for things businesses pay for, each checked on WordPress.org on 17 Nov 2026.
    static let tags = ["ecommerce", "booking", "invoice", "membership", "crm", "lms", "events", "donations", "inventory", "forms"]
    /// Plugins asked for per tag (the API returns the most installed first).
    static let perTag = 30
    /// Plugins with fewer active installs are skipped: too few reviews to show a pattern.
    static let minInstalls = 1_000
    /// Plugins whose reviews are read each day.
    static let pluginsPerDay = 8
    /// Most low-star reviews kept per plugin, so one unpopular plugin can't dominate.
    static let reviewsPerPlugin = 4
    /// Most items from this source per refresh.
    static let maxItems = 30
    /// Each feed holds only the newest 30 reviews of any rating, so look back further than other sources.
    static let windowDays = 90.0

    /// One plugin from the directory.
    struct Plugin: Equatable, Sendable {
        /// The directory slug, e.g. "sliced-invoices" (letters, digits and hyphens only).
        var slug: String
        /// Plugin name, plain text.
        var name: String
        /// One-line description, plain text.
        var summary: String
        /// Active installs, as rounded by WordPress.org.
        var installs: Int
        /// The tag it was found under.
        var tag: String
    }

    /// Reads each tag's plugins, picks today's, then reads their review feeds. Throws only if every request failed.
    /// - Parameters:
    ///   - since: Start of the window; reviews look back at least `windowDays`.
    ///   - topics: The user's topics (not used by this source).
    /// - Returns: Up to `maxItems` 1–2 star reviews.
    /// - Throws: The first error, only if every tag failed and no reviews were found.
    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
        var plugins: [Plugin] = []
        var firstError: Error?
        for tag in Self.tags {
            // Safe to unwrap: the tags are fixed letters, so the address is always valid.
            let url = URL(string: "https://api.wordpress.org/plugins/info/1.2/?action=query_plugins&request%5Btag%5D=\(tag)"
                + "&request%5Bper_page%5D=\(Self.perTag)&request%5Bfields%5D%5Bdescription%5D=0"
                + "&request%5Bfields%5D%5Bsections%5D=0&request%5Bfields%5D%5Bicons%5D=0&request%5Bfields%5D%5Btags%5D=0")!
            do { plugins += try Self.parsePlugins(try await HTTP.get(url), tag: tag) }
            catch { firstError = firstError ?? error }
        }
        let day = Calendar.current.ordinality(of: .day, in: .year, for: .now) ?? 0
        let reviewsSince = min(since, Date.now.addingTimeInterval(-Self.windowDays * 86_400))
        var results: [FetchedItem] = []
        for plugin in Self.todaysPlugins(plugins, day: day, areaWords: areaWords) where results.count < Self.maxItems {
            guard let url = URL(string: "https://wordpress.org/support/plugin/\(plugin.slug)/reviews/feed/") else { continue }
            do { results += try Self.parseReviews(try await HTTP.get(url), plugin: plugin, since: reviewsSince) }
            catch { firstError = firstError ?? error }
        }
        if results.isEmpty, plugins.isEmpty, let firstError { throw firstError }
        return Array(results.prefix(Self.maxItems))
    }

    private struct Query: Decodable {
        struct Entry: Decodable {
            let slug: String
            let name: String
            let short_description: String?
            let active_installs: Int?
        }
        let plugins: [Entry]
    }

    /// Reads one page of the Plugins API's `query_plugins` reply.
    /// - Parameters:
    ///   - data: The JSON reply.
    ///   - tag: The tag asked for, kept on each plugin.
    /// - Returns: Plugins with at least `minInstalls` installs and a safe slug.
    /// - Throws: `DecodingError` if the reply's shape has changed.
    static func parsePlugins(_ data: Data, tag: String) throws -> [Plugin] {
        try JSONDecoder().decode(Query.self, from: data).plugins.compactMap { entry in
            let installs = entry.active_installs ?? 0
            // Robustness: the slug becomes part of a link, so anything but letters, digits and hyphens is skipped.
            guard installs >= minInstalls, !entry.slug.isEmpty,
                  entry.slug.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
            return Plugin(slug: entry.slug, name: decodeEntities(TextCleaner.clean(entry.name, max: 80)),
                          summary: decodeEntities(TextCleaner.clean(entry.short_description, max: 160)),
                          installs: installs, tag: tag)
        }
    }

    /// Removes duplicates across tags and picks today's plugins, those about the interest area first.
    /// - Parameters:
    ///   - plugins: Every tag's plugins, most installed first.
    ///   - day: Day of the year, which picks today's slice.
    ///   - areaWords: The interest area's words; empty means no preference.
    /// - Returns: Up to `pluginsPerDay` plugins.
    static func todaysPlugins(_ plugins: [Plugin], day: Int, areaWords: [String] = []) -> [Plugin] {
        var seen = Set<String>()
        let pool = plugins.filter { seen.insert($0.slug).inserted }
        return AreaFocus.todaysPick(pool, count: pluginsPerDay, day: day) {
            AreaFocus.mentions("\($0.name) \($0.summary) \($0.tag)", areaWords)
        }
    }

    /// Keeps reviews of 1–2 stars posted since `since` (at most `reviewsPerPlugin`). Score is 2 for one star,
    /// 1 for two, so the angriest come first.
    /// - Parameters:
    ///   - data: The plugin's reviews RSS feed.
    ///   - plugin: The plugin the reviews belong to.
    ///   - since: Oldest review date kept.
    /// - Returns: Up to `reviewsPerPlugin` items, newest first, each linked to the review on WordPress.org.
    /// - Throws: The XML parser's error if the feed isn't valid XML.
    static func parseReviews(_ data: Data, plugin: Plugin, since: Date) throws -> [FetchedItem] {
        try WordPressReviewFeed.parse(data).compactMap { review -> FetchedItem? in
            guard let stars = review.stars, stars <= 2, review.date >= since,
                  let url = URL(string: review.link), url.scheme == "https" else { return nil }
            let text = decodeEntities(TextCleaner.clean(review.text, max: 300))
            return FetchedItem(key: "wp-\(url.path())", source: .wordpressReviews,
                               title: "\(plugin.name): \(decodeEntities(TextCleaner.clean(review.title, max: 100)))",
                               detail: "★\(stars) review of a WordPress plugin (\(plugin.installs.formatted())+ installs, \(plugin.tag)): \(text)",
                               url: url, score: 3 - stars, postedAt: review.date)
        }
        .prefix(reviewsPerPlugin)
        .map { $0 }
    }

    /// Turns numeric HTML entities such as `&#8217;` (common in WordPress text) into characters.
    /// - Parameter text: Text after `TextCleaner.clean`.
    /// - Returns: The text with each valid numeric entity replaced.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&#") else { return text }
        var result = text
        for match in text.matches(of: #/&#(\d{1,7});/#).reversed() {
            guard let code = UInt32(match.1), let scalar = Unicode.Scalar(code) else { continue }
            result.replaceSubrange(match.range, with: String(Character(scalar)))
        }
        return result
    }
}

/// Parses a WordPress.org plugin reviews feed. Each review's rating is in its title ("Too slow (1 star)") and at
/// the start of its description ("Rating: 1 star").
final class WordPressReviewFeed: NSObject, XMLParserDelegate {
    /// One review from the feed.
    struct Review {
        /// The review's title, without the "(1 star)" ending.
        var title: String
        /// The review text, without the "Replies" and "Rating" lines.
        var text: String
        /// Stars given, 1–5; `nil` if the feed didn't say.
        var stars: Int?
        /// Link to the review on WordPress.org.
        var link: String
        /// When it was posted.
        var date: Date
    }

    private var reviews: [Review] = []
    private var fields: [String: String] = [:]
    private var current = ""
    private var inItem = false

    /// Parses the feed.
    /// - Parameter data: The RSS feed.
    /// - Returns: Every review with a link and a date, in the feed's newest-first order.
    /// - Throws: The XML parser's error if the feed isn't valid XML.
    static func parse(_ data: Data) throws -> [Review] {
        let feed = WordPressReviewFeed()
        let parser = XMLParser(data: data)
        parser.delegate = feed
        guard parser.parse() else { throw parser.parserError ?? FetchError.http(0) }
        return feed.reviews
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    /// Starts collecting an item's fields at <item>.
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if name == "item" { inItem = true; fields = [:] }
        current = ""
    }

    /// Collects text inside the current element.
    func parser(_ parser: XMLParser, foundCharacters string: String) { current += string }

    /// Collects CDATA text (the review body) inside the current element.
    func parser(_ parser: XMLParser, foundCDATA block: Data) { current += String(decoding: block, as: UTF8.self) }

    /// Stores a finished field, and finishes a review at </item>.
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard inItem else { return }
        guard name == "item" else { fields[name] = current.trimmingCharacters(in: .whitespacesAndNewlines); return }
        inItem = false
        guard let link = fields["link"], let date = fields["pubDate"].flatMap(Self.dateFormatter.date(from:)) else { return }
        let rawTitle = fields["title"] ?? ""
        let body = TextCleaner.clean(fields["description"], max: 2_000)
        let rating = body.firstMatch(of: #/Rating: (\d) star/#) ?? rawTitle.firstMatch(of: #/\((\d) stars?\)$/#)
        let title = rawTitle.replacing(#/\s*\(\d stars?\)$/#, with: "")
        let text = body.replacing(#/^Replies: \d+\s*/#, with: "").replacing(#/^Rating: \d stars?\s*/#, with: "")
        reviews.append(Review(title: title, text: text, stars: rating.flatMap { Int($0.1) }, link: link, date: date))
    }
}
