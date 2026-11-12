// PrinciplesViews.swift
// The five principles on an idea's screen (owner's decision, 11 Nov 2026): each with its score and a one-line
// reason, then the competitors and prices (with a coloured tag: undercuts a competitor, or fills a gap), the one job and features, the money, and the devil's advocate's answers.
// Only for ideas judged on the principles; older ideas keep their older scores section.

import SwiftUI

/// The sections shown for an idea judged on the five principles.
struct IdeaPrinciplesSections: View {
    let idea: KillerIdea

    var body: some View {
        Section {
            ForEach(idea.principles, id: \.name) { outcome in
                PrincipleRow(outcome: outcome)
            }
        } header: {
            Text("Five principles")
        } footer: {
            Text("Vibe-codable is a must; the other four score and rank the idea. The killer score is their average.")
        }
        if !idea.oneJob.isEmpty || !idea.keepFeatures.isEmpty || !idea.leaveOutFeatures.isEmpty {
            Section("What it does") {
                if !idea.oneJob.isEmpty { labelled("One job", idea.oneJob) }
                if !idea.keepFeatures.isEmpty { labelled("Keep", idea.keepFeatures.joined(separator: " · ")) }
                if !idea.leaveOutFeatures.isEmpty { labelled("Leave out", idea.leaveOutFeatures.joined(separator: " · ")) }
            }
        }
        Section {
            IdeaKindTag(idea: idea)
            if idea.competitorList.isEmpty && !idea.fillsGap {
                Text("No competitors named.")
            }
            ForEach(Array(idea.competitorList.enumerated()), id: \.offset) { _, competitor in
                CompetitorRow(competitor: competitor)
            }
        } header: {
            Text("Competitors")
        } footer: {
            Text(idea.competitorList.contains { $0.confirmed }
                 ? "Prices with a link were checked on the web."
                 : "Prices are the AI's best knowledge and haven't been checked on the web.")
        }
        if let plan = idea.salesPlan {
            SalesPlanSection(idea: idea, plan: plan)
        } else {
            Section("The money") {
                LabeledContent("Your price", value: idea.monthlyPrice >= FiveTests.minimumPrice ? FiveTests.money(idea.monthlyPrice) + " a month" : "Not given")
                LabeledContent("Build", value: buildText)
                LabeledContent("Likely customers, first year", value: "\(idea.likelyCustomers)")
                if let months = FiveTests.paybackMonths(buildCost: FiveTests.buildCost(days: idea.buildDays, tool: idea.builderTool),
                                                        customers: idea.likelyCustomers, price: idea.monthlyPrice) {
                    LabeledContent("Pays back the build", value: FiveTests.monthsText(months))
                }
            }
        }
        if !idea.followRisk.isEmpty || !idea.copyRisk.isEmpty || !idea.keepPaying.isEmpty {
            Section("Devil's advocate also asks") {
                if !idea.followRisk.isEmpty { labelled("Would competitors follow?", idea.followRisk) }
                if !idea.copyRisk.isEmpty { labelled("What stops copying?", idea.copyRisk) }
                if !idea.keepPaying.isEmpty { labelled("Will customers keep paying?", idea.keepPaying) }
            }
        }
    }

    private var buildText: String { IdeaPrinciplesSections.buildText(idea) }

    /// "about 10 days · $20 of Claude Code".
    static func buildText(_ idea: KillerIdea) -> String {
        (idea.buildDays > 0 ? "about \(idea.buildDays) day\(idea.buildDays == 1 ? "" : "s")" : "time not estimated")
            + " · " + FiveTests.money(FiveTests.buildCost(days: idea.buildDays, tool: idea.builderTool)) + " of \(idea.builderTool.label)"
    }

    private func labelled(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            Text(text)
        }
    }
}

/// One principle: a tick or cross (so it isn't shown by colour alone), its score and the reason.
struct PrincipleRow: View {
    let outcome: TestOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(outcome.name, systemImage: !outcome.known ? "questionmark.circle" : outcome.passed ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(outcome.passed || !outcome.known ? Color.primary : Color.orange)
                Spacer()
                Text(outcome.known ? "\(outcome.score)/5" : "Unproven").monospacedDigit()
            }
            Text(outcome.reason).font(.footnote).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(outcome.name), " + (outcome.known ? "\(outcome.passed ? "met" : "not met"), \(outcome.score) out of 5. " : "unproven. ")
                            + outcome.reason)
    }
}

/// A competitor, its plan and price, with a link when the price was checked on the web.
struct CompetitorRow: View {
    let competitor: Competitor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(competitor.name).font(.subheadline.bold())
                Spacer()
                Text(competitor.isFree ? "Free" : competitor.monthlyPrice >= FiveTests.minimumPrice
                     ? FiveTests.money(competitor.monthlyPrice) + "/mo" : "Price unknown")
                    .monospacedDigit()
            }
            if !competitor.plan.isEmpty { Text(competitor.plan).font(.footnote).foregroundStyle(.secondary) }
            if let url = URL(string: competitor.url), url.isWebLink {   // Security: web links only
                Link("Where the price was found", destination: url).font(.footnote)
            }
        }
    }
}

/// What kind of idea it is, in colour with an icon (never colour alone; owner, 12 Nov 2026): blue when it undercuts
/// competitors, purple when it fills a gap no app covers. Only for ideas judged on the five principles.
struct IdeaKindTag: View {
    let idea: KillerIdea

    /// The kinds an idea can be.
    enum Kind: Equatable {
        case undercuts(String)
        case competes(String)
        case fillsGap
        case noneNamed
    }

    /// The idea's kind and its wording.
    static func kind(competitors: [Competitor], fillsGap: Bool) -> Kind {
        let paid = FiveTests.paid(competitors)
        if let cheapest = paid.first {
            return .undercuts(paid.count == 1 ? "Undercuts \(cheapest.name) (\(FiveTests.money(cheapest.monthlyPrice))/mo)"
                              : "Undercuts \(paid.count) competitors (from \(FiveTests.money(cheapest.monthlyPrice))/mo)")
        }
        if let first = competitors.first {
            return .competes(competitors.count == 1 ? "Competes with \(first.name)" : "Competes with \(competitors.count) apps")
        }
        return fillsGap ? .fillsGap : .noneNamed
    }

    var body: some View {
        if idea.engineVersion >= 1 {
            let (text, icon, colour): (String, String, Color) = switch Self.kind(competitors: idea.competitorList, fillsGap: idea.fillsGap) {
            case .undercuts(let text): (text, "tag.fill", .blue)
            case .competes(let text): (text, "person.2.fill", .blue)
            case .fillsGap: ("Fills a gap: no app does this", "sparkles", .purple)
            case .noneNamed: ("No competitor named", "questionmark.circle", .secondary)
            }
            Label(text, systemImage: icon)
                .font(.caption.bold())
                .foregroundStyle(colour)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(colour.opacity(0.15), in: Capsule())
        }
    }
}

/// The money for an idea with a sales plan: how it's sold and why, the costs, and the first year's sums.
struct SalesPlanSection: View {
    let idea: KillerIdea
    let plan: SalesPlan

    var body: some View {
        let year = PaybackSums.firstYear(plan: plan, monthlyPrice: idea.monthlyPrice, customers: idea.likelyCustomers,
                                         buildDays: idea.buildDays, tool: idea.builderTool)
        Section {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent(plan.model.label, value: idea.monthlyPrice >= FiveTests.minimumPrice ? idea.priceText : "No price given")
                if !plan.reason.isEmpty { Text(plan.reason).font(.subheadline).foregroundStyle(.secondary) }
            }
            LabeledContent("Build", value: IdeaPrinciplesSections.buildText(idea))
            LabeledContent("Yearly costs", value: FiveTests.money(plan.otherYearlyCosts))
            LabeledContent("Running cost per customer", value: FiveTests.money(plan.runningCostPerCustomer) + " a month")
            if plan.model == .subscription {
                LabeledContent("Customers leaving",
                               value: "\(max(plan.monthlyChurnPercent, PaybackSums.minimumChurnPercent).formatted())% a month")
            }
            LabeledContent("Customers counted, first year",
                           value: "\(PaybackSums.cautiousCustomers(idea.likelyCustomers)) (half the guess of \(idea.likelyCustomers))")
            LabeledContent("First-year profit", value: FiveTests.money(year.profit))
            LabeledContent("Pays back", value: year.paybackMonth.map { "in about \($0) month\($0 == 1 ? "" : "s")" } ?? "Not within the first year")
        } header: {
            Text("The money")
        } footer: {
            Text("Customers arrive evenly over the year. Sales keep 85% after the store's fee. The costs and customers are the devil's advocate's estimates; to be cautious, the sums count half its customer guess. Apple's developer fee isn't included.")
        }
    }
}
