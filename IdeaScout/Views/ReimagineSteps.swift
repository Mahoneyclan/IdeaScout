// ReimagineSteps.swift
// The parts of the "Reimagine an app" screen (owner, 16 Nov 2026): step 1's "About this app" card, step 2's ways
// to reimagine it, and step 3's idea with its "Compared with what they use now" rows. Text from the web is shown as
// plain text; links open only if they're web links.

import SwiftUI

/// Step 1: what the research found about the app, with links.
struct ReimagineProfileSections: View {
    let run: Reimagine.Run
    /// Clears the run so the user can correct the name (shown only before any idea is built).
    var notThisApp: (() -> Void)?

    var body: some View {
        let p = run.profile
        Section {
            if !p.whatItDoes.isEmpty { Text(p.whatItDoes) }
            if !p.whoFor.isEmpty { LabeledContent("Who it's for", value: p.whoFor) }
            ForEach(Array(p.plans.enumerated()), id: \.offset) { _, plan in PlanRow(plan: plan) }
            if p.whatItDoes.isEmpty && p.plans.isEmpty {
                Text("The web search found little about this app itself, so the ways below lean on its reviews and your note.")
                    .foregroundStyle(.secondary)
            }
            if let notThisApp {
                Button("Not this app? Change the name", systemImage: "arrow.uturn.backward", action: notThisApp)
                    .frame(minHeight: 44)
            }
        } header: {
            Text("Step 1 · About \(run.target.name)")
        } footer: {
            if !run.target.from.isEmpty { Text("From the link: \(run.target.from)") }
        }
        findings("What people like", p.likes, icon: "hand.thumbsup")
        let reviews = run.items.filter { $0.source == .appReviews }
        if !p.complaints.isEmpty || !reviews.isEmpty {
            Section("What people complain about") {
                ForEach(Array(p.complaints.enumerated()), id: \.offset) { _, f in
                    FindingRow(text: f.text, who: f.who, url: f.url, icon: "hand.thumbsdown")
                }
                ForEach(reviews, id: \.key) { r in
                    FindingRow(text: r.title, who: r.detail, url: r.url.absoluteString, icon: "star.slash")
                }
            }
        }
        if !p.alternatives.isEmpty {
            Section("What else people pay for") {
                ForEach(Array(p.alternatives.enumerated()), id: \.offset) { _, plan in PlanRow(plan: plan) }
            }
        }
        findings("Already made by solo builders", p.alreadyBuilt, icon: "wand.and.stars")
    }

    @ViewBuilder private func findings(_ title: String, _ list: [Reimagine.Finding], icon: String) -> some View {
        if !list.isEmpty {
            Section(title) {
                ForEach(Array(list.enumerated()), id: \.offset) { _, f in FindingRow(text: f.text, who: f.who, url: f.url, icon: icon) }
            }
        }
    }
}

/// A finding with who said it and its link.
private struct FindingRow: View {
    let text: String
    let who: String
    let url: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(text, systemImage: icon)
            if !who.isEmpty { Text(who).font(.caption).foregroundStyle(.secondary) }
            if let link = URL(string: url), link.isWebLink { Link("Source", destination: link).font(.caption) }   // Security: web links only
        }
    }
}

/// A paid plan with its price and link.
private struct PlanRow: View {
    let plan: Reimagine.Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(plan.plan.isEmpty ? plan.name : "\(plan.name) · \(plan.plan)",
                           value: plan.monthlyPrice >= FiveTests.minimumPrice ? FiveTests.money(plan.monthlyPrice) + "/mo" : "Price unknown")
            if let link = URL(string: plan.url), link.isWebLink { Link("Where the price was found", destination: link).font(.caption) }
        }
    }
}

/// Step 2: one way to reimagine the app, tappable to choose it.
struct DirectionRow: View {
    let direction: Reimagine.Direction
    let chosen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle").foregroundStyle(chosen ? Color.accentColor : .secondary)
                Text("\(direction.job) — for \(direction.who)").font(.headline)
            }
            if !direction.whyNotTheApp.isEmpty { Text("Why the app won't fix it: \(direction.whyNotTheApp)").font(.subheadline) }
            if !direction.alreadyServedBy.isEmpty { Text("Who serves them now: \(direction.alreadyServedBy)").font(.caption) }
            if !direction.roughPrice.isEmpty { Text("Rough price: \(direction.roughPrice)").font(.caption) }
            if !direction.isOwn {
                Label(direction.strong ? "Strong evidence (\(direction.evidenceNumbers.count) items)"
                                       : "Thin evidence (\(direction.evidenceNumbers.count) items)",
                      systemImage: direction.strong ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(.caption.bold()).foregroundStyle(direction.strong ? .green : .orange)
            }
        }
        .padding(.vertical, 4)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }
}

/// Step 3: the idea, how it compares with what the group uses now, and the devil's advocate's verdict.
struct ReimagineBuiltSection: View {
    let built: ReimagineBuilt

    var body: some View {
        let c = built.result.candidate, r = built.result.review
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(c.title).font(.headline)
                Text(c.pitch)
                Text("\(c.buyer) · \(FiveTests.money(built.result.price))/mo").font(.caption).foregroundStyle(.secondary)
            }
            Label(r.survives ? "Backed by the devil's advocate" : "Rejected by the devil's advocate: \(r.objection)",
                  systemImage: r.survives ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(r.survives ? .green : .orange)
        } header: {
            Text("Step 3 · Your idea")
        }
        if !c.oneJob.isEmpty || !c.keepFeatures.isEmpty || !c.leaveOutFeatures.isEmpty {
            Section("Compared with what they use now") {
                if !c.oneJob.isEmpty { LabeledContent("New", value: c.oneJob) }
                if !c.keepFeatures.isEmpty { LabeledContent("Keep", value: c.keepFeatures.joined(separator: " · ")) }
                if !c.leaveOutFeatures.isEmpty { LabeledContent("Leave out", value: c.leaveOutFeatures.joined(separator: " · ")) }
            }
        }
    }
}
