import Foundation
import UserNotifications

/// Non-secret preferences, stored in UserDefaults. The Settings screen edits the same keys via @AppStorage.
enum AppSettings {
    enum Keys {
        static let topics = "topics"
        static let aiProvider = "aiProvider"
        static let notifyHour = "notifyHour"
        static func sourceEnabled(_ kind: SourceKind) -> String { "source.\(kind.rawValue)" }
    }

    static let defaultTopics = "ai agent, llm, mcp, vibe coding, local-first"

    static var topics: [String] {
        let raw = UserDefaults.standard.string(forKey: Keys.topics) ?? defaultTopics
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func isEnabled(_ kind: SourceKind) -> Bool {
        UserDefaults.standard.object(forKey: Keys.sourceEnabled(kind)) as? Bool ?? true
    }

    static var provider: AIProvider {
        AIProvider(rawValue: UserDefaults.standard.string(forKey: Keys.aiProvider) ?? "") ?? .apple
    }

    static var notifyHour: Int {
        UserDefaults.standard.object(forKey: Keys.notifyHour) as? Int ?? 7
    }

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
