// ReimagineStore.swift
// Recent "Reimagine an app" research runs, saved as one JSON file on this device so the user can come back and try
// another direction without paying for the research again. Kept on the device only (not in the synced database:
// a new record type would need an iCloud schema change), at most `maxRuns`, newest first. Removed by
// "Delete all my data". UI tests use a separate temporary file.

import Foundation
import os

enum ReimagineStore {
    /// Most runs kept; older ones are dropped.
    static let maxRuns = 10
    private static let log = Logger(subsystem: "com.mahoney.IdeaScout", category: "Reimagine")

    /// Where the runs are saved. Tests may point it elsewhere.
    nonisolated(unsafe) static var fileURL: URL = {
        let folder = TestMode.isUITesting ? FileManager.default.temporaryDirectory
            : (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
        return folder.appendingPathComponent(TestMode.isUITesting ? "reimagine-runs-uitest.json" : "reimagine-runs.json")
    }()

    /// The saved runs, newest first; empty if there are none or the file can't be read.
    static func load() -> [Reimagine.Run] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([Reimagine.Run].self, from: data)
        } catch {
            log.error("Couldn't read saved Reimagine runs: \(error.localizedDescription, privacy: .private)")
            return []
        }
    }

    /// Saves a run, replacing an earlier copy of it, newest first, keeping at most `maxRuns`.
    /// - Returns: The runs now saved.
    @discardableResult static func save(_ run: Reimagine.Run) -> [Reimagine.Run] {
        let runs = Array(([run] + load().filter { $0.id != run.id }).prefix(maxRuns))
        write(runs)
        return runs
    }

    /// Removes one run.
    static func remove(_ id: UUID) { write(load().filter { $0.id != id }) }

    /// Removes every run ("Delete all my data").
    static func deleteAll() { try? FileManager.default.removeItem(at: fileURL) }

    private static func write(_ runs: [Reimagine.Run]) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(runs).write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            log.error("Couldn't save Reimagine runs: \(error.localizedDescription, privacy: .private)")
        }
    }
}
