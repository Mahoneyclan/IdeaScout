// ImproveIdeaView.swift
// The "Improve this idea" screen: start a run (cost shown first), watch the rounds, compare each version with the
// original, keep one, or undo a kept improvement. Starting again asks first, because it's another paid run.

import SwiftUI
import SwiftData

/// Improves one idea in rounds and shows every version.
struct ImproveIdeaView: View {
    @Bindable var idea: KillerIdea
    @Environment(DigestService.self) private var service
    @AppStorage(AppSettings.Keys.dailyCap) private var dailyCap = AppSettings.defaultDailyCap
    /// Estimated cost of a full run; `nil` when no paid cloud AI is set up. Read when the screen appears.
    @State private var cost: Double?
    /// The last error: a plain message and any technical detail.
    @State private var failure: (message: String, details: String?)?
    @State private var confirmAgain = false

    private var isRunning: Bool { service.improvingIdea == idea.key }
    private var costText: String { cost.map { " · up to " + AppSettings.approximateCostText($0) } ?? "" }

    private var intro: String {
        "Each round, the AI rewrites \(idea.title) to answer the devil's advocate's strongest objection, then the devil's "
            + "advocate scores the rewrite. It stops after \(IdeaImprover.maxRounds) rounds, or sooner when the score stops "
            + "rising or reaches your quality bar. Nothing changes until you keep a version."
    }
    private static let needsAIText = "Improving an idea needs a cloud AI with its API key. See Settings → Advanced → AI & costs."
    private static let costNote = "Pain and willingness to pay can't go up, because a rewrite adds no new evidence. "
        + "The cost is an upper guide and counts towards your daily AI spending limit."

    var body: some View {
        Form {
            Section {
                Text(intro)
                startButton
                if idea.originalVersion != nil && !isRunning {
                    Button("Undo improvement", systemImage: "arrow.uturn.backward") { service.undoImprovement(of: idea) }
                        .frame(minHeight: 44)
                        .accessibilityHint("Puts back the idea as the daily scan proposed it")
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
                versionSections(run)
            }
        }
        .readableList()
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

    /// One section per version: the original, then each round.
    @ViewBuilder private func versionSections(_ run: IdeaImprover.Run) -> some View {
        ForEach(Array(run.versions.enumerated()), id: \.offset) { index, version in
            Section {
                HStack {
                    Text(index == 0 ? "Original" : "Round \(index)").font(.headline)
                    Spacer()
                    KillerScoreBadge(score: version.score)
                }
                if !version.survives {
                    Label("Rejected by the devil's advocate", systemImage: "xmark.octagon").foregroundStyle(.red)
                } else if !version.passes {
                    Label(version.offer == nil ? "Has a weak spot" : "Not vibe-codable", systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                }
                if index > 0 && version.passes && !isRunning {
                    Button("Keep this version", systemImage: "checkmark.circle") { service.keep(version, for: idea) }
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
        return " Made on \(run.madeAt.formatted(date: .abbreviated, time: .omitted))\(model)."
    }

    /// The repeat run's cost and today's spending against the daily limit.
    private var repeatMessage: String {
        let spent = UsageTracker.summary().today.cost.formatted(.currency(code: "USD"))
        let limit = dailyCap > 0 ? " of \(dailyCap.formatted(.currency(code: "USD")))" : ""
        let price = cost.map { " (up to \(AppSettings.approximateCostText($0)))" } ?? ""
        return "This makes more paid AI requests\(price) and replaces these versions. Spent today: \(spent)\(limit)."
    }

    /// Starts a run; errors show on screen. Runs in its own task, so leaving the screen doesn't waste paid calls.
    private func start() {
        failure = nil
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
