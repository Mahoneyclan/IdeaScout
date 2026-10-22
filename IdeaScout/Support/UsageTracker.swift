import Foundation

/// Records what each Claude call cost, using the token counts Claude returns with every reply.
/// Stored in UserDefaults as a small ledger of daily totals (Apple's on-device AI is free and not tracked).
enum UsageTracker {
    /// Claude Opus 5.5 list prices, in US dollars per million tokens, used for entries recorded
    /// before prices were stored per call. Thinking tokens are billed as output.
    static let inputPrice = 4.0
    static let outputPrice = 20.0
    static let cacheWritePrice = 5.0   // 1.25 × input
    static let cacheReadPrice = 0.20

    struct Usage: Codable, Equatable {
        var input = 0
        var output = 0
        var cacheWrite = 0
        var cacheRead = 0
        var calls = 0
        /// Dollars, worked out with the price of the model that was used. Older entries (Claude only)
        /// don't have it, so their cost comes from the token counts at Claude's prices.
        var dollars: Double?

        var cost: Double {
            dollars ?? (Double(input) * UsageTracker.inputPrice + Double(output) * UsageTracker.outputPrice
                        + Double(cacheWrite) * UsageTracker.cacheWritePrice + Double(cacheRead) * UsageTracker.cacheReadPrice) / 1_000_000
        }

        static func + (a: Usage, b: Usage) -> Usage {
            Usage(input: a.input + b.input, output: a.output + b.output, cacheWrite: a.cacheWrite + b.cacheWrite,
                  cacheRead: a.cacheRead + b.cacheRead, calls: a.calls + b.calls, dollars: a.cost + b.cost)
        }
    }

    /// Ledger: day ("yyyy-MM-dd") → feature → usage.
    typealias Ledger = [String: [String: Usage]]

    private static let storageKey = "usage.ledger"
    private static let lock = NSLock()

    /// Reads the `usage` block of a Claude response.
    static func parseUsage(_ data: Data) -> Usage? {
        struct Response: Decodable {
            struct U: Decodable {
                let input_tokens: Int?
                let output_tokens: Int?
                let cache_creation_input_tokens: Int?
                let cache_read_input_tokens: Int?
            }
            let usage: U?
        }
        guard let u = (try? JSONDecoder().decode(Response.self, from: data))?.usage else { return nil }
        return Usage(input: u.input_tokens ?? 0, output: u.output_tokens ?? 0,
                     cacheWrite: u.cache_creation_input_tokens ?? 0, cacheRead: u.cache_read_input_tokens ?? 0, calls: 1)
    }

    static func record(response data: Data, feature: String, price: ModelPrice? = nil, on date: Date = .now) {
        guard var usage = parseUsage(data) else { return }
        if let price {
            usage.dollars = price.cost(input: usage.input, output: usage.output, cacheWrite: usage.cacheWrite, cacheRead: usage.cacheRead)
        }
        lock.lock(); defer { lock.unlock() }
        var ledger = load()
        let day = dayKey(date)
        ledger[day, default: [:]][feature] = (ledger[day]?[feature] ?? Usage()) + usage
        save(ledger)
    }

    static func load() -> Ledger {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode(Ledger.self, from: data)) ?? [:]
    }

    private static func save(_ ledger: Ledger) {
        if let data = try? JSONEncoder().encode(ledger) { UserDefaults.standard.set(data, forKey: storageKey) }
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: - Summaries for the Settings screen

    struct Summary: Equatable {
        var today = Usage()
        var thisMonth = Usage()
        var allTime = Usage()
        var byFeatureThisMonth: [(feature: String, usage: Usage)] = []
        var lastDays: [(day: String, cost: Double)] = []

        static func == (a: Summary, b: Summary) -> Bool {
            a.today == b.today && a.thisMonth == b.thisMonth && a.allTime == b.allTime
        }
    }

    static func summary(_ ledger: Ledger = load(), now: Date = .now, days: Int = 7) -> Summary {
        let today = dayKey(now)
        let month = String(today.prefix(7))
        var s = Summary()
        var features: [String: Usage] = [:]
        for (day, perFeature) in ledger {
            let total = perFeature.values.reduce(Usage(), +)
            s.allTime = s.allTime + total
            if day == today { s.today = s.today + total }
            if day.hasPrefix(month) {
                s.thisMonth = s.thisMonth + total
                for (feature, usage) in perFeature { features[feature] = (features[feature] ?? Usage()) + usage }
            }
        }
        s.byFeatureThisMonth = features.map { ($0.key, $0.value) }.sorted { $0.usage.cost > $1.usage.cost }
        s.lastDays = (0..<days).compactMap { offset in
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: now) else { return nil }
            let key = dayKey(date)
            return (key, (ledger[key]?.values.reduce(Usage(), +) ?? Usage()).cost)
        }
        return s
    }
}
