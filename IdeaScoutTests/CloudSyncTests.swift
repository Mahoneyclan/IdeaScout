// CloudSyncTests.swift
// iCloud sync between the user's devices (owner, 12 Nov 2026): shared settings, spending added across devices,
// the "other device is scanning" rule, merging copies of the same idea, starred project or day's scan, and
// "Delete all my data" reaching iCloud. Uses a stand-in for iCloud storage and in-memory databases.

import Foundation
import Testing
import SwiftData
@testable import IdeaScout

/// iCloud key-value storage stand-in.
private final class FakeStore: KeyValueStore {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
    var dictionaryRepresentation: [String: Any] { values }
}

private func freshDefaults() -> UserDefaults {
    let name = "CloudSyncTests.\(UUID().uuidString)"
    return UserDefaults(suiteName: name) ?? .standard
}

struct CloudSyncTests {
    @Test func settingsFromICloudWinAndLocalOnesAreSentUp() {
        let store = FakeStore(), defaults = freshDefaults()
        store.values[AppSettings.Keys.aboutMe] = "iOS dev"
        defaults.set("fitness", forKey: AppSettings.Keys.interestArea)
        defaults.set("old", forKey: AppSettings.Keys.aboutMe)
        CloudSync.pullSettings(from: store, into: defaults)
        #expect(defaults.string(forKey: AppSettings.Keys.aboutMe) == "iOS dev", "iCloud wins")
        #expect(store.values[AppSettings.Keys.interestArea] as? String == "fitness", "only here, so sent up")

        defaults.set("web", forKey: AppSettings.Keys.appType)
        defaults.removeObject(forKey: AppSettings.Keys.aboutMe)
        CloudSync.pushSettings(from: defaults, to: store)
        #expect(store.values[AppSettings.Keys.appType] as? String == "web")
        #expect(store.values[AppSettings.Keys.aboutMe] == nil, "cleared here, cleared in iCloud")
    }

    @Test func spendingIsAddedAcrossDevicesSoTheLimitCoversThemAll() throws {
        let store = FakeStore()
        let other: UsageTracker.Ledger = ["2026-11-12": ["Trends": .init(calls: 1, dollars: 0.30)]]
        store.values[CloudSync.ledgerPrefix + "ipad"] = try JSONEncoder().encode(other)
        store.values[CloudSync.ledgerPrefix + "iphone"] = try JSONEncoder().encode(["2026-11-12": ["Trends": UsageTracker.Usage(dollars: 9)]])
        let own: UsageTracker.Ledger = ["2026-11-12": ["Trends": .init(calls: 1, dollars: 0.20)]]
        let total = CloudSync.combined(own, others: CloudSync.otherLedgers(in: store, excluding: "iphone"))
        #expect(abs((total["2026-11-12"]?["Trends"]?.cost ?? 0) - 0.50) < 0.0001, "this device's own entry isn't counted twice")
    }

    @Test func onlyRecentSpendingIsShared() throws {
        let store = FakeStore()
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        let old = UsageTracker.dayKey(now.addingTimeInterval(-90 * 86_400)), today = UsageTracker.dayKey(now)
        CloudSync.publish(ledger: [old: ["T": .init(dollars: 1)], today: ["T": .init(dollars: 2)]], to: store, now: now)
        let shared = try #require(store.values[CloudSync.ledgerPrefix + CloudSync.deviceID] as? Data)
        #expect(try JSONDecoder().decode(UsageTracker.Ledger.self, from: shared).keys.sorted() == [today])
    }

    @Test(arguments: [("ipad", 0.0, true), ("ipad", 29 * 60.0, true), ("ipad", 31 * 60.0, false),
                      ("iphone", 60.0, false), ("ipad", -86_400.0 * 1.5, false)])
    func anAutomaticScanWaitsForTheOtherDevice(device: String, startedAgo: Double, waits: Bool) {
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        let started = now.addingTimeInterval(-startedAgo)
        let note = CloudSync.ScanNote(day: UsageTracker.dayKey(started), deviceID: device, startedAt: started)
        #expect(CloudSync.otherDeviceIsScanning(note, deviceID: "iphone", now: now) == waits)
        #expect(!CloudSync.otherDeviceIsScanning(nil, deviceID: "iphone", now: now))
    }
}

@MainActor
struct SyncHousekeepingTests {
    private func context() throws -> ModelContext {
        let container = try ModelContainer(for: Digest.self, Theme.self, Item.self, Idea.self, KillerIdea.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        return ModelContext(container)
    }

    @Test func copiesOfTheSameIdeaAreMergedKeepingTheNewest() throws {
        let context = try context()
        let day1 = Date(timeIntervalSince1970: 1_793_000_000), day2 = day1.addingTimeInterval(86_400)
        let older = KillerIdea(key: "k", title: "Old text")
        older.firstSeen = day1; older.lastSeen = day1; older.daysSeen = [day1]; older.isSaved = true; older.savedAt = day1
        older.starterKitJSON = "{}"
        let newer = KillerIdea(key: "k", title: "New text")
        newer.firstSeen = day2; newer.lastSeen = day2; newer.daysSeen = [day2]
        let unrelated = KillerIdea(key: "other", title: "Other")
        [older, newer, unrelated].forEach(context.insert)
        #expect(SyncHousekeeping.mergeDuplicates(in: context) == 1)
        let left = try context.fetch(FetchDescriptor<KillerIdea>(predicate: #Predicate { $0.key == "k" }))
        let kept = try #require(left.first)
        #expect(left.count == 1 && kept.title == "New text")
        #expect(kept.firstSeen == day1 && kept.daysSeen == [day1, day2] && kept.timesSeen == 2)
        #expect(kept.isSaved && kept.savedAt == day1 && kept.starterKitJSON == "{}")
    }

    @Test func twoScansForOneDayKeepTheBetter() throws {
        let context = try context()
        let day = Calendar.current.startOfDay(for: .now)
        let keywords = Digest(day: day, summarizer: "Keywords")
        let cloud = Digest(day: day, summarizer: "Claude")
        cloud.createdAt = keywords.createdAt.addingTimeInterval(-60)
        let theme = Theme(title: "T", summary: "", order: 0, opportunities: [])
        keywords.themes = [theme]
        [keywords, cloud].forEach(context.insert)
        #expect(SyncHousekeeping.mergeDuplicates(in: context) == 1)
        #expect(try context.fetch(FetchDescriptor<Digest>()).map(\.summarizer) == ["Claude"])
        #expect(try context.fetch(FetchDescriptor<Theme>()).isEmpty, "the removed scan's trends go with it")
    }

    @Test func starredTwiceKeepsTheFirstWithNotes() throws {
        let context = try context()
        let item = Item(FetchedItem(key: "gh-1", source: .github, title: "Repo", detail: "", url: URL(string: "https://x.dev")!,
                                    score: 1, postedAt: .now))
        let first = Idea(from: item), second = Idea(from: item)
        first.starredAt = .distantPast
        second.note = "my note"
        [first, second].forEach(context.insert)
        #expect(SyncHousekeeping.mergeDuplicates(in: context) == 1)
        let left = try context.fetch(FetchDescriptor<Idea>())
        #expect(left.count == 1 && left.first?.starredAt == .distantPast && left.first?.note == "my note")
    }

    @Test func deleteAllEmptiesICloudToo() throws {
        let context = try context()
        context.insert(KillerIdea(key: "k", title: "T"))
        let store = FakeStore()
        store.values[AppSettings.Keys.aboutMe] = "me"
        store.values[CloudSync.ledgerPrefix + "ipad"] = Data()
        let suite = "CloudSyncTests.delete.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        #expect(DigestService.eraseAll(context: context, defaults: defaults, defaultsDomain: suite,
                                       keychainService: "CloudSyncTests.\(UUID().uuidString)", cloudStore: store))
        let ideasLeft = try context.fetch(FetchDescriptor<KillerIdea>())
        #expect(store.values.isEmpty && ideasLeft.isEmpty)
    }
}
