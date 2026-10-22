import Foundation

// Sources of demand: what businesses complain about, ask for or spend money on.

// MARK: - Field notes (the owner's own work problems, typed in Settings)

struct FieldNotesFetcher: ItemFetcher {
    let kind = SourceKind.fieldNotes
    let notes: String

    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
        Self.items(from: notes, postedAt: since)
    }

    /// One item per non-empty line. The key comes from the text, so an edited note counts as a new one.
    static func items(from notes: String, postedAt: Date) -> [FetchedItem] {
        notes.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { index, line in
                let key = KillerIdea.key(for: line).prefix(60)
                return FetchedItem(key: "note-\(key)", source: .fieldNotes, title: line,
                                   detail: "From my own work", url: URL(string: "ideascout://field-note/\(index + 1)")!,
                                   score: 0, postedAt: postedAt)
            }
    }
}

// MARK: - App Store complaints (1-2 star reviews of top-grossing business apps)

struct AppReviewsFetcher: ItemFetcher {
    let kind = SourceKind.appReviews
    static let countries = ["au", "us"]
    static let genres = ["6000": "Business", "6015": "Finance", "6007": "Productivity"]
    static let appsPerDay = 12
    static let reviewsPerApp = 5
    /// Low-star reviews of business apps are rare, so look back further than other sources.
    static let windowDays = 60.0

    struct App: Equatable, Sendable {
        var id: String
        var name: String
        var country: String
        var genre: String
        var rank: Int
    }

    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
        var apps: [App] = []
        var firstError: Error?
        for country in Self.countries {
            for (genreID, genre) in Self.genres.sorted(by: { $0.key < $1.key }) {
                let url = URL(string: "https://itunes.apple.com/\(country)/rss/topgrossingapplications/limit=25/genre=\(genreID)/json")!
                do { apps += try Self.parseChart(try await HTTP.get(url), country: country, genre: genre) }
                catch { firstError = firstError ?? error }
            }
        }
        let day = Calendar.current.ordinality(of: .day, in: .year, for: .now) ?? 0
        var results: [FetchedItem] = []
        let reviewsSince = min(since, Date.now.addingTimeInterval(-Self.windowDays * 86_400))
        for app in Self.todaysApps(apps, day: day) {
            let url = URL(string: "https://itunes.apple.com/\(app.country)/rss/customerreviews/page=1/id=\(app.id)/sortby=mostrecent/json")!
            do { results += try Self.parseReviews(try await HTTP.get(url), app: app, since: reviewsSince) }
            catch { firstError = firstError ?? error }
        }
        if results.isEmpty, apps.isEmpty, let firstError { throw firstError }
        return results
    }

    private struct Chart: Decodable {
        struct Feed: Decodable { let entry: [Entry]? }
        struct Entry: Decodable {
            struct Label: Decodable { let label: String }
            struct ID: Decodable {
                struct Attributes: Decodable { let id: String; enum CodingKeys: String, CodingKey { case id = "im:id" } }
                let attributes: Attributes
            }
            let name: Label
            let id: ID
            enum CodingKeys: String, CodingKey { case name = "im:name", id }
        }
        let feed: Feed
    }

    static func parseChart(_ data: Data, country: String, genre: String) throws -> [App] {
        (try JSONDecoder().decode(Chart.self, from: data).feed.entry ?? []).enumerated().map { index, entry in
            App(id: entry.id.attributes.id, name: entry.name.label, country: country, genre: genre, rank: index + 1)
        }
    }

    /// Skips the top 5 (giants like LinkedIn, whose complaints are too general), removes duplicates
    /// across charts, then rotates through the rest a few apps a day.
    static func todaysApps(_ apps: [App], day: Int) -> [App] {
        var seen = Set<String>()
        let pool = apps.filter { $0.rank > 5 && seen.insert($0.id).inserted }
        guard pool.count > appsPerDay else { return pool }
        let start = (day * appsPerDay) % pool.count
        return (0..<appsPerDay).map { pool[(start + $0) % pool.count] }
    }

    private struct Reviews: Decodable {
        struct Feed: Decodable { let entry: [Entry]? }
        struct Entry: Decodable {
            struct Label: Decodable { let label: String }
            let id: Label
            let title: Label
            let content: Label?
            let rating: Label?
            let updated: Label
            enum CodingKeys: String, CodingKey { case id, title, content, rating = "im:rating", updated }
        }
        let feed: Feed
    }

    static func parseReviews(_ data: Data, app: App, since: Date) throws -> [FetchedItem] {
        let entries = try JSONDecoder().decode(Reviews.self, from: data).feed.entry ?? []
        let url = URL(string: "https://apps.apple.com/\(app.country)/app/id\(app.id)")!
        return entries.compactMap { entry -> FetchedItem? in
            guard let stars = entry.rating.flatMap({ Int($0.label) }), stars <= 2,
                  let date = ISODates.parse(entry.updated.label), date >= since else { return nil }
            let text = TextCleaner.clean(entry.content?.label, max: 300)
            return FetchedItem(key: "rev-\(entry.id.label)", source: .appReviews,
                               title: "\(app.name): \(TextCleaner.clean(entry.title.label, max: 100))",
                               detail: "★\(stars) review (#\(app.rank) top-grossing \(app.genre), \(app.country.uppercased())): \(text)",
                               url: url, score: 3 - stars, postedAt: date)
        }
        .prefix(reviewsPerApp)
        .map { $0 }
    }
}

// MARK: - Atlassian Marketplace (add-ons enterprise teams are adopting)

struct AtlassianFetcher: ItemFetcher {
    let kind = SourceKind.atlassian

    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
        var results: [FetchedItem] = []
        var firstError: Error?
        for (filter, limit) in [("trending", 12), ("new", 15)] {
            let url = URL(string: "https://marketplace.atlassian.com/rest/2/addons?filter=\(filter)&limit=\(limit)&hosting=cloud")!
            do { results += try Self.parse(try await HTTP.get(url), label: filter, postedAt: since) }
            catch { firstError = firstError ?? error }
        }
        if results.isEmpty, let firstError { throw firstError }
        return results
    }

    private struct Response: Decodable {
        struct Embedded: Decodable { let addons: [Addon] }
        struct Addon: Decodable {
            struct Links: Decodable { struct Href: Decodable { let href: String }; let alternate: Href? }
            struct Inner: Decodable {
                struct Category: Decodable { let name: String }
                struct Distribution: Decodable { let totalInstalls: Int? }
                let categories: [Category]?
                let distribution: Distribution?
            }
            let id: String
            let name: String
            let tagLine: String?
            let summary: String?
            let _links: Links?
            let _embedded: Inner?
        }
        let _embedded: Embedded
    }

    static func parse(_ data: Data, label: String, postedAt: Date) throws -> [FetchedItem] {
        try JSONDecoder().decode(Response.self, from: data)._embedded.addons.map { addon in
            let installs = addon._embedded?.distribution?.totalInstalls ?? 0
            let categories = (addon._embedded?.categories ?? []).prefix(2).map(\.name).joined(separator: ", ")
            var detail = TextCleaner.clean(addon.tagLine ?? addon.summary, max: 160)
            detail += " (\(label) Jira/Confluence app, \(installs) installs" + (categories.isEmpty ? ")" : "; \(categories))")
            let path = addon._links?.alternate?.href ?? "/apps/\(addon.id)"
            return FetchedItem(key: "atl-\(addon.id)", source: .atlassian, title: addon.name, detail: detail,
                               url: URL(string: "https://marketplace.atlassian.com" + path) ?? URL(string: "https://marketplace.atlassian.com")!,
                               score: installs, postedAt: postedAt)
        }
    }
}

// MARK: - AusTender (Australian government IT contracts: who is paying for what)

struct AusTenderFetcher: ItemFetcher {
    let kind = SourceKind.ausTender
    static let maxPages = 5
    static let maxItems = 15
    /// UNSPSC codes: 43 = IT equipment and software, 8111 = computer services.
    static let itPrefixes = ["43", "8111"]

    func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] {
        let f = ISO8601DateFormatter()
        var next: URL? = URL(string: "https://api.tenders.gov.au/ocds/findByDates/contractPublished/\(f.string(from: since))/\(f.string(from: .now))")
        var results: [FetchedItem] = []
        var pages = 0
        while let url = next, pages < Self.maxPages {
            let page = try Self.parse(try await HTTP.get(url))
            results += page.items
            next = page.next
            pages += 1
        }
        return Array(results.sorted { $0.score > $1.score }.prefix(Self.maxItems))
    }

    private struct Response: Decodable {
        struct Links: Decodable { let next: String? }
        struct Release: Decodable {
            struct Party: Decodable { let name: String?; let roles: [String]? }
            struct Contract: Decodable {
                struct Item: Decodable { struct Class: Decodable { let id: String? }; let classification: Class? }
                struct Value: Decodable { let amount: String? }
                let id: String
                let description: String?
                let dateSigned: String?
                let items: [Item]?
                let value: Value?
            }
            let parties: [Party]?
            let contracts: [Contract]?
        }
        let releases: [Release]?
        let links: Links?
    }

    /// IT contracts only. Score is the value in thousands of dollars.
    static func parse(_ data: Data) throws -> (items: [FetchedItem], next: URL?) {
        let response = try JSONDecoder().decode(Response.self, from: data)
        var items: [FetchedItem] = []
        for release in response.releases ?? [] {
            let agency = release.parties?.first { $0.roles?.contains("procuringEntity") == true }?.name ?? "A government agency"
            let supplier = release.parties?.first { $0.roles?.contains("supplier") == true }?.name
            for contract in release.contracts ?? [] {
                let codes = (contract.items ?? []).compactMap { $0.classification?.id }
                guard codes.contains(where: { code in itPrefixes.contains { code.hasPrefix($0) } }),
                      let description = contract.description, !description.isEmpty else { continue }
                let amount = Double(contract.value?.amount ?? "") ?? 0
                var detail = "\(agency) paid AUD \(Int(amount).formatted())"
                if let supplier { detail += " to \(supplier)" }
                let url = URL(string: "https://www.tenders.gov.au/Search/CnAdvancedSearch?keyword=\(contract.id)")!
                items.append(FetchedItem(key: "aus-\(contract.id)", source: .ausTender, title: TextCleaner.clean(description, max: 160),
                                         detail: detail, url: url, score: Int(amount / 1000),
                                         postedAt: contract.dateSigned.flatMap(ISODates.parse) ?? .now))
            }
        }
        return (items, response.links?.next.flatMap(URL.init(string:)))
    }
}
