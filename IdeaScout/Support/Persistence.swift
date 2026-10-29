// Persistence.swift
// Saving the SwiftData database without failing silently. Every save goes through `saveOrReport`, which
// logs a failure (without personal data) and returns a plain message the caller can show.

import Foundation
import SwiftData
import os

extension Logger {
    /// Log for database problems. Messages contain the action name only; error details are marked private.
    static let persistence = Logger(subsystem: "com.mahoney.IdeaScout", category: "persistence")
}

extension ModelContext {
    /// Saves pending changes.
    /// - Parameter action: What was being saved, in plain words (e.g. "today's ideas"), used in the message.
    /// - Returns: `nil` on success, or a plain message for the user if the save failed.
    @discardableResult
    func saveOrReport(_ action: String) -> String? {
        do {
            try save()
            return nil
        } catch {
            // Privacy: the action name is public; the error text could include data, so it's private.
            Logger.persistence.error("Save failed (\(action, privacy: .public)): \(error.localizedDescription, privacy: .private)")
            return Self.failureMessage(for: action)
        }
    }

    /// The message shown when saving fails.
    /// - Parameter action: What was being saved, in plain words.
    /// - Returns: A plain message with what to try next.
    static func failureMessage(for action: String) -> String {
        "IdeaScout couldn't save \(action). Please try again; if it keeps happening, restart the app or free up storage."
    }
}
