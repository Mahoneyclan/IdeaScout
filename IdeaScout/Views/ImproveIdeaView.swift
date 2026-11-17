// ImproveIdeaView.swift
// The "Improve this idea" screen: start a run (cost shown first), watch the rounds, compare each version with the
// original, keep one (a confirmation says so, and the version in use is marked), or undo a kept improvement.
// "Improve again" asks first, because it's another paid run, and adds rounds after the last ones. On iPad at full or wide width the rounds are compared
// side by side with the original (ImproveCompareView.swift).

import SwiftUI
import SwiftData

/// Improves one idea in rounds and shows every version.
struct ImproveIdeaView: View {
    @Bindable var idea: KillerIdea
    @Environment(DigestService.self) private var service
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage(AppSettings.Keys.dailyCap) private var dailyCap = AppSettings.defaultDailyCap
    /// Estimated cost of a full run; `nil` when no paid cloud AI is set up. Read when the screen appears.
    @State private var cost: Double?
    /// The last error: a plain message and any technical detail.
    @State private var failure: (message: String, details: String?)?
    @State private var confirmAgain = false
    /// Shows rounds older than the latest few.
    @State private var showEarlier = false
    /// Rounds shown before "Show earlier rounds".
    private static let roundsShown = 3
    /// What the last keep or undo did, shown at the top until the next action.
    @State private var notice: String?

    private var isRunning: Bool { service.improvingIdea == idea.key }
    private var costText: String { cost.map { " · up to " + AppSettings.approximateCostText($0) } ?? "" }

    private var intro: String {
        "Each round, the AI rewrites \(idea.title) to answer the devil's advocate's strongest objection, then the devil's "
            + "advocate scores the rewrite. It stops after \(IdeaImprover.maxRounds) rounds, or sooner when the score stops "
            + "rising or reaches your minimum score. Nothing changes until you keep a version."
    }
    private static let needsAIText = "Improving an idea needs a cloud AI with its API key. See Settings → Advanced → AI & costs."
    private static let costNote = "Pain and willingness to pay can't go up, because a rewrite adds no new evidence. "
        + "The cost is an upper guide and counts towards your daily AI spending limit."

    var body: some View {
        Form {
            if let notice {
                Section {
                    Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            Section {
                Text(intro)
                startButton
                if idea.originalVersion != nil && !isRunning {
                    Button("Undo improvement", systemImage: "arrow.uturn.backward") {
                        service.undoImprovement(of: idea)
                        announce("Original put back. The idea uses the version the daily refresh proposed.")
                    }
                        .frame(minHeight: 44)
                        .accessibilityHint("Puts back the idea as the daily refresh proposed it")
                }
            } footer: {
                Text(cost == nil ? Self.needsAIText : Self.costNote)
            }
            if let failure {
                Section {
                    Label(failure.message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    if let details = failure.details { ErrorDetailsDisclosure(details: details) }
                }
            }
            if let run = idea.improvement {
                if comparesSideBySide(run) {
                    ImproveCompareSection(idea: idea, run: run, canKeep: !isRunning,
                                          footer: run.stop.map { $0.text + madeText(run) },
                                          keep: { keep($0, round: $1) })
                } else {
                    versionSections(run)
                }
            }
        }
        .readableList(idea.improvement.map(comparesSideBySide) == true ? Layout.compareWidth : Layout.readableWidth)
        .confirmationDialog("Improve it again?", isPresented: $confirmAgain, titleVisibility: .visible) {
            Button("Improve again" + costText) { start() }
        } message: {
            Text(repeatMessage)
        }
        .onAppear { cost = AppSettings.improveCost() }
        .navigationTitle("Improve this idea")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The start button, or progress while a run is going.
    @ViewBuilder private var startButton: some View {
        if isRunning {
            HStack(spacing: 12) {
                ProgressView()
                Text(service.improveStep.isEmpty ? "Starting…" : service.improveStep)
            }
            .frame(minHeight: 44)
        } else {
            Button {
                // Money: a repeat paid run asks first.
                if idea.improvement != nil && cost != nil { confirmAgain = true } else { start() }
            } label: {
                Label((idea.improvement == nil ? "Improve this idea" : "Improve again") + costText, systemImage: "arrow.up.circle")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(service.improvingIdea != nil)
        }
    }

    /// Side by side on a wide screen (iPad at full or wide width) once there's a round to compare.
    private func comparesSideBySide(_ run: IdeaImprover.Run) -> Bool { sizeClass == .regular && run.versions.count >= 2 }

    /// One section per version: the original, then each round. Once "Improve again" has added rounds, only the
    /// latest few show until "Show earlier rounds" is tapped, to keep the list short on iPhone.
    @ViewBuilder private func versionSections(_ run: IdeaImprover.Run) -> some View {
        let hidden = showEarlier ? 0 : max(0, run.versions.count - 1 - Self.roundsShown)
        let shown = [0] + Array(run.versions.indices.dropFirst(1 + hidden))
        if hidden > 0 {
            Section {
                Button("Show \(hidden) earlier round\(hidden == 1 ? "" : "s")", systemImage: "chevron.down") { showEarlier = true }
                    .frame(minHeight: 44)
            }
        }
        ForEach(shown, id: \.self) { index in
            let version = run.versions[index]
            Section {
                let inUse = version.isInUse(by: idea, isOriginal: index == 0)
                HStack {
                    Text(index == 0 ? "Original" : "Round \(index)").font(.headline)
                    if inUse {
                        Label("In use", systemImage: "checkmark.seal.fill")
                            .font(.caption.bold()).foregroundStyle(.green)
                            .accessibilityLabel("This version is in use")
                    }
                    Spacer()
                    KillerScoreBadge(score: version.score)
                }
                if !version.survives {
                    Label("Rejected by the devil's advocate", systemImage: "xmark.octagon").foregroundStyle(.red)
                } else if !version.passes {
                    Label(version.offer == nil ? "Has a weak spot" : "Not vibe-codable", systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                }
                if index > 0 && version.passes && !isRunning && !inUse {
                    Button("Keep this version", systemImage: "checkmark.circle") { keep(version, round: index) }
                        .frame(minHeight: 44)
                }
                if !version.changes.isEmpty { labelled("What changed", version.changes) }
                labelled("Pitch", version.pitch)
                labelled("Who pays", version.buyer)
                labelled("Pricing", version.pricing)
                if !version.channel.isEmpty { labelled("Where to find buyers", version.channel) }
                labelled("Test it in one week", version.oneWeekTest)
                labelled("Strongest objection", version.objection)
            } footer: {
                if index == run.versions.count - 1, let stop = run.stop {
                    Text(stop.text + madeText(run))
                }
            }
        }
    }

    private func labelled(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            Text(text)
        }
    }

    private func madeText(_ run: IdeaImprover.Run) -> String {
        let model = run.model.isEmpty ? "" : " with \(run.model)"
        let made = " Made on \(run.madeAt.formatted(date: .abbreviated, time: .omitted))\(model)."
        guard let scan = run.scanScore else { return made }
        return made + " The original was re-scored by the same devil's advocate as the rounds, so they compare fairly "
            + "(before, it scored \(scan.formatted(.number.precision(.fractionLength(1)))))."
    }

    /// The repeat run's cost and today's spending against the daily limit.
    private var repeatMessage: String {
        let spent = UsageTracker.summary().today.cost.formatted(.currency(code: "USD"))
        let limit = dailyCap > 0 ? " of \(dailyCap.formatted(.currency(code: "USD")))" : ""
        let price = cost.map { " (up to \(AppSettings.approximateCostText($0)))" } ?? ""
        return "This adds up to \(IdeaImprover.maxRounds) more rounds after these, with more paid AI requests\(price). Spent today: \(spent)\(limit)."
    }

    /// Keeps a version and says so, with the score change.
    private func keep(_ version: IdeaVersion, round: Int) {
        let before = idea.killerScore
        service.keep(version, for: idea)
        let score = { (s: Double) in s.formatted(.number.precision(.fractionLength(1))) }
        announce("Kept round \(round): score \(score(before)) → \(score(idea.killerScore)). The idea now uses this version.")
    }

    /// Shows a notice at the top and reads it out with VoiceOver.
    private func announce(_ text: String) {
        notice = text
        AccessibilityNotification.Announcement(text).post()
    }

    /// Starts a run; errors show on screen. Runs in its own task, so leaving the screen doesn't waste paid calls.
    private func start() {
        failure = nil
        notice = nil
        Task {
            do {
                try await service.improve(idea)
            } catch {
                guard !DigestService.isCancellation(error) else { return }
                let described = DigestWarning.describe(error)
                failure = (described.message, described.details)
            }
        }
    }
}
