// SecureClipboard.swift
// Copies prompt text (which can include the user's About me and notes) to the clipboard safely.
// Used by "Copy plan prompt" (KillerViews) and "Copy prompt" (IdeasView).

import UIKit
import UniformTypeIdentifiers

/// Security: the copied prompts contain the user's own profile and notes. A normal copy stays on the
/// clipboard indefinitely and syncs to the user's other Apple devices (Universal Clipboard), where any
/// app can read it later. These copies stay on this iPhone and clear themselves after a few minutes,
/// which is plenty of time to paste into Claude, ChatGPT or similar.
enum SecureClipboard {
    /// How long a copy stays on the clipboard.
    static let lifetime: TimeInterval = 10 * 60

    /// Copies plain text to this device only, expiring after `lifetime`.
    /// - Parameter text: The text to copy.
    static func copy(_ text: String) {
        UIPasteboard.general.setItems([[UTType.plainText.identifier: text]], options: options())
    }

    /// The pasteboard options used for every copy (separated out so tests can check them).
    /// - Parameter now: The time the copy is made.
    static func options(now: Date = .now) -> [UIPasteboard.OptionsKey: Any] {
        [.localOnly: true, .expirationDate: now.addingTimeInterval(lifetime)]
    }
}
