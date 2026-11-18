// LiveRefreshView.swift
// The "Today's refresh" checklist on the Ideas tab (owner, 18 Nov 2026, after a Fable review): all five steps from
// the start, every row built the same way (an icon and a word for its state, the step's name, a one-line result, and
// tap to open its detail once it has some). After the refresh it folds into one "How it went" row until the next
// refresh. VoiceOver announces each finished step. Nothing opens by itself, so the list doesn't jump.

import SwiftUI

/// The checklist: open while a refresh runs, folded into a summary row afterwards.
struct RefreshChecklist: View {
    let live: LiveRefresh
    let isRefreshing: Bool

    var body: some View {
        if isRefreshing {
            Section {
                steps
            } header: {
                Text("Today's refresh")
            } footer: {
                Text("Usually takes 2–4 minutes. Keep the app open.")
            }
            .onChange(of: live.steps) { old, new in announceFinishedSteps(old: old, new: new) }
        } else if let started = live.startedAt, Calendar.current.isDateInToday(started) {
            Section {
                DisclosureGroup {
                    steps
                } label: {
                    Label("How it went · " + live.summary(), systemImage: "list.bullet.clipboard").frame(minHeight: 44)
                }
            }
        }
    }

    @ViewBuilder private var steps: some View {
        ForEach(1...LiveRefresh.stepNames.count, id: \.self) { number in
            StepRow(number: number, live: live)
        }
    }

    /// One announcement per step that has just finished, skipped or failed (never for every update).
    private func announceFinishedSteps(old: [LiveRefresh.StepState], new: [LiveRefresh.StepState]) {
        for index in new.indices where old.indices.contains(index) && old[index] != new[index] {
            switch new[index] {
            case .done, .skipped, .failed: AccessibilityNotification.Announcement(live.announcement(for: index + 1)).post()
            case .waiting, .running: break
            }
        }
    }
}

/// One step: state icon, name and result line; tap to open when there's detail to show.
private struct StepRow: View {
    let number: Int
    let live: LiveRefresh
    @ScaledMetric private var iconSize = 22.0

    private var state: LiveRefresh.StepState { live.state(number) }
    private var name: String { LiveRefresh.stepNames[number - 1] }

    var body: some View {
        if hasDetail {
            DisclosureGroup { detail } label: { summary }
        } else {
            summary
        }
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            icon.frame(width: iconSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(state == .running ? .semibold : .regular))
                Text(state.line(running: LiveRefresh.runningLines[number - 1]))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number) of 5, \(name), \(state.word). " + state.line(running: ""))
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .waiting: Image(systemName: "circle").foregroundStyle(.secondary)
        case .running: ProgressView()
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var hasDetail: Bool {
        switch number {
        case 1: !live.sources.isEmpty
        case 2: !live.painClusters.isEmpty || !live.trends.isEmpty
        case 3, 4: !live.drafts.isEmpty && state != .waiting
        default: false
        }
    }

    @ViewBuilder private var detail: some View {
        switch number {
        case 1:
            ForEach(Array(live.sources.enumerated()), id: \.offset) { _, source in
                LabeledContent(source.label, value: "\(source.count)")
            }
        case 2:
            ForEach(Array(live.painClusters.enumerated()), id: \.offset) { _, title in Label(title, systemImage: "exclamationmark.bubble") }
            ForEach(Array(live.trends.enumerated()), id: \.offset) { _, title in Label(title, systemImage: "chart.line.uptrend.xyaxis") }
        case 3:
            ForEach(Array(live.drafts.enumerated()), id: \.offset) { _, draft in
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.title).font(.subheadline.bold())
                    Text(draft.pitch).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        default:
            ForEach(Array(live.drafts.enumerated()), id: \.offset) { _, draft in DraftVerdictRow(draft: draft) }
            if live.drafts.contains(where: { $0.status == .backed }) {
                Text("Kept ideas are in the list below.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// A draft's title and the devil's advocate's verdict, with an icon and words (never colour alone).
private struct DraftVerdictRow: View {
    let draft: LiveRefresh.Draft

    var body: some View {
        let (text, icon, colour): (String, String, Color) = switch draft.status {
        case .unjudged: ("Being tested", "hourglass", .secondary)
        case .backed: ("Kept", "checkmark.circle.fill", .green)
        case .rejected(let reason): ("Rejected" + (reason.isEmpty ? "" : ": \(reason)"), "xmark.circle", .orange)
        case .dropped: ("Dropped: too big for one person, or not in today's top ideas", "minus.circle", .secondary)
        }
        VStack(alignment: .leading, spacing: 2) {
            Text(draft.title).font(.subheadline.bold())
            Label(text, systemImage: icon).font(.subheadline).foregroundStyle(colour).lineLimit(3)
        }
        .accessibilityElement(children: .combine)
    }
}
