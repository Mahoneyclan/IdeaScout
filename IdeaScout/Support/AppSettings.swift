import Foundation
import UserNotifications

/// Non-secret preferences, stored in UserDefaults. The Settings screen edits the same keys via @AppStorage.
enum AppSettings {
    enum Keys {
        static let topics = "topics"
        static let aiProvider = "aiProvider"
        static let notifyHour = "notifyHour"
        static let weightNovelty = "weight.novelty"
        static let weightMomentum = "weight.momentum"
        static let weightViability = "weight.viability"
        static let weightGap = "weight.gap"
        static let aboutMe = "aboutMe"
        static let qualityBar = "qualityBar"
        static let dailyCap = "dailyCap"
        static let focusIndustry = "focusIndustry"
        static let trendWindowDays = "trendWindowDays"
        static let painWindowDays = "painWindowDays"
        static let claudeMaxItems = "claudeMaxItems"
        static let fieldNotes = "fieldNotes"
        static func model(_ provider: AIProvider) -> String { "model.\(provider.rawValue)" }
        static func customPrice(_ provider: AIProvider, _ side: String) -> String { "price.\(provider.rawValue).\(side)" }
        static func sourceEnabled(_ kind: SourceKind) -> String { "source.\(kind.rawValue)" }
    }

    static let defaultTopics = "ai agent, llm, mcp, vibe coding, local-first"

    static var topics: [String] {
        let raw = UserDefaults.standard.string(forKey: Keys.topics) ?? defaultTopics
        return raw.split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func isEnabled(_ kind: SourceKind) -> Bool {
        UserDefaults.standard.object(forKey: Keys.sourceEnabled(kind)) as? Bool ?? kind.enabledByDefault
    }

    static var provider: AIProvider {
        AIProvider(rawValue: UserDefaults.standard.string(forKey: Keys.aiProvider) ?? "") ?? .claude
    }

    static var aboutMe: String {
        UserDefaults.standard.string(forKey: Keys.aboutMe)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Minimum score (out of 5) for trends and killer ideas to be shown or kept.
    static var qualityBar: Double {
        UserDefaults.standard.object(forKey: Keys.qualityBar) as? Double ?? defaultQualityBar
    }
    static let defaultQualityBar = 3.5

    /// Most Claude spending allowed per day, in US dollars (0 = no limit). Checked before each refresh's
    /// Claude calls, so one refresh can go slightly over.
    static var dailyCap: Double {
        UserDefaults.standard.object(forKey: Keys.dailyCap) as? Double ?? defaultDailyCap
    }
    static let defaultDailyCap = 1.00

    static var isOverDailyCap: Bool { overCap(spent: UsageTracker.summary().today.cost, cap: dailyCap) }

    static func overCap(spent: Double, cap: Double) -> Bool { cap > 0 && spent >= cap }

    /// The industry where at least two killer ideas a day should be aimed (the owner's domain).
    static var focusIndustry: String {
        let value = UserDefaults.standard.string(forKey: Keys.focusIndustry)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value ?? defaultFocusIndustry
    }
    static let defaultFocusIndustry = "energy, utilities and enterprise IT"

    /// Work problems the owner has seen, one per line. Each becomes a demand item.
    static var fieldNotes: String { UserDefaults.standard.string(forKey: Keys.fieldNotes) ?? "" }

    /// How far back sources are searched for trends, and (separately) for pain points, which are rarer.
    static var trendWindowDays: Int { UserDefaults.standard.object(forKey: Keys.trendWindowDays) as? Int ?? defaultTrendWindowDays }
    static let defaultTrendWindowDays = 7
    static var painWindowDays: Int { UserDefaults.standard.object(forKey: Keys.painWindowDays) as? Int ?? defaultPainWindowDays }
    static let defaultPainWindowDays = 14
    static let windowChoices = [7, 14, 28]

    /// How many items Claude reads per refresh. More items cost more and take longer.
    static var claudeMaxItems: Int { UserDefaults.standard.object(forKey: Keys.claudeMaxItems) as? Int ?? defaultClaudeMaxItems }
    static let defaultClaudeMaxItems = 300
    static let maxItemChoices = [100, 150, 300, 500]

    /// Rough cost of one full Claude refresh (trends, ideas, devil's advocate) for a given number of items, in US dollars.
    static func estimatedRefreshCost(items: Int) -> ClosedRange<Double> {
        let base = 0.10 + Double(items) * 0.0006
        return base...(base * 1.5)
    }

    static var notifyHour: Int {
        UserDefaults.standard.object(forKey: Keys.notifyHour) as? Int ?? 7
    }

    /// True while unit tests run, so the app doesn't fetch live data in the background of a test.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// The chosen AI if it can run, otherwise Apple's on-device model, otherwise keyword grouping.
    /// Never falls back to a different paid provider, so spending only happens where the user chose.
    static func makeSummarizer() -> any Summarizer {
        if let client = makeClient(for: provider) { return LLMSummarizer(client: client) }
        if AppleSummarizer.isAvailable { return AppleSummarizer() }
        return KeywordSummarizer(topics: topics)
    }

    /// A client for a cloud provider, or nil if it's Apple or has no API key.
    static func makeClient(for provider: AIProvider) -> (any LLMClient)? {
        guard let keyName = provider.keychainKey, let key = Keychain.get(keyName) else { return nil }
        let model = model(for: provider)
        let price = price(for: provider, model: model)
        if provider == .claude { return ClaudeClient(apiKey: key, model: model, price: price) }
        return OpenAICompatibleClient(provider: provider, apiKey: key, model: model, price: price)
    }

    /// The model chosen for a provider (the recommended one unless the user picked another).
    static func model(for provider: AIProvider) -> String {
        let value = UserDefaults.standard.string(forKey: Keys.model(provider))?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? provider.recommendedModel : value
    }

    /// Known models use their list price; any other model uses the price typed in Settings
    /// (defaulting to the recommended model's price).
    static func price(for provider: AIProvider, model: String) -> ModelPrice {
        if let known = provider.models.first(where: { $0.id == model }) { return known.price }
        let fallback = provider.models.first?.price ?? ModelPrice(input: 0, output: 0)
        let input = UserDefaults.standard.object(forKey: Keys.customPrice(provider, "input")) as? Double ?? fallback.input
        let output = UserDefaults.standard.object(forKey: Keys.customPrice(provider, "output")) as? Double ?? fallback.output
        return ModelPrice(input: input, output: output)
    }
}

enum Notifier {
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func digestReady(themes: Int, items: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "Today's ideas are ready"
        content.body = "\(themes) themes from \(items) new projects."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "digest-\(Date.now.timeIntervalSince1970)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
