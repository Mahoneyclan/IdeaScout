// ErrorDetailsDisclosure.swift
// A collapsed "Details" row that reveals an error's technical text. Copied from TipChecker.

import SwiftUI

/// A collapsed "Details" disclosure under an error message. The text is selectable so it can be copied into a
/// support email.
struct ErrorDetailsDisclosure: View {
    /// Technical detail, e.g. `LLMHTTPError.technicalDetail`.
    let details: String

    var body: some View {
        DisclosureGroup("Details") {
            Text(details)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .font(.footnote)
    }
}
