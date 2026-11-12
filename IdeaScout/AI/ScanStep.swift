// ScanStep.swift
// The steps of a scan that can each use their own Claude model. With "Mixed" chosen (owner, 13 Nov 2026), Claude
// Haiku 5.5 reads and sorts the day's items, Claude Sonnet 5.5 writes ideas (and Improve rewrites, starter kits), and
// Claude Opus 5.5 is the devil's advocate. With any other model chosen, every step uses that model.

enum ScanStep: Sendable, CaseIterable {
    case reading, writing, judging

    /// The model ID saved in Settings for "Mixed". Stored on users' devices, so it's permanent.
    static let mixedModel = "claude-mixed"

    /// The Claude model "Mixed" uses for this step.
    var mixedModelID: String {
        switch self {
        case .reading: "claude-haiku-5-5"
        case .writing: "claude-sonnet-5-5"
        case .judging: "claude-opus-5-5"
        }
    }

    /// The API model for this step.
    /// - Parameter chosen: The Claude model chosen in Settings.
    /// - Returns: Mixed's model for this step, or the chosen model itself.
    func model(chosen: String) -> String { chosen == Self.mixedModel ? mixedModelID : chosen }
}
