// LiveRefreshView.swift
// The Ideas tab while a refresh runs: each step's results appear as soon as that step finishes (owner, 16 Nov
// 2026): the items read per source, the day's pain clusters and trends, then the draft ideas with the devil's
// advocate's verdict on each. Saved ideas still appear in the leaderboard when the refresh is done.

import SwiftUI

/// The sections shown under the progress row during a refresh, filled in step by step.
struct LiveRefreshSections: View {
    let live: LiveRefresh

    var body: some View {
        if !live.sources.isEmpty {
            Section {
                DisclosureGroup {
                    ForEach(live.sources, id: \.label) { source in
                        LabeledContent(source.label, value: "\(source.count)")
                    }
                } label: {
                    Label("Read \(live.itemCount) item\(live.itemCount == 1 ? "" : "s") from \(live.sources.count) "
                          + "source\(live.sources.count == 1 ? "" : "s")", systemImage: "tray.full")
                }
            } header: {
                Text("Step 1 · Sources")
            }
        }
        if !live.painClusters.isEmpty || !live.trends.isEmpty {
            Section {
                ForEach(live.painClusters, id: \.self) { Label($0, systemImage: "exclamationmark.bubble") }
                ForEach(live.trends, id: \.self) { Label($0, systemImage: "chart.line.uptrend.xyaxis") }
            } header: {
                Text("Step 2 · Common complaints and trends")
            } footer: {
                Text("Saved now, so they're kept even if a later step fails.")
            }
        }
        if !live.drafts.isEmpty {
            Section {
                ForEach(live.drafts, id: \.title) { DraftIdeaRow(draft: $0) }
            } header: {
                Text("Steps 3–4 · Draft ideas")
            } footer: {
                Text("The ideas kept appear in the list below when the refresh is done, with checked prices.")
            }
        }
    }
}

/// A draft idea and where it stands, with an icon and words for each status (never colour alone).
struct DraftIdeaRow: View {
    let draft: LiveRefresh.Draft

    private var status: (text: String, icon: String, colour: Color) {
        switch draft.status {
        case .unjudged: ("Draft: not judged yet", "hourglass", .secondary)
        case .backed: ("Backed by the devil's advocate", "checkmark.circle.fill", .green)
        case .rejected(let objection):
            ("Rejected by the devil's advocate" + (objection.isEmpty ? "" : ": \(objection)"), "xmark.circle", .orange)
        case .dropped: ("Dropped: too big for one person, or not in today's top ideas", "minus.circle", .secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(draft.title).font(.headline)
            Text(draft.pitch).font(.subheadline)
            if !draft.buyer.isEmpty { Text(draft.buyer).font(.caption).foregroundStyle(.secondary) }
            Label(status.text, systemImage: status.icon).font(.caption.bold()).foregroundStyle(status.colour)
        }
        .padding(.vertical, 4)
        .opacity(draft.status == .dropped ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}
