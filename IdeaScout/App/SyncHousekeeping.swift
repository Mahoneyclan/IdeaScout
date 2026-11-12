// SyncHousekeeping.swift
// Tidies the database after iCloud sync. iCloud can't enforce "one per key", so two devices can each save the same
// idea, starred project or day's scan (for example the first time they sync, or when both scanned before the other's
// results arrived). Duplicates are merged here: at launch, when the app comes back, and when changes arrive.

import Foundation
import SwiftData
import CoreData

enum SyncHousekeeping {
    /// Merges duplicate ideas, starred projects and scans, and saves.
    /// - Returns: How many duplicates were removed.
    @MainActor @discardableResult
    static func mergeDuplicates(in context: ModelContext) -> Int {
        let removed = mergeIdeas(in: context) + mergeStarred(in: context) + mergeScans(in: context)
        if removed > 0 { context.saveOrReport("merging synced copies") }
        return removed
    }

    /// Runs the merge whenever changes arrive from another device.
    @MainActor static func watchForRemoteChanges(_ container: ModelContainer) {
        guard CloudSync.isEnabled, !CloudSync.databaseSyncFailed else { return }
        NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { _ = mergeDuplicates(in: container.mainContext) }
        }
    }

    /// The same idea from two devices: keeps the copy updated most recently and folds in the other's history, its
    /// Saved state and its starter kit.
    static func mergeIdeas(in context: ModelContext) -> Int {
        let all = (try? context.fetch(FetchDescriptor<KillerIdea>())) ?? []
        var removed = 0
        for copies in Dictionary(grouping: all, by: \.key).values where copies.count > 1 {
            let ordered = copies.sorted { $0.lastSeen > $1.lastSeen }
            let keep = ordered[0]
            for other in ordered.dropFirst() {
                keep.firstSeen = min(keep.firstSeen, other.firstSeen)
                keep.daysSeen = Array(Set(keep.daysSeen + other.daysSeen)).sorted()
                keep.timesSeen = max(keep.timesSeen, other.timesSeen, keep.daysSeen.count)
                if other.scoreHistory.count > keep.scoreHistory.count { keep.scoreHistory = other.scoreHistory }
                if other.isSaved && !keep.isSaved { keep.isSaved = true; keep.savedAt = other.savedAt }
                if keep.starterKitJSON.isEmpty && !other.starterKitJSON.isEmpty {
                    keep.starterKitJSON = other.starterKitJSON
                    keep.starterKitMadeAt = other.starterKitMadeAt
                    keep.starterKitModel = other.starterKitModel
                }
                context.delete(other)
                removed += 1
            }
        }
        return removed
    }

    /// The same starred project from two devices: keeps the first starred, with any notes and suggestions.
    static func mergeStarred(in context: ModelContext) -> Int {
        let all = (try? context.fetch(FetchDescriptor<Idea>())) ?? []
        var removed = 0
        for copies in Dictionary(grouping: all, by: \.key).values where copies.count > 1 {
            let ordered = copies.sorted { $0.starredAt < $1.starredAt }
            let keep = ordered[0]
            for other in ordered.dropFirst() {
                if keep.note.isEmpty { keep.note = other.note }
                if keep.extensions.isEmpty { keep.extensions = other.extensions }
                context.delete(other)
                removed += 1
            }
        }
        return removed
    }

    /// Two scans for the same day: keeps the better one (the usual rule: a cloud AI's beats a weaker one), and the
    /// later of two equally good. Deleting a scan deletes its trends and posts.
    static func mergeScans(in context: ModelContext) -> Int {
        let all = (try? context.fetch(FetchDescriptor<Digest>())) ?? []
        var removed = 0
        for copies in Dictionary(grouping: all, by: \.day).values where copies.count > 1 {
            let ordered = copies.sorted {
                let a = DigestService.quality($0.summarizer), b = DigestService.quality($1.summarizer)
                return a != b ? a > b : $0.createdAt > $1.createdAt
            }
            for other in ordered.dropFirst() {
                context.delete(other)
                removed += 1
            }
        }
        return removed
    }
}
