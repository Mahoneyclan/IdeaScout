// SettingsView.swift
// The Settings tab and its Advanced pages (Sources, Scan & ranking, AI & costs), plus the reusable
// controls they use: SecretField (API keys, stored in the Keychain), WeightSlider, SourceToggle and
// ModelChooser. All other settings are UserDefaults keys from AppSettings.Keys, edited via @AppStorage.

import SwiftUI
import SwiftData

// MARK: - Main Settings tab

/// Everyday inputs up front; configuration that rarely changes sits behind links.
struct SettingsView: View {
    @AppStorage(AppSettings.Keys.aboutMe) private var aboutMe = ""
    @AppStorage(AppSettings.Keys.fieldNotes) private var fieldNotes = ""
    @AppStorage(AppSettings.Keys.focusIndustry) private var focusIndustry = AppSettings.defaultFocusIndustry
    @AppStorage(AppSettings.Keys.notifyHour) private var notifyHour = 7
    /// Spending summary for the "AI & costs" row; refreshed when the screen appears.
    @State private var usage = UsageTracker.summary()
    /// Set after the user answers the notification prompt.
    @State private var notificationsAllowed: Bool?
    /// Whether a text field has the keyboard (the Done button clears it).
    @FocusState private var keyboardOpen: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Enterprise IT in energy, Swift hobbyist, evenings only, small budget",
                              text: $aboutMe, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($keyboardOpen)
                } header: {
                    Text("About me")
                } footer: {
                    // Security: this text is sent to the chosen AI provider, so steer users away from confidential details.
                    Text("Skills, industry, time and budget. Used to score how well each idea fits you. Sent to your AI provider, so avoid confidential or personal details.")
                }

                Section {
                    TextField("e.g. Contractor timesheets are re-keyed into SAP every Friday", text: $fieldNotes, axis: .vertical)
                        .lineLimit(3...10)
                        .focused($keyboardOpen)
                } header: {
                    Text("My Business Challenges")
                } footer: {
                    // Security: sent to the chosen AI provider; describing problems generically avoids leaking employer secrets.
                    Text("One per line. Each is treated as strong evidence of demand. Sent to your AI provider, so describe problems in general terms: no confidential company information or client names.")
                }

                Section {
                    TextField("e.g. energy, utilities and enterprise IT", text: $focusIndustry)
                        .focused($keyboardOpen)
                } header: {
                    Text("Industry focus")
                } footer: {
                    Text("At least 2 ideas a day target this industry; the rest target small and medium businesses.")
                }

                Section {
                    Picker("Daily digest around", selection: $notifyHour) {
                        ForEach(5..<12) { hour in
                            Text(Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)!
                                .formatted(date: .omitted, time: .shortened)).tag(hour)
                        }
                    }
                    .onChange(of: notifyHour) { DigestService.shared.scheduleBackgroundRefresh() }
                    Button(notificationsAllowed == true ? "Notifications allowed" : "Allow notifications") {
                        Task { notificationsAllowed = await Notifier.requestPermission() }
                    }
                    .frame(minHeight: 44)
                    .disabled(notificationsAllowed == true)
                } header: {
                    Text("Daily digest")
                } footer: {
                    Text("iOS decides when background refreshes run and may skip days. The digest is always built when you open IdeaScout.")
                }

                Section {
                    AccessStatusRow()
                    NavigationLink { AboutView() } label: { Text("About & privacy") }
                }

                Section {
                    NavigationLink { SourcesSettings() } label: {
                        LabeledContent("Sources", value: "\(SourceKind.allCases.filter(AppSettings.isEnabled).count) on")
                    }
                    NavigationLink { ScanRankingSettings() } label: { Text("Scan & ranking") }
                    NavigationLink { AISettings() } label: {
                        LabeledContent("AI & costs", value: "\(AppSettings.provider.shortName) · today \(usage.today.cost.formatted(.currency(code: "USD")))")
                    }
                } header: {
                    Text("Advanced")
                }
            }
            .navigationTitle("Settings")
            .keyboardDone($keyboardOpen)
            .onAppear {
                usage = UsageTracker.summary()
            }
        }
    }
}

/// Lets the user drag the form to close the keyboard, and adds a Done button above it.
extension View {
    /// - Parameter focus: The screen's focus state; Done sets it to `false`.
    func keyboardDone(_ focus: FocusState<Bool>.Binding) -> some View {
        scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focus.wrappedValue = false }
                }
            }
    }
}

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

// MARK: - Reusable controls

/// Entry for a secret stored in the Keychain. Shows whether one is saved (last 4 characters only).
/// Only non-empty input is saved, so the field clearing itself when tapped again (normal for
/// password fields) can't erase a saved key; removing one is a deliberate tap.
struct SecretField: View {
    /// Field label, e.g. "Claude API key".
    let title: String
    /// Which Keychain entry it edits.
    let key: Keychain.Key
    /// What the user is typing (never pre-filled with the saved key).
    @State private var input = ""
    /// The saved key, read on appear; only its last 4 characters are shown.
    @State private var saved = ""
    /// Shows the "Remove the key?" confirmation.
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField(saved.isEmpty ? title : "Replace \(title.lowercased())", text: $input)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: input) { _, value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, Keychain.set(trimmed, for: key) else { return }
                    saved = trimmed
                }
            if !saved.isEmpty {
                HStack {
                    Label("Saved · ends …\(String(saved.suffix(4)))", systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(.green)
                    Spacer()
                    Button("Remove", role: .destructive) { confirmRemove = true }
                        .frame(minWidth: 44, minHeight: 44)
                        .buttonStyle(.borderless)
                        .confirmationDialog("Remove the \(title.lowercased())?", isPresented: $confirmRemove, titleVisibility: .visible) {
                            Button("Remove", role: .destructive) {
                                Keychain.set(nil, for: key)
                                saved = ""
                                input = ""
                            }
                        }
                }
            }
        }
        .onAppear { saved = Keychain.get(key) ?? "" }
    }
}

/// A 0–2 slider (steps of 0.5) for one trend ranking weight; 0 shows "Off".
struct WeightSlider: View {
    /// Score name.
    let name: String
    /// SF Symbol.
    let symbol: String
    /// The weight being edited.
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading) {
            LabeledContent {
                Text(value == 0 ? "Off" : "×\(value.formatted(.number.precision(.fractionLength(1))))").monospacedDigit()
            } label: {
                Label(name, systemImage: symbol)
            }
            Slider(value: $value, in: 0...2, step: 0.5)
                .accessibilityLabel("\(name) weight")
        }
    }
}

/// One source's on/off switch, with its signal and last-digest count. Defaults to the source's own default
/// until the user changes it.
struct SourceToggle: View {
    /// The source.
    let kind: SourceKind
    /// Items it gave in the last digest, if known.
    var count: Int?
    @AppStorage private var isOn: Bool

    /// Creates the toggle, defaulting to the source's own default until the user changes it.
    init(kind: SourceKind, count: Int? = nil) {
        self.kind = kind
        self.count = count
        _isOn = AppStorage(wrappedValue: kind.enabledByDefault, AppSettings.Keys.sourceEnabled(kind))
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.label)
                    Text(kind.signal.label + (count.map { " · \($0) in last digest" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: kind.symbol)
            }
        }
    }
}

/// Model picker for one provider: the recommended model first, a few alternatives, or any other model name.
struct ModelChooser: View {
    /// The provider whose model is being chosen.
    let provider: AIProvider
    /// The chosen model ID (defaults to the recommended one).
    @AppStorage private var model: String
    /// Prices typed in for an "Other…" model, per million tokens.
    @AppStorage private var customInput: Double
    @AppStorage private var customOutput: Double
    /// Whether "Other…" is selected, so a custom name can be typed.
    @State private var useOther = false
    @FocusState private var typing: Bool

    /// Binds the model and custom prices to this provider's settings keys.
    init(provider: AIProvider) {
        self.provider = provider
        let fallback = provider.models.first?.price ?? ModelPrice(input: 0, output: 0)
        _model = AppStorage(wrappedValue: provider.recommendedModel, AppSettings.Keys.model(provider))
        _customInput = AppStorage(wrappedValue: fallback.input, AppSettings.Keys.customPrice(provider, "input"))
        _customOutput = AppStorage(wrappedValue: fallback.output, AppSettings.Keys.customPrice(provider, "output"))
    }

    /// Whether the model is one of the listed ones.
    private var isKnown: Bool { provider.models.contains { $0.id == model } }

    var body: some View {
        Picker("Model", selection: Binding(
            get: { useOther || !isKnown ? "other" : model },
            set: { value in
                if value == "other" { useOther = true } else { useOther = false; model = value }
            })) {
            ForEach(Array(provider.models.enumerated()), id: \.element.id) { index, option in
                Text(index == 0 ? "\(option.label) (recommended)" : option.label).tag(option.id)
            }
            Text("Other…").tag("other")
        }
        if let known = provider.models.first(where: { $0.id == model }), !useOther {
            LabeledContent("Price per 1M tokens",
                           value: "\(known.price.input.formatted(.currency(code: "USD"))) in · \(known.price.output.formatted(.currency(code: "USD"))) out")
                .font(.caption)
        } else {
            TextField("Model name, e.g. \(provider.recommendedModel)", text: $model)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($typing)
            LabeledContent("Input $ per 1M tokens") {
                TextField("Input", value: $customInput, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            LabeledContent("Output $ per 1M tokens") {
                TextField("Output", value: $customOutput, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            Button("Use recommended model") { useOther = false; model = provider.recommendedModel }
                .frame(minHeight: 44)
        }
    }
}
