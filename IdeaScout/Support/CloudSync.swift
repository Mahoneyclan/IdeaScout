// CloudSync.swift
// Sharing between the user's own devices through their iCloud account (owner's decision, 12 Nov 2026). The database
// (scans, ideas, starred projects) syncs through SwiftData's iCloud support (see IdeaScoutApp). This file syncs the
// small things through iCloud key-value storage: a few settings, each device's AI spending (so the daily limit covers
// all devices together), and a "today's scan has started" note so two devices don't both pay for the morning scan.
// API keys never sync: they stay in this device's Keychain.

import Foundation

/// A key-value store, so the sync rules can be tested without iCloud.
protocol KeyValueStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    var dictionaryRepresentation: [String: Any] { get }
}

extension NSUbiquitousKeyValueStore: KeyValueStore {}

enum CloudSync {
    /// The app's iCloud container (matches IdeaScout.entitlements).
    static let containerID = "iCloud.com.mahoney.IdeaScout"
    /// Off in tests, which must never touch the owner's iCloud.
    static var isEnabled: Bool { !AppSettings.isRunningTests && !TestMode.isUITesting }
    /// iCloud key-value storage, or `nil` when sync is off.
    static var store: KeyValueStore? { isEnabled ? NSUbiquitousKeyValueStore.default : nil }
    /// Set at launch when the database couldn't be opened with iCloud and is working on this device only.
    nonisolated(unsafe) static var databaseSyncFailed = false

    /// The settings shared between devices (all text). Everything else, consents included, stays per device.
    static let syncedSettings = [AppSettings.Keys.aboutMe, AppSettings.Keys.interestArea, AppSettings.Keys.fieldNotes,
                                 AppSettings.Keys.starterKitTool, AppSettings.Keys.appType]

    /// A random ID for this device (not synced), to tell its spending and scans from the other devices'.
    static var deviceID: String {
        let key = "sync.deviceID"
        if let id = AppSettings.defaults.string(forKey: key) { return id }
        let id = UUID().uuidString
        AppSettings.defaults.set(id, forKey: key)
        return id
    }

    // MARK: - Starting

    /// Brings in the shared settings, then keeps both sides up to date. Call once at launch.
    @MainActor static func start() {
        guard isEnabled else { return }
        NSUbiquitousKeyValueStore.default.synchronize()
        pullSettings(from: NSUbiquitousKeyValueStore.default, into: AppSettings.defaults)
        publish(ledger: UsageTracker.load())
        NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                               object: nil, queue: .main) { _ in
            pullSettings(from: NSUbiquitousKeyValueStore.default, into: AppSettings.defaults)
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            pushSettings(from: AppSettings.defaults, to: NSUbiquitousKeyValueStore.default)
        }
    }

    // MARK: - Settings

    /// Takes each shared setting from iCloud when it has one; sends up a setting only this device has.
    static func pullSettings(from store: KeyValueStore, into defaults: UserDefaults) {
        for key in syncedSettings {
            if let remote = store.object(forKey: key) as? String {
                if defaults.string(forKey: key) != remote { defaults.set(remote, forKey: key) }
            } else if let local = defaults.string(forKey: key) {
                store.set(local, forKey: key)
            }
        }
    }

    /// Sends changed settings up; a setting cleared here is cleared in iCloud too.
    static func pushSettings(from defaults: UserDefaults, to store: KeyValueStore) {
        for key in syncedSettings {
            let local = defaults.string(forKey: key)
            guard store.object(forKey: key) as? String != local else { continue }
            if let local { store.set(local, forKey: key) } else { store.removeObject(forKey: key) }
        }
    }

    // MARK: - Spending

    /// Each device's ledger is stored under its own key, so devices never overwrite each other's spending.
    static let ledgerPrefix = "usage.ledger."
    /// Only recent days are shared (today's total is what the limit needs; the month total is shown).
    static let sharedLedgerDays = 62

    /// Shares this device's recent spending.
    static func publish(ledger: UsageTracker.Ledger, to store: KeyValueStore? = store, now: Date = .now) {
        guard let store else { return }
        let oldest = UsageTracker.dayKey(now.addingTimeInterval(-Double(sharedLedgerDays) * 86_400))
        let recent = ledger.filter { $0.key >= oldest }
        if let data = try? JSONEncoder().encode(recent) { store.set(data, forKey: ledgerPrefix + deviceID) }
    }

    /// The other devices' spending.
    static func otherLedgers(in store: KeyValueStore?, excluding id: String = deviceID) -> [UsageTracker.Ledger] {
        guard let store else { return [] }
        return store.dictionaryRepresentation
            .filter { $0.key.hasPrefix(ledgerPrefix) && $0.key != ledgerPrefix + id }
            .compactMap { ($0.value as? Data).flatMap { try? JSONDecoder().decode(UsageTracker.Ledger.self, from: $0) } }
    }

    /// This device's ledger plus the others', added day by day and feature by feature.
    static func combined(_ own: UsageTracker.Ledger, others: [UsageTracker.Ledger]) -> UsageTracker.Ledger {
        var total = own
        for ledger in others {
            for (day, features) in ledger {
                for (feature, usage) in features {
                    total[day, default: [:]][feature] = (total[day]?[feature]).map { $0 + usage } ?? usage
                }
            }
        }
        return total
    }

    // MARK: - Today's scan

    /// Who started today's scan, and when.
    struct ScanNote: Codable, Equatable {
        var day: String
        var deviceID: String
        var startedAt: Date
    }

    static let scanKey = "scan.started"
    /// A scan started on another device this long ago or less is treated as still running.
    static let scanRunningFor: TimeInterval = 30 * 60

    /// Notes that this device has started today's scan.
    static func noteScanStarted(in store: KeyValueStore? = store, now: Date = .now) {
        guard let store else { return }
        let note = ScanNote(day: UsageTracker.dayKey(now), deviceID: deviceID, startedAt: now)
        if let data = try? JSONEncoder().encode(note) { store.set(data, forKey: scanKey) }
    }

    /// The last scan note, if any.
    static func scanNote(in store: KeyValueStore? = store) -> ScanNote? {
        (store?.object(forKey: scanKey) as? Data).flatMap { try? JSONDecoder().decode(ScanNote.self, from: $0) }
    }

    /// Whether another device started today's scan in the last half hour, so an automatic scan here should wait for
    /// its results to arrive instead of paying for a second one.
    static func otherDeviceIsScanning(_ note: ScanNote?, deviceID: String = deviceID, now: Date = .now) -> Bool {
        guard let note, note.deviceID != deviceID, note.day == UsageTracker.dayKey(now) else { return false }
        return now.timeIntervalSince(note.startedAt) <= scanRunningFor
    }

    // MARK: - Delete all my data

    /// Removes everything IdeaScout keeps in iCloud key-value storage (all devices' entries).
    static func eraseAll(in store: KeyValueStore?) {
        guard let store else { return }
        for key in store.dictionaryRepresentation.keys { store.removeObject(forKey: key) }
    }
}
