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

    /// Picks the chosen AI if it can run, otherwise the other one, otherwise keyword grouping.
    static func makeSummarizer() -> any Summarizer {
        let claudeKey = Keychain.get(.claudeAPIKey)
        let claude = claudeKey.map { ClaudeSummarizer(apiKey: $0) }
        let apple = AppleSummarizer.isAvailable ? AppleSummarizer() : nil
        let ordered: [(any Summarizer)?] = provider == .claude ? [claude, apple] : [apple, claude]
        return ordered.compactMap { $0 }.first ?? KeywordSummarizer(topics: topics)
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
