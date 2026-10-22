// AdvancedSettingsViews.swift
// The Advanced pages of Settings: Sources (topics and source switches), Scan & ranking (windows, items,
// quality bar, weights) and AI & costs (provider, model, key, consent, spending and the daily limit).

import SwiftUI
import SwiftData

// MARK: - Advanced pages

/// Topics and the on/off switch for every source, grouped by signal, with each source's item count in the
/// last digest.
struct SourcesSettings: View {
    @AppStorage(AppSettings.Keys.topics) private var topics = AppSettings.defaultTopics
    @Query(sort: \Digest.createdAt, order: .reverse) private var digests: [Digest]
    @FocusState private var keyboardOpen: Bool

    var body: some View {
        Form {
            Section {
                // Wraps over several lines; Return closes the keyboard instead of adding a line break.
                TextField("e.g. invoicing, compliance, scheduling", text: $topics, axis: .vertical)
                    .lineLimit(2...6)
                    .submitLabel(.done)
                    .textInputAutocapitalization(.never)
                    .focused($keyboardOpen)
                    .onChange(of: topics) { _, value in
                        guard value.contains(where: \.isNewline) else { return }
                        if value.last?.isNewline == true { keyboardOpen = false }
                        topics = value.split(whereSeparator: \.isNewline).joined(separator: ", ")
                    }
            } header: {
                Text("Topics")
            } footer: {
                Text("Comma-separated. Steers GitHub search (first \(GitHubFetcher.maxTopics) topics).")
            }
            let counts = Dictionary(grouping: digests.first?.themes.flatMap(\.items) ?? [], by: \.source).mapValues(\.count)
            ForEach(Signal.allCases, id: \.self) { signal in
                Section(signal.label) {
                    ForEach(SourceKind.allCases.filter { $0.signal == signal }) { kind in
                        SourceToggle(kind: kind, count: counts[kind])
                    }
                }
            }
            Section {} footer: {
                Text("Demand 40% · Supply 40% · Timing 20%. Numbers = items in the last digest.")
            }
        }
        .navigationTitle("Sources")
        .keyboardDone($keyboardOpen)
    }
}

/// Look-back windows, items the AI reads (with cost estimates), the quality bar and trend ranking weights.
struct ScanRankingSettings: View {
    @AppStorage(AppSettings.Keys.trendWindowDays) private var trendWindow = AppSettings.defaultTrendWindowDays
    @AppStorage(AppSettings.Keys.painWindowDays) private var painWindow = AppSettings.defaultPainWindowDays
    @AppStorage(AppSettings.Keys.claudeMaxItems) private var maxItems = AppSettings.defaultClaudeMaxItems
    @AppStorage(AppSettings.Keys.qualityBar) private var qualityBar = AppSettings.defaultQualityBar
    @AppStorage(AppSettings.Keys.weightNovelty) private var wNovelty = 1.0
    @AppStorage(AppSettings.Keys.weightMomentum) private var wMomentum = 1.0
    @AppStorage(AppSettings.Keys.weightViability) private var wViability = 1.0
    @AppStorage(AppSettings.Keys.weightGap) private var wGap = 1.0

    var body: some View {
        Form {
            Section {
                Picker("Trend window", selection: $trendWindow) {
                    ForEach(AppSettings.windowChoices, id: \.self) { Text("\($0) days").tag($0) }
                }
                Picker("Pain points window", selection: $painWindow) {
                    ForEach(AppSettings.windowChoices, id: \.self) { Text("\($0) days").tag($0) }
                }
                Picker("Items Claude reads", selection: $maxItems) {
                    ForEach(AppSettings.maxItemChoices, id: \.self) { count in
                        let cost = AppSettings.estimatedRefreshCost(items: count)
                        Text("\(count) · ~\(cost.lowerBound.formatted(.currency(code: "USD")))–\(cost.upperBound.formatted(.currency(code: "USD")))").tag(count)
                    }
                }
            } header: {
                Text("Scan")
            } footer: {
                Text("Longer windows favour older posts. More items cost more.")
            }

            Section {
                VStack(alignment: .leading) {
                    LabeledContent {
                        Text(qualityBar == 0 ? "Off" : "\(qualityBar.formatted()) / 5").monospacedDigit()
                    } label: {
                        Label("Quality bar", systemImage: "line.horizontal.star.fill.line.horizontal")
                    }
                    Slider(value: $qualityBar, in: 0...4.5, step: 0.5)
                        .accessibilityLabel("Quality bar")
                }
            } header: {
                Text("Quality bar")
            } footer: {
                Text("Ideas at or above this are Killer; below are Near-misses. Trends below it are hidden. Default \(AppSettings.defaultQualityBar.formatted()).")
            }

            Section {
                WeightSlider(name: "Novelty", symbol: "sparkles", value: $wNovelty)
                WeightSlider(name: "Momentum", symbol: "chart.line.uptrend.xyaxis", value: $wMomentum)
                WeightSlider(name: "Viability", symbol: "checkmark.seal", value: $wViability)
                WeightSlider(name: "Opportunity gap", symbol: "arrow.triangle.branch", value: $wGap)
            } header: {
                Text("Trend ranking weights")
            } footer: {
                Text("How much each score counts towards a trend's rank. 0 ignores it.")
            }
        }
        .navigationTitle("Scan & ranking")
    }
}

/// Provider, model, API key, data-sharing consent, spending summary and daily limit. Switching to a cloud
/// provider without consent opens the consent screen straight away.
struct AISettings: View {
    @AppStorage(AppSettings.Keys.aiProvider) private var provider = AIProvider.claude.rawValue
    /// The provider whose consent screen is showing.
    @State private var consentFor: AIProvider?
    /// Bumped after consent changes, so the "Data sharing" row redraws.
    @State private var consentVersion = 0
    @AppStorage(AppSettings.Keys.dailyCap) private var dailyCap = AppSettings.defaultDailyCap
    @AppStorage(AppSettings.Keys.claudeMaxItems) private var maxItems = AppSettings.defaultClaudeMaxItems
    @State private var usage = UsageTracker.summary()
    /// Shows the "Reset the cost tracker?" confirmation.
    @State private var confirmReset = false
    @FocusState private var keyboardOpen: Bool

    /// The chosen provider (unknown values fall back to Claude).
    private var chosen: AIProvider { AIProvider(rawValue: provider) ?? .claude }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $provider) {
                    ForEach(AIProvider.allCases) { Text($0.label).tag($0.rawValue) }
                }
                if chosen.isCloud {
                    ModelChooser(provider: chosen)
                    Button {
                        if AppSettings.hasConsent(chosen) { AppSettings.setConsent(chosen, false); consentVersion += 1 }
                        else { consentFor = chosen }
                    } label: {
                        LabeledContent("Data sharing", value: AppSettings.hasConsent(chosen) ? "Agreed · tap to withdraw" : "Not agreed · tap to review")
                    }
                    .id(consentVersion)
                    .frame(minHeight: 44)
                    SecretField(title: "\(chosen.shortName) API key", key: chosen.keychainKey!)
                        .id(chosen)   // reload the saved state when the provider changes
                        .focused($keyboardOpen)
                } else {
                    LabeledContent("Status", value: AppleSummarizer.statusText)
                }
            } header: {
                Text("AI")
            } footer: {
                if chosen.isCloud {
                    Text("Run by a company in \(chosen.country). \(chosen.dataNote.map { $0 + " " } ?? "")Get a key at \(chosen.keyURL). Reads up to \(maxItems) items and makes the killer ideas. Keys stay in the iPhone Keychain. If this provider isn't set up, IdeaScout uses Apple's free on-device AI, never another paid provider.")
                } else {
                    Text("Free and private, but reads only about 20 items and can't make killer ideas.")
                }
            }

            Section {
                LabeledContent("Today", value: usage.today.cost.formatted(.currency(code: "USD")))
                LabeledContent("This month", value: usage.thisMonth.cost.formatted(.currency(code: "USD")))
                LabeledContent("All time", value: usage.allTime.cost.formatted(.currency(code: "USD")))
                Picker("Daily limit", selection: $dailyCap) {
                    ForEach([0.2, 0.4, 0.6, 1.0, 2.0], id: \.self) { Text($0.formatted(.currency(code: "USD"))).tag($0) }
                    Text("No limit").tag(0.0)
                }
                DisclosureGroup("Details") {
                    ForEach(usage.byFeatureThisMonth, id: \.feature) { row in
                        LabeledContent(row.feature, value: row.usage.cost.formatted(.currency(code: "USD")))
                    }
                    LabeledContent("Calls this month", value: "\(usage.thisMonth.calls)")
                    LabeledContent("Tokens this month",
                                   value: "\((usage.thisMonth.input + usage.thisMonth.cacheRead + usage.thisMonth.cacheWrite).formatted()) in · \(usage.thisMonth.output.formatted()) out")
                    ForEach(usage.lastDays, id: \.day) { day in
                        LabeledContent(day.day, value: day.cost.formatted(.currency(code: "USD")))
                            .font(.caption)
                    }
                    Button("Reset cost tracker", role: .destructive) { confirmReset = true }
                        .frame(minHeight: 44)
                        .confirmationDialog("Reset the cost tracker?", isPresented: $confirmReset, titleVisibility: .visible) {
                            Button("Reset", role: .destructive) {
                                UsageTracker.reset()
                                usage = UsageTracker.summary()
                            }
                        } message: {
                            Text("This clears all recorded spending, including today's, which the daily limit uses.")
                        }
                }
            } header: {
                Text("AI costs")
            } footer: {
                Text("Estimated at list prices. Refreshes skip Claude once the daily limit is reached.")
            }
        }
        .navigationTitle("AI & costs")
        // Switching to a cloud provider asks for consent before any data is sent to it.
        .onChange(of: provider) { _, value in
            if let new = AIProvider(rawValue: value), new.isCloud, !AppSettings.hasConsent(new) { consentFor = new }
        }
        .sheet(item: $consentFor) { target in
            ConsentView(provider: target) { _ in consentVersion += 1 }
        }
        .keyboardDone($keyboardOpen)
        .onAppear { usage = UsageTracker.summary() }
    }
}
