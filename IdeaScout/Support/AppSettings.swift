// AppSettings.swift
// Typed access to the user's preferences (UserDefaults) and the rules that pick which AI runs.
// Screens edit the same keys with @AppStorage, so changes apply immediately everywhere. Secrets are
// never stored here: API keys live in the Keychain (Keychain.swift). Also holds Notifier, the local
// "ideas are ready" notification.

import Foundation
import UserNotifications

/// Non-secret preferences, stored in UserDefaults. The Settings screen edits the same keys via @AppStorage.
enum AppSettings {
    /// UserDefaults key names. Changing a value here loses that setting for existing users.
    enum Keys {
        /// Comma-separated topics that steer GitHub search.
        static let topics = "topics"
        /// The chosen AIProvider (raw value).
        static let aiProvider = "aiProvider"
        /// Hour (5–11) around which the daily background refresh is requested.
        static let notifyHour = "notifyHour"
        /// Trend ranking weights (0–2) for novelty, momentum, viability and opportunity gap.
        static let weightNovelty = "weight.novelty"
        static let weightMomentum = "weight.momentum"
        static let weightViability = "weight.viability"
        static let weightGap = "weight.gap"
        /// Free text about the user, sent to the cloud AI to score "fit".
        static let aboutMe = "aboutMe"
        /// Score (0–4.5) separating Killer ideas from Near-misses, and hiding weaker trends.
        static let qualityBar = "qualityBar"
        /// Daily AI spending limit in US dollars (0 = no limit).
        static let dailyCap = "dailyCap"
        /// Industry that at least 2 ideas a day must target.
        static let focusIndustry = "focusIndustry"
        /// How many days back sources are searched (7, 14 or 28).
        static let trendWindowDays = "trendWindowDays"
        /// Separate, longer window for complaint sources, which are rarer.
        static let painWindowDays = "painWindowDays"
        /// Items the cloud AI reads per refresh. Named before other providers existed; applies to all of them.
        static let claudeMaxItems = "claudeMaxItems"
        /// "My Business Challenges": the user's own problems, one per line.
        static let fieldNotes = "fieldNotes"
        /// Set once the welcome screens are finished.
        static let onboarded = "onboarded"
        /// Whether the user agreed to share data with this provider.
        static func consent(_ provider: AIProvider) -> String { "consent.\(provider.rawValue)" }
        /// The model chosen for this provider (empty = recommended).
        static func model(_ provider: AIProvider) -> String { "model.\(provider.rawValue)" }
        /// Price per million tokens typed in for an "Other…" model; `side` is "input" or "output".
        static func customPrice(_ provider: AIProvider, _ side: String) -> String { "price.\(provider.rawValue).\(side)" }
        /// Whether a source is switched on. Unset means the source's own default (`enabledByDefault`).
        static func sourceEnabled(_ kind: SourceKind) -> String { "source.\(kind.rawValue)" }
    }

    /// The settings store: the app's normal one, or the separate store used by UI tests.
    static var defaults: UserDefaults { TestMode.isUITesting ? TestMode.defaults : .standard }

    /// Starting topics for a new install (users usually replace them with business topics).
    static let defaultTopics = "ai agent, llm, mcp, vibe coding, local-first"

    /// The topics as a list, split on commas or new lines, blanks removed.
    static var topics: [String] {
        let raw = defaults.string(forKey: Keys.topics) ?? defaultTopics
        return raw.split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Whether a source should be fetched: the user's toggle if set, otherwise the source's default.
    static func isEnabled(_ kind: SourceKind) -> Bool {
        defaults.object(forKey: Keys.sourceEnabled(kind)) as? Bool ?? kind.enabledByDefault
    }

    /// The chosen AI provider. Unknown values (e.g. a removed provider) fall back to Claude.
    static var provider: AIProvider {
        AIProvider(rawValue: defaults.string(forKey: Keys.aiProvider) ?? "") ?? .claude
    }

    /// "About me", trimmed.
    static var aboutMe: String {
        defaults.string(forKey: Keys.aboutMe)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Score (out of 5) at or above which an idea counts as "Killer" (below it, "Near-miss"); trends
    /// scoring below it are hidden unless the user chooses to show them. Ideas are kept either way.
    static var qualityBar: Double {
        defaults.object(forKey: Keys.qualityBar) as? Double ?? defaultQualityBar
    }
    /// Default quality bar.
    static let defaultQualityBar = 3.5

    /// Most AI spending allowed per day, in US dollars (0 = no limit), for whichever provider is chosen.
    /// Checked before the trend step and again before the idea step, so one refresh can go slightly over.
    static var dailyCap: Double {
        defaults.object(forKey: Keys.dailyCap) as? Double ?? defaultDailyCap
    }
    /// About two refreshes a day with Claude Sonnet at 300 items.
    static let defaultDailyCap = 1.00

    /// Whether today's recorded spending has reached the limit.
    static var isOverDailyCap: Bool { overCap(spent: UsageTracker.summary().today.cost, cap: dailyCap) }

    /// - Returns: `true` if a limit is set (`cap` > 0) and `spent` has reached it.
    static func overCap(spent: Double, cap: Double) -> Bool { cap > 0 && spent >= cap }

    /// The industry where at least two killer ideas a day should be aimed (the owner's domain).
    static var focusIndustry: String {
        let value = defaults.string(forKey: Keys.focusIndustry)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value ?? defaultFocusIndustry
    }
    /// The owner's own domain, where their experience is an edge.
    static let defaultFocusIndustry = "energy, utilities and enterprise IT"

    /// Work problems the owner has seen, one per line. Each becomes a demand item.
    static var fieldNotes: String { defaults.string(forKey: Keys.fieldNotes) ?? "" }

    /// How far back sources are searched for trends, and (separately) for pain points, which are rarer.
    static var trendWindowDays: Int { defaults.object(forKey: Keys.trendWindowDays) as? Int ?? defaultTrendWindowDays }
    /// A week: long enough for several projects to share a theme, short enough to stay fresh.
    static let defaultTrendWindowDays = 7
    /// Window for Pain points and App Store complaints.
    static var painWindowDays: Int { defaults.object(forKey: Keys.painWindowDays) as? Int ?? defaultPainWindowDays }
    /// Two weeks, because business complaints are rare.
    static let defaultPainWindowDays = 14
    /// Window lengths offered in Settings.
    static let windowChoices = [7, 14, 28]

    /// How many items the cloud AI reads per refresh (every provider). More items cost more and take longer.
    static var claudeMaxItems: Int { defaults.object(forKey: Keys.claudeMaxItems) as? Int ?? defaultClaudeMaxItems }
    /// Chosen by the owner on 22 Oct 2026, with business sources added.
    static let defaultClaudeMaxItems = 300
    /// Item limits offered in Settings.
    static let maxItemChoices = [100, 150, 300, 500]

    /// Rough cost range of one full refresh (trends, ideas, devil's advocate), in US dollars, shown in Settings and on
    /// the refresh button. Fitted to measured Claude costs (about $0.29 at 150 items, $0.44 at 300 with Opus);
    /// cheaper models cost less, so treat it as an upper guide.
    static func estimatedRefreshCost(items: Int) -> ClosedRange<Double> {
        let base = 0.10 + Double(items) * 0.0006
        return base...(base * 1.5)
    }

    /// Hour for the daily refresh request (default 7 am).
    static var notifyHour: Int {
        defaults.object(forKey: Keys.notifyHour) as? Int ?? 7
    }

    /// True while unit tests run, so the app doesn't fetch live data in the background of a test.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Whether the user agreed to send their data to this cloud provider (Apple's rules require consent
    /// before personal data goes to a third-party AI). Asked again for each provider.
    static func hasConsent(_ provider: AIProvider) -> Bool {
        !provider.isCloud || defaults.bool(forKey: Keys.consent(provider))
    }

    /// Records the user's answer on the consent screen (or a withdrawal in Settings).
    static func setConsent(_ provider: AIProvider, _ value: Bool) {
        defaults.set(value, forKey: Keys.consent(provider))
    }

    /// True when a cloud provider is chosen and has a key, but the user hasn't agreed to share data with it.
    static var needsConsent: Bool {
        provider.isCloud && !hasConsent(provider) && provider.keychainKey.flatMap { Keychain.get($0) } != nil
    }

    /// The chosen AI if it can run and the user agreed to share data with it, otherwise Apple's
    /// on-device model, otherwise keyword grouping. Never falls back to a different paid provider,
    /// so spending only happens where the user chose.
    static func makeSummarizer() -> any Summarizer {
        if hasConsent(provider), let client = makeClient(for: provider) { return LLMSummarizer(client: client) }
        if AppleSummarizer.isAvailable { return AppleSummarizer() }
        return KeywordSummarizer(topics: topics)
    }

    /// A client for a cloud provider, with its chosen model and price.
    /// - Returns: `nil` if the provider is Apple or has no API key saved.
    static func makeClient(for provider: AIProvider) -> (any LLMClient)? {
        guard let keyName = provider.keychainKey, let key = Keychain.get(keyName) else { return nil }
        let model = model(for: provider)
        let price = price(for: provider, model: model)
        if provider == .claude { return ClaudeClient(apiKey: key, model: model, price: price) }
        return OpenAICompatibleClient(provider: provider, apiKey: key, model: model, price: price)
    }

    /// The model chosen for a provider (the recommended one unless the user picked another).
    static func model(for provider: AIProvider) -> String {
        let value = defaults.string(forKey: Keys.model(provider))?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? provider.recommendedModel : value
    }

    /// Known models use their list price; any other model uses the price typed in Settings
    /// (defaulting to the recommended model's price).
    static func price(for provider: AIProvider, model: String) -> ModelPrice {
        if let known = provider.models.first(where: { $0.id == model }) { return known.price }
        let fallback = provider.models.first?.price ?? ModelPrice(input: 0, output: 0)
        let input = defaults.object(forKey: Keys.customPrice(provider, "input")) as? Double ?? fallback.input
        let output = defaults.object(forKey: Keys.customPrice(provider, "output")) as? Double ?? fallback.output
        return ModelPrice(input: input, output: output)
    }
}

/// The local notification sent when a background refresh has built the day's digest.
enum Notifier {
    /// Asks the user for permission to show notifications.
    /// - Returns: Whether permission was granted.
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Posts "Today's ideas are ready" immediately. Contains counts only, no idea text.
    static func digestReady(themes: Int, items: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "Today's ideas are ready"
        content.body = "\(themes) themes from \(items) new projects."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "digest-\(Date.now.timeIntervalSince1970)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
