import SwiftUI
import SwiftData

/// Everyday inputs up front; configuration that rarely changes sits behind links.
struct SettingsView: View {
    @AppStorage(AppSettings.Keys.aboutMe) private var aboutMe = ""
    @AppStorage(AppSettings.Keys.fieldNotes) private var fieldNotes = ""
    @AppStorage(AppSettings.Keys.focusIndustry) private var focusIndustry = AppSettings.defaultFocusIndustry
    @AppStorage(AppSettings.Keys.notifyHour) private var notifyHour = 7
    @State private var usage = UsageTracker.summary()
    @State private var notificationsAllowed: Bool?
    @State private var hasProductHuntToken = false
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
                    Text("Skills, industry, time and budget. Used to score how well each idea fits you.")
                }

                Section {
                    TextField("e.g. Contractor timesheets are re-keyed into SAP every Friday", text: $fieldNotes, axis: .vertical)
                        .lineLimit(3...10)
                        .focused($keyboardOpen)
                } header: {
                    Text("My Business Challenges")
                } footer: {
                    Text("One per line. Each is treated as strong evidence of demand.")
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
                    NavigationLink { SourcesSettings() } label: {
                        LabeledContent("Sources", value: "\(SourceKind.allCases.filter(AppSettings.isEnabled).count) on")
                    }
                    NavigationLink { ScanRankingSettings() } label: { Text("Scan & ranking") }
                    NavigationLink { AISettings() } label: {
                        LabeledContent("AI & costs", value: "Today \(usage.today.cost.formatted(.currency(code: "USD")))")
                    }
                    NavigationLink { ProductHuntSettings() } label: {
                        LabeledContent("Product Hunt token", value: hasProductHuntToken ? "Saved" : "Not set")
                    }
                } header: {
                    Text("Advanced")
                }
            }
            .navigationTitle("Settings")
            .keyboardDone($keyboardOpen)
            .onAppear {
                usage = UsageTracker.summary()
                hasProductHuntToken = Keychain.get(.productHuntToken) != nil
            }
        }
    }
}

/// Lets the user drag the form to close the keyboard, and adds a Done button above it.
extension View {
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

struct AISettings: View {
    @AppStorage(AppSettings.Keys.aiProvider) private var provider = AIProvider.claude.rawValue
    @AppStorage(AppSettings.Keys.dailyCap) private var dailyCap = AppSettings.defaultDailyCap
    @AppStorage(AppSettings.Keys.claudeMaxItems) private var maxItems = AppSettings.defaultClaudeMaxItems
    @State private var usage = UsageTracker.summary()
    @State private var confirmReset = false
    @FocusState private var keyboardOpen: Bool

    var body: some View {
        Form {
            Section {
                Picker("Summaries by", selection: $provider) {
                    ForEach(AIProvider.allCases) { Text($0.label).tag($0.rawValue) }
                }
                LabeledContent("Apple Intelligence", value: AppleSummarizer.statusText)
                SecretField(title: "Claude API key", key: .claudeAPIKey)
                    .focused($keyboardOpen)
            } header: {
                Text("AI")
            } footer: {
                Text("Claude reads up to \(maxItems) items and makes the killer ideas. Apple is free but reads about 20. Keys are kept in the iPhone Keychain.")
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
                Text("AI costs (Claude)")
            } footer: {
                Text("Estimated at list prices. Refreshes skip Claude once the daily limit is reached.")
            }
        }
        .navigationTitle("AI & costs")
        .keyboardDone($keyboardOpen)
        .onAppear { usage = UsageTracker.summary() }
    }
}

struct ProductHuntSettings: View {
    @FocusState private var keyboardOpen: Bool

    var body: some View {
        Form {
            Section {
                SecretField(title: "Product Hunt developer token", key: .productHuntToken)
                    .focused($keyboardOpen)
            } footer: {
                Text("Create a free token at producthunt.com/v2/oauth/applications (use the Developer Token).")
            }
        }
        .navigationTitle("Product Hunt")
        .keyboardDone($keyboardOpen)
    }
}

/// Entry for a secret stored in the Keychain. Shows whether one is saved (last 4 characters only).
/// Only non-empty input is saved, so the field clearing itself when tapped again (normal for
/// password fields) can't erase a saved key; removing one is a deliberate tap.
struct SecretField: View {
    let title: String
    let key: Keychain.Key
    @State private var input = ""
    @State private var saved = ""
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

struct WeightSlider: View {
    let name: String
    let symbol: String
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

struct SourceToggle: View {
    let kind: SourceKind
    var count: Int?
    @AppStorage private var isOn: Bool

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
