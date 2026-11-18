// TestMode.swift
// A sealed mode for automated screen (UI) tests, available only in Debug builds. Started by launch
// arguments from IdeaScoutUITests. It keeps tests away from the owner's real data and from the network:
// an in-memory database, a separate settings store and Keychain area, fake sources
// and a scripted AI. Release builds compile `isUITesting` to `false` and leave out the fake sources,
// the scripted AI and the dummy key, so none of this can be reached or found in the App Store build.

import Foundation

/// Switches for the sealed UI-test mode.
enum TestMode {
    #if DEBUG
    /// True when launched by the UI tests with `-ui-testing`.
    static let isUITesting = ProcessInfo.processInfo.arguments.contains("-ui-testing")
    #else
    /// Always false in Release builds.
    static let isUITesting = false
    #endif

    /// Launch arguments understood in test mode.
    enum Argument {
        /// Skip the welcome screens, with a Claude key and consent already set.
        static let skipWelcome = "-ui-skip-welcome"
        /// App Store screenshots: sample tips, and a second refresh that pauses so its progress can be captured.
        static let screenshots = "-ui-screenshots"
    }

    /// Whether the app was launched with `argument`.
    /// - Parameter argument: One of `Argument`'s values.
    /// - Returns: `true` if it's among the launch arguments.
    static func has(_ argument: String) -> Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    /// Separate settings store, emptied at every test launch.
    static let defaultsSuite = "com.mahoney.IdeaScout.uitests"
    /// The test settings store (falls back to standard only if the suite can't be created, which doesn't happen in practice).
    static let defaults = UserDefaults(suiteName: defaultsSuite) ?? .standard
    /// Separate Keychain area, emptied at every test launch.
    static let keychainService = "com.mahoney.IdeaScout.uitests"

    /// Resets the test stores and applies the launch arguments. Called once at launch, in test mode only.
    static func prepare() {
        guard isUITesting else { return }
        defaults.removePersistentDomain(forName: defaultsSuite)
        Keychain.removeAll(service: keychainService)
        #if DEBUG
        // Security: the dummy key and the fakes below exist only in Debug builds, so none of this test-only
        // code or text ships in the App Store build.
        if has(Argument.skipWelcome) {
            defaults.set(true, forKey: AppSettings.Keys.onboarded)
            defaults.set(AIProvider.claude.rawValue, forKey: AppSettings.Keys.aiProvider)
            AppSettings.setConsent(.claude, true)
            Keychain.set("ui-test-key-0000", for: .claudeAPIKey)
        }
        ReimagineStore.deleteAll()
        if has(Argument.screenshots), let run = TestModeScripts.sampleRun() { ReimagineStore.save(run) }
        #endif
    }

    #if DEBUG
    /// Refresh dependencies for test mode: two fake sources, and the scripted AI below.
    @MainActor static var dependencies: DigestService.Dependencies {
        DigestService.Dependencies(
            makeFetchers: {
                [FixedFetcher(kind: .painPoints, items: [sample("p1", .painPoints, "I wish there was a simple way to chase invoices")]),
                 FixedFetcher(kind: .appReviews, items: [sample("r1", .appReviews, "Too expensive for a one-person business")]),
                 FixedFetcher(kind: .github, items: [sample("g1", .github, "invoice bot"), sample("g2", .github, "roster helper")])]
            },
            makeSummarizer: {
                AppSettings.hasConsent(.claude) && Keychain.get(.claudeAPIKey) != nil
                    ? LLMSummarizer(client: ScriptedClient()) as any Summarizer
                    : KeywordSummarizer(topics: ["invoice"])
            },
            freeSummarizer: { KeywordSummarizer(topics: ["invoice"]) },
            isOverDailyCap: { false },
            needsConsent: { AppSettings.needsConsent },
            notify: { _, _ in },
            priceChecker: {
                AppSettings.hasConsent(.claude) && Keychain.get(.claudeAPIKey) != nil ? ScriptedClient() : nil
            },
            httpGet: { _ in Data(#"{"feed":{"entry":[]}}"#.utf8) })
    }

    private static func sample(_ key: String, _ source: SourceKind, _ title: String) -> FetchedItem {
        // Safe to unwrap: `key` is a short fixed test string, so the URL is always valid.
        FetchedItem(key: key, source: source, title: title, detail: "", url: URL(string: "https://example.com/\(key)")!,
                    score: 10, postedAt: .now)
    }

    /// A source that returns fixed items.
    private struct FixedFetcher: ItemFetcher {
        let kind: SourceKind
        let items: [FetchedItem]
        /// Returns the fixed items.
        /// - Parameters:
        ///   - since: Ignored.
        ///   - topics: Ignored.
        /// - Returns: `items`.
        /// - Throws: Never.
        func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] { items }
    }

    /// An AI that answers every request from a script, offline.
    private struct ScriptedClient: LLMClient, WebSearchClient {
        let provider = AIProvider.claude
        let model = "ui-test"
        /// Counts devil's-advocate calls, so only a second refresh pauses for the screenshots.
        static let critiques = Counter()

        /// A thread-safe counter for test mode.
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        }

        /// Returns the made-up pricing pages as the search's sources (no real web search).
        func searchWeb(system: String, prompt: String, maxSearches: Int, blockedDomains: [String],
                       feature: String) async throws -> WebSearchReply {
            // The text echoes the question, so the scripted price check can answer for the right idea.
            WebSearchReply(text: "Scripted research for: " + prompt, sources: Set(TestModeScripts.pricingPages))
        }

        /// Returns the scripted reply for the feature, in Claude's format.
        /// - Parameters:
        ///   - system: Ignored.
        ///   - prompt: Ignored.
        ///   - schema: Ignored.
        ///   - effort: Ignored.
        ///   - feature: Picks the reply from `TestModeScripts` (the improved idea's review scores the same, so an
        ///     improvement run stops after one round).
        /// - Returns: The reply in Claude's message format.
        /// - Throws: Only if the fixed reply can't be serialised, which doesn't happen.
        func complete(system: String, prompt: String, schema: [String: Any], effort: String, feature: String) async throws -> Data {
            // Screenshots: a second refresh pauses at the devil's advocate, so the step-by-step progress can be captured.
            if feature == "Devil's advocate" && has(Argument.screenshots) {
                if ScriptedClient.critiques.increment() > 1 { try await Task.sleep(for: .seconds(25)) }
            }
            let json = TestModeScripts.reply(feature: feature, system: system, prompt: prompt)
            return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": json]], "stop_reason": "end_turn"])
        }
    }
    #else
    /// Release builds never run in test mode, so they always use the real sources and AI.
    @MainActor static var dependencies: DigestService.Dependencies { .live }
    #endif
}
