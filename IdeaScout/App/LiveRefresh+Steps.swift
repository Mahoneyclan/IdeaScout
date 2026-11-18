// LiveRefresh+Steps.swift
// The "Today's refresh" checklist (owner, 18 Nov 2026, after a Fable review): five steps listed from the start, each
// waiting, running, done, skipped or failed, with a one-line result in plain words. DigestService moves each step on;
// the screens only read it. The wording is built here so it can be tested.

import Foundation

extension LiveRefresh {
    /// Where one step stands, with the line shown under its name.
    enum StepState: Equatable, Sendable {
        case waiting
        case running
        case done(String)
        case skipped(String)
        case failed(String)

        /// The line under the step's name.
        func line(running: String) -> String {
            switch self {
            case .waiting: "Waiting"
            case .running: running
            case .done(let text): text
            case .skipped(let reason): "Skipped: " + reason
            case .failed(let reason): "Didn't work: " + reason
            }
        }

        /// One word for VoiceOver and for people who can't tell the icons apart.
        var word: String {
            switch self {
            case .waiting: "waiting"
            case .running: "working"
            case .done: "done"
            case .skipped: "skipped"
            case .failed: "didn't work"
            }
        }
    }

    /// The five steps, in order (matching `DigestService.Stage` raw values 1–5).
    static let stepNames = ["Read the sources", "Find complaints and trends", "Come up with ideas",
                            "Devil's advocate checks them", "Check competitor prices"]
    /// What each step says while it runs.
    static let runningLines = ["Reading your sources…", "Grouping what people say…", "Writing ideas…",
                               "Testing each idea…", "Searching the web for prices…"]

    /// The state of step `number` (1–5).
    func state(_ number: Int) -> StepState { steps.indices.contains(number - 1) ? steps[number - 1] : .waiting }

    /// The step that's running, if any (1–5).
    var runningStep: Int? { steps.firstIndex(of: .running).map { $0 + 1 } }

    mutating func set(_ number: Int, _ state: StepState) {
        guard steps.indices.contains(number - 1) else { return }
        steps[number - 1] = state
    }

    /// Skips every step from `number` on that hasn't finished, with the same reason.
    mutating func skip(from number: Int, _ reason: String) {
        for step in number...Self.stepNames.count where [.waiting, .running].contains(state(step)) { set(step, .skipped(reason)) }
    }

    /// Ends the refresh: a step still running was stopped part-way (iOS ended it, or it was cancelled).
    mutating func finish(at date: Date = .now) {
        if let step = runningStep {
            set(step, .failed("stopped before it finished"))
            skip(from: step + 1, "the refresh stopped early")
        }
        finishedAt = date
    }

    // MARK: - Result lines

    /// "42 items from 5 sources".
    static func sourcesLine(_ sources: [SourceCount]) -> String {
        let items = sources.reduce(0) { $0 + $1.count }
        return "\(items) item\(items == 1 ? "" : "s") from \(sources.count) source\(sources.count == 1 ? "" : "s")"
    }

    /// "2 complaints, 3 trends", noting when the AI didn't answer and keywords were used.
    static func trendsLine(complaints: Int, trends: Int, byKeyword: Bool) -> String {
        let counts = "\(complaints) complaint\(complaints == 1 ? "" : "s"), \(trends) trend\(trends == 1 ? "" : "s")"
        return byKeyword ? counts + ", grouped by keyword (the AI didn't answer)" : counts
    }

    /// "5 ideas: NudgeBill, ShiftSwap, PlantPal Pro…".
    static func ideasLine(_ drafts: [Draft]) -> String {
        guard !drafts.isEmpty else { return "No ideas came back" }
        let names = drafts.prefix(3).map(\.title).joined(separator: ", ") + (drafts.count > 3 ? "…" : "")
        return "\(drafts.count) idea\(drafts.count == 1 ? "" : "s"): " + names
    }

    /// "3 kept, 1 rejected, 1 dropped" (only the parts that apply).
    static func verdictLine(_ drafts: [Draft]) -> String {
        let kept = drafts.filter { $0.status == .backed }.count
        let rejected = drafts.filter { if case .rejected = $0.status { true } else { false } }.count
        let dropped = drafts.filter { $0.status == .dropped }.count
        var parts = ["\(kept) kept"]
        if rejected > 0 { parts.append("\(rejected) rejected") }
        if dropped > 0 { parts.append("\(dropped) dropped") }
        return parts.joined(separator: ", ")
    }

    /// The folded summary after a refresh: "Finished at 9:12 PM in 3 min · 3 ideas kept", or where it stopped.
    func summary(calendar: Calendar = .current) -> String {
        guard let finishedAt else { return "Refreshing…" }
        if let stopped = steps.firstIndex(where: { if case .failed = $0 { true } else { false } }) {
            return "Stopped at step \(stopped + 1): " + state(stopped + 1).line(running: "")
                .replacingOccurrences(of: "Didn't work: ", with: "")
        }
        let minutes = startedAt.map { max(1, Int((finishedAt.timeIntervalSince($0) / 60).rounded())) } ?? 1
        let kept = drafts.filter { $0.status == .backed }.count
        return "Finished at \(finishedAt.formatted(date: .omitted, time: .shortened)) in \(minutes) min"
            + (drafts.isEmpty ? "" : " · \(kept) idea\(kept == 1 ? "" : "s") kept")
    }

    /// What VoiceOver says when step `number` finishes: "Step 2 done: 2 complaints, 3 trends. Now: Come up with ideas".
    func announcement(for number: Int) -> String {
        let name = Self.stepNames[number - 1]
        var text = "Step \(number), \(name), \(state(number).word): " + state(number).line(running: "")
        if let next = runningStep { text += ". Now: " + Self.stepNames[next - 1] }
        return text
    }
}
