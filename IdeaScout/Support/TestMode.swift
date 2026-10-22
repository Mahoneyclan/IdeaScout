// TestMode.swift
// A sealed mode for automated screen (UI) tests, available only in Debug builds. Started by launch
// arguments from IdeaScoutUITests. It keeps tests away from the owner's real data and from the network:
// an in-memory database, a separate settings store and Keychain area, fixed trial state, fake sources
// and a scripted AI. Release builds compile `isUITesting` to `false`, so none of this can be reached.

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
        /// Start with the free trial already over.
        static let trialExpired = "-ui-trial-expired"
    }

    /// Whether the app was launched with `argument`.
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
        if has(Argument.skipWelcome) {
            defaults.set(true, forKey: AppSettings.Keys.onboarded)
            defaults.set(AIProvider.claude.rawValue, forKey: AppSettings.Keys.aiProvider)
            AppSettings.setConsent(.claude, true)
            Keychain.set("ui-test-key-0000", for: .claudeAPIKey)
        }
    }

    /// Refresh dependencies for test mode: two fake sources, the scripted AI below, and a fixed trial state.
    @MainActor static var dependencies: DigestService.Dependencies {
        DigestService.Dependencies(
            makeFetchers: {
                [FixedFetcher(kind: .painPoints, items: [sample("p1", .painPoints, "I wish there was an invoice chaser")]),
                 FixedFetcher(kind: .github, items: [sample("g1", .github, "invoice bot"), sample("g2", .github, "billing agent")])]
            },
            makeSummarizer: {
                AppSettings.hasConsent(.claude) && Keychain.get(.claudeAPIKey) != nil
                    ? LLMSummarizer(client: ScriptedClient()) as any Summarizer
                    : KeywordSummarizer(topics: ["invoice"])
            },
            freeSummarizer: { KeywordSummarizer(topics: ["invoice"]) },
            access: { StoreManager.shared.access },
            isOverDailyCap: { false },
            needsConsent: { AppSettings.needsConsent },
            notify: { _, _ in })
    }

    private static func sample(_ key: String, _ source: SourceKind, _ title: String) -> FetchedItem {
        FetchedItem(key: key, source: source, title: title, detail: "", url: URL(string: "https://example.com/\(key)")!,
                    score: 10, postedAt: .now)
    }

    /// A source that returns fixed items.
    private struct FixedFetcher: ItemFetcher {
        let kind: SourceKind
        let items: [FetchedItem]
        /// Returns the fixed items.
        func fetch(since: Date, topics: [String]) async throws -> [FetchedItem] { items }
    }

    /// An AI that answers every request from a script, offline.
    private struct ScriptedClient: LLMClient {
        let provider = AIProvider.claude
        let model = "ui-test"

        /// Returns the scripted reply for the feature, in Claude's format.
        func complete(system: String, prompt: String, schema: [String: Any], effort: String, feature: String) async throws -> Data {
            let json = switch feature {
            case "Trends": #"{"themes":[{"title":"Invoice automation","summary":"Tools that chase unpaid invoices.","opportunities":["Chaser for trades"],"item_numbers":[2,3],"novelty":4,"novelty_reason":"r","viability":4,"viability_reason":"r","opportunity_gap":4,"opportunity_gap_reason":"r"}],"translations":[],"pain_clusters":[{"title":"Chasing invoices","buyer":"Bookkeeper","workaround":"Email","pay_signals":"none seen","summary":"s","item_numbers":[1]}],"noise_numbers":[]}"#
            case "Killer ideas": #"{"ideas":[{"title":"InvoiceChaser","pitch":"Chases unpaid invoices automatically.","buyer":"Small trades businesses","pricing":"$49/month","why_now":"w","one_week_test":"t","replaces":"Manual follow-up emails","evidence_numbers":[1],"same_as":""}]}"#
            default: #"{"reviews":[{"title":"InvoiceChaser","survives":true,"objection":"o","competitors":"none found","verdict":"v","pain":4,"willing_to_pay":4,"timing":4,"gap":4,"fit":4,"evidence_needed":"e"}]}"#
            }
            return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": json]], "stop_reason": "end_turn"])
        }
    }
}
