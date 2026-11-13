// ImproveCompareView.swift
// The side-by-side comparison for "Improve this idea" on iPad at full or wide width (owner, 13 Nov 2026): the original
// (or the round before it) and one chosen round row by row, changed rows marked in words, unchanged text shown as "(same)", and one Keep button.
// iPhone and narrow iPad windows use the stacked list in ImproveIdeaView instead.

import SwiftUI

/// One row of the comparison: a field of the original beside the same field of a round.
struct ComparisonRow: Equatable, Identifiable {
    var label: String
    var original: String
    var round: String
    /// Whether the round's text differs from the original's (ignoring spacing and case).
    var changed: Bool { Self.normalised(original) != Self.normalised(round) }
    var id: String { label }

    /// The rows shown, in reading order; a field empty in both is left out.
    /// - Parameters:
    ///   - original: The idea before improving.
    ///   - round: A round's version.
    /// - Returns: The rows.
    static func rows(original: IdeaVersion, round: IdeaVersion) -> [ComparisonRow] {
        [
            ComparisonRow(label: "Pitch", original: original.pitch, round: round.pitch),
            ComparisonRow(label: "Who pays", original: original.buyer, round: round.buyer),
            ComparisonRow(label: "Pricing", original: original.pricing, round: round.pricing),
            ComparisonRow(label: "Where to find buyers", original: original.channel, round: round.channel),
            ComparisonRow(label: "Test it in one week", original: original.oneWeekTest, round: round.oneWeekTest),
            ComparisonRow(label: "Strongest objection", original: original.objection, round: round.objection),
        ].filter { !$0.original.isEmpty || !$0.round.isEmpty }
    }

    /// The round to show first: the one in use if a round was kept, otherwise the best-scoring (the later on a tie).
    /// - Parameters:
    ///   - run: The improvement run (at least two versions).
    ///   - inUse: Whether a version is the one in use, given its index.
    /// - Returns: An index from 1.
    static func initialRound(_ run: IdeaImprover.Run, inUse: (IdeaVersion, Int) -> Bool) -> Int {
        let rounds = Array(run.versions.indices.dropFirst())
        if let kept = rounds.first(where: { inUse(run.versions[$0], $0) }) { return kept }
        var best = 1
        for index in rounds where run.versions[index].score >= run.versions[best].score { best = index }
        return best
    }

    private static func normalised(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// The comparison section: a round picker, the original (or the round before) beside the chosen round, and Keep.
struct ImproveCompareSection: View {
    @Bindable var idea: KillerIdea
    let run: IdeaImprover.Run
    /// False while a run is going, so nothing can be kept mid-run.
    let canKeep: Bool
    /// The run's stop reason and date, shown under the comparison.
    let footer: String?
    /// Keeps a round (version, round number).
    let keep: (IdeaVersion, Int) -> Void
    @State private var selected: Int?
    /// Compare the chosen round with the round before it rather than the original.
    @State private var withPrevious = false

    var body: some View {
        let chosen = min(selected ?? ComparisonRow.initialRound(run, inUse: inUse), run.versions.count - 1)
        let leftIndex = withPrevious ? chosen - 1 : 0
        let leftTitle = leftIndex == 0 ? "Original" : "Round \(leftIndex)"
        let original = run.versions[leftIndex], round = run.versions[chosen]
        Section {
            if run.versions.count > 2 {
                let picker = Picker("Round", selection: Binding(get: { chosen }, set: { selected = $0 })) {
                    ForEach(1..<run.versions.count, id: \.self) { Text("Round \($0)").tag($0) }
                }
                // Segments get cramped past a handful of rounds, so longer runs use a menu.
                if run.versions.count > 5 { picker.pickerStyle(.menu) } else { picker.pickerStyle(.segmented) }
                Picker("Compare with", selection: $withPrevious) {
                    Text("Original").tag(false)
                    Text("Previous round").tag(true)
                }
                .pickerStyle(.segmented)
            }
            Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 14) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    heading(leftTitle, version: original, index: leftIndex)
                    heading("Round \(chosen)", version: round, index: chosen)
                }
                Divider().gridCellColumns(3)
                ForEach(ComparisonRow.rows(original: original, round: round)) { row in
                    GridRow {
                        Text(row.label).font(.subheadline.bold()).fixedSize(horizontal: false, vertical: true).frame(width: 130, alignment: .leading)
                        Text(row.original).frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            if row.changed {
                                Label("Changed", systemImage: "circle.fill")
                                    .font(.caption.bold()).foregroundStyle(.orange)
                                Text(row.round)
                            } else {
                                Text("(same)").foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(row.changed ? "\(row.label). \(leftTitle): \(row.original). Round \(chosen), changed: \(row.round)"
                                                    : "\(row.label): unchanged. \(row.original)")
                }
                if !round.changes.isEmpty {
                    Divider().gridCellColumns(3)
                    GridRow {
                        Text("What changed").font(.subheadline.bold()).frame(width: 130, alignment: .leading)
                        Text(round.changes).gridCellColumns(2)
                    }
                }
            }
            .padding(.vertical, 4)
            if round.passes && canKeep && !round.isInUse(by: idea, isOriginal: false) {
                Button("Keep this version (round \(chosen))", systemImage: "checkmark.circle") { keep(round, chosen) }
                    .frame(minHeight: 44)
            }
        } header: {
            Text(leftIndex == 0 ? "Original and round side by side" : "Round and the one before, side by side")
        } footer: {
            if let footer { Text(footer) }
        }
    }

    private func inUse(_ version: IdeaVersion, _ index: Int) -> Bool { version.isInUse(by: idea, isOriginal: index == 0) }

    /// A column heading: its name, score and status.
    private func heading(_ title: String, version: IdeaVersion, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                KillerScoreBadge(score: version.score)
            }
            if inUse(version, index) {
                Label("In use", systemImage: "checkmark.seal.fill").font(.caption.bold()).foregroundStyle(.green)
                    .accessibilityLabel("This version is in use")
            }
            if !version.survives {
                Label("Rejected by the devil's advocate", systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
            } else if !version.passes {
                Label(version.offer == nil ? "Has a weak spot" : "Not vibe-codable", systemImage: "xmark.octagon")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
