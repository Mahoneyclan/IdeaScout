// UsageTracker.swift
// The AI cost tracker behind Settings → Advanced → AI & costs and the daily spending limit.
// Every cloud AI reply is converted to the same shape (see LLMClient), so one parser reads token counts
// for every provider; each call is priced at the model actually used.

import Foundation

/// Records what each cloud AI call cost, from the token counts in its reply.
/// Stored in UserDefaults as a small ledger of daily totals (Apple's on-device AI is free and not tracked), and shared
/// with the user's other devices through iCloud (see CloudSync).
enum UsageTracker {
    /// Claude Opus 5.5 list prices, in US dollars per million tokens, used for entries recorded
    /// before prices were stored per call. Thinking tokens are billed as output.
    static let inputPrice = 4.0
    /// Claude Opus 5.5 output price per million tokens (legacy entries only).
    static let outputPrice = 20.0
    /// Claude Opus 5.5 cache-write price per million tokens (legacy entries only).
    static let cacheWritePrice = 5.0   // 1.25 × input
    /// Claude Opus 5.5 cache-read price per million tokens (legacy entries only).
    static let cacheReadPrice = 0.20

    /// Token counts and cost for one day and one feature (e.g. "Trends"). Stored as JSON, so new fields
    /// must be optional to keep reading older ledgers.
    struct Usage: Codable, Equatable {
        /// Uncached input tokens.
        var input = 0
        /// Output tokens, including any reasoning ("thinking") tokens, which are billed as output.
        var output = 0
        /// Input tokens written to the provider's prompt cache.
        var cacheWrite = 0
        /// Input tokens read from the provider's prompt cache (much cheaper).
        var cacheRead = 0
        /// Number of AI calls.
        var calls = 0
        /// Dollars, worked out with the price of the model that was used. Older entries (Claude only)
        /// don't have it, so their cost comes from the token counts at Claude's prices.
        var dollars: Double?

        /// Cost in US dollars: the stored price-based amount, or (for older entries) the tokens at Opus prices.
        var cost: Double {
            dollars ?? (Double(input) * UsageTracker.inputPrice + Double(output) * UsageTracker.outputPrice
                        + Double(cacheWrite) * UsageTracker.cacheWritePrice + Double(cacheRead) * UsageTracker.cacheReadPrice) / 1_000_000
        }

        /// Adds two usages. The result always stores dollars, so mixed old and new entries add up correctly.
        /// - Parameters:
        ///   - a: The first usage.
        ///   - b: The usage to add to it.
        /// - Returns: The combined token counts, calls and cost.
        static func + (a: Usage, b: Usage) -> Usage {
            Usage(input: a.input + b.input, output: a.output + b.output, cacheWrite: a.cacheWrite + b.cacheWrite,
                  cacheRead: a.cacheRead + b.cacheRead, calls: a.calls + b.calls, dollars: a.cost + b.cost)
        }
    }

    /// Ledger: day ("yyyy-MM-dd") → feature → usage.
    typealias Ledger = [String: [String: Usage]]

    /// UserDefaults key for the JSON ledger.
    private static let storageKey = "usage.ledger"
    /// Serialises read-modify-write of the ledger: replies can arrive from several AI calls at once.
    private static let lock = NSLock()

    /// Reads the `usage` block of a reply in Claude's format (other providers' replies are converted to it).
    /// - Returns: The token counts with `calls` = 1, or `nil` if the reply has no usage block.
    static func parseUsage(_ data: Data) -> Usage? {
        /// The `usage` block of a Claude-format reply.
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

    /// Adds one call to today's ledger under `feature`.
    /// - Parameters:
    ///   - data: The reply, in Claude's format.
    ///   - feature: Ledger label, e.g. "Trends", "Killer ideas", "Devil's advocate".
    ///   - price: The model's price; if `nil`, cost is worked out later at legacy Opus prices.
    ///   - date: The day to record against (tests pass a fixed date).
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
        CloudSync.publish(ledger: ledger)
    }

    /// This device's spending plus what the user's other devices shared through iCloud: what the daily limit and
    /// the cost screen use, so the limit covers all devices together.
    static func combinedLedger() -> Ledger {
        CloudSync.combined(load(), others: CloudSync.otherLedgers(in: CloudSync.store))
    }

    /// Reads the whole ledger. Returns an empty ledger if none is saved or it can't be decoded.
    static func load() -> Ledger {
        guard let data = AppSettings.defaults.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode(Ledger.self, from: data)) ?? [:]
    }

    /// Writes the whole ledger. Callers must hold `lock`.
    private static func save(_ ledger: Ledger) {
        if let data = try? JSONEncoder().encode(ledger) { AppSettings.defaults.set(data, forKey: storageKey) }
    }

    /// Deletes all recorded spending (Settings → Reset cost tracker). Today's total, which the daily
    /// spending limit uses, also goes back to zero.
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        AppSettings.defaults.removeObject(forKey: storageKey)
        CloudSync.publish(ledger: [:])
    }

    /// The ledger key for a date, in the phone's time zone with a fixed Gregorian "yyyy-MM-dd" format,
    /// so keys sort and compare correctly whatever the user's calendar or language.
    /// - Parameter date: The moment to file under.
    /// - Returns: The day as "yyyy-MM-dd".
    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: - Summaries for the Settings screen

    /// Totals shown in Settings → AI & costs.
    struct Summary: Equatable {
        /// Spending today; also what the daily spending limit is checked against.
        var today = Usage()
        /// Spending in the current calendar month.
        var thisMonth = Usage()
        /// Spending since the tracker was last reset.
        var allTime = Usage()
        /// This month's spending per feature, most expensive first.
        var byFeatureThisMonth: [(feature: String, usage: Usage)] = []
        /// Cost per day for the last `days` days, newest first (days with no calls show $0).
        var lastDays: [(day: String, cost: Double)] = []

        /// Compares the totals only; tuple arrays can't be compared automatically.
        /// - Parameters:
        ///   - a: The first summary.
        ///   - b: The summary to compare it with.
        /// - Returns: `true` when today's, this month's and all-time totals match.
        static func == (a: Summary, b: Summary) -> Bool {
            a.today == b.today && a.thisMonth == b.thisMonth && a.allTime == b.allTime
        }
    }

    /// Builds the totals from a ledger.
    /// - Parameters:
    ///   - ledger: The ledger to summarise (tests pass their own).
    ///   - now: "Today" for the calculation.
    ///   - days: How many recent days to list.
    /// - Returns: Today, month, all-time and per-feature totals.
    static func summary(_ ledger: Ledger = combinedLedger(), now: Date = .now, days: Int = 7) -> Summary {
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
