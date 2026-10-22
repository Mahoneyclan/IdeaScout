import SwiftUI
import SwiftData

struct SettingsView: View {
    @AppStorage(AppSettings.Keys.topics) private var topics = AppSettings.defaultTopics
    @AppStorage(AppSettings.Keys.aiProvider) private var provider = AIProvider.claude.rawValue
    @AppStorage(AppSettings.Keys.notifyHour) private var notifyHour = 7
    @AppStorage(AppSettings.Keys.weightNovelty) private var wNovelty = 1.0
    @AppStorage(AppSettings.Keys.weightMomentum) private var wMomentum = 1.0
    @AppStorage(AppSettings.Keys.weightViability) private var wViability = 1.0
    @AppStorage(AppSettings.Keys.weightGap) private var wGap = 1.0
    @AppStorage(AppSettings.Keys.aboutMe) private var aboutMe = ""
    @AppStorage(AppSettings.Keys.qualityBar) private var qualityBar = AppSettings.defaultQualityBar
    @AppStorage(AppSettings.Keys.dailyCap) private var dailyCap = AppSettings.defaultDailyCap
    @AppStorage(AppSettings.Keys.focusIndustry) private var focusIndustry = AppSettings.defaultFocusIndustry
    @AppStorage(AppSettings.Keys.trendWindowDays) private var trendWindow = AppSettings.defaultTrendWindowDays
    @AppStorage(AppSettings.Keys.painWindowDays) private var painWindow = AppSettings.defaultPainWindowDays
    @AppStorage(AppSettings.Keys.claudeMaxItems) private var maxItems = AppSettings.defaultClaudeMaxItems
    @AppStorage(AppSettings.Keys.fieldNotes) private var fieldNotes = ""
    @Query(sort: \Digest.createdAt, order: .reverse) private var digests: [Digest]
    @State private var usage = UsageTracker.summary()

    @State private var notificationsAllowed: Bool?
    @FocusState private var keyboardOpen: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Wraps over several lines; Return closes the keyboard instead of adding a line break.
                    TextField("e.g. ai agent, saas, mcp", text: $topics, axis: .vertical)
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
                    Text("Comma-separated. Used to search GitHub (first \(GitHubFetcher.maxTopics) topics) and to group items when no AI is available.")
                }

                Section {
                    TextField("e.g. Swift/iOS developer, enterprise IT in energy, evenings only, small budget",
                              text: $aboutMe, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($keyboardOpen)
                } header: {
                    Text("About me")
                } footer: {
                    Text("Your skills, industry, time and budget. Claude uses this to score how well each killer idea fits you. Stored only on this iPhone and sent to Claude with each refresh.")
                }

                Section {
                    TextField("e.g. Contractor timesheets are re-keyed into SAP every Friday", text: $fieldNotes, axis: .vertical)
                        .lineLimit(3...10)
                        .focused($keyboardOpen)
                } header: {
                    Text("My Business Challenges")
                } footer: {
                    Text("One business challenge per line: things you see people struggle with, re-key, chase or pay too much for. Each line is treated as strong evidence of demand. Tap Done to close the keyboard.")
                }

                Section {
                    TextField("e.g. energy, utilities and enterprise IT", text: $focusIndustry)
                        .focused($keyboardOpen)
                } header: {
                    Text("Industry focus")
                } footer: {
                    Text("Ideas are for business buyers. At least 2 of each day's ideas are aimed at this industry; the rest target small and medium businesses.")
                }

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
                    Text("How far back to look, and how many items Claude reads per refresh (with rough cost per refresh). Longer windows favour older, already-popular posts; pain points are rarer, so they get their own window. More items cost more and take longer.")
                }

                Section {
                    let counts = Dictionary(grouping: digests.first?.themes.flatMap(\.items) ?? [], by: \.source).mapValues(\.count)
                    ForEach(Signal.allCases, id: \.self) { signal in
                        ForEach(SourceKind.allCases.filter { $0.signal == signal }) { kind in
                            SourceToggle(kind: kind, count: counts[kind])
                        }
                    }
                } header: {
                    Text("Sources")
                } footer: {
                    Text("Grouped as demand (complaints and spending), supply (things being built) and timing (new startups and research). Claude reads about 40% demand, 40% supply and 20% timing; the number is how many items each source gave in the last digest.")
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
                    Text("Trends and killer ideas scoring below this are hidden. Killer ideas must also score at least 2 on every measure. Higher means fewer, stronger ideas. Default \(AppSettings.defaultQualityBar.formatted()).")
                }

                Section {
                    WeightSlider(name: "Novelty", symbol: "sparkles", value: $wNovelty)
                    WeightSlider(name: "Momentum", symbol: "chart.line.uptrend.xyaxis", value: $wMomentum)
                    WeightSlider(name: "Viability", symbol: "checkmark.seal", value: $wViability)
                    WeightSlider(name: "Opportunity gap", symbol: "arrow.triangle.branch", value: $wGap)
                } header: {
                    Text("Ranking weights")
                } footer: {
                    Text("How much each score counts towards a theme's overall rank. Set one to 0 to ignore it. Momentum is measured from stars, points and votes; the others are judged by the AI.")
                }

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
                    Text("Claude is recommended: it reads up to \(maxItems) projects (see Scan) and finds much stronger trends and ideas. Apple's on-device model is free but reads only about 20. If your choice isn't available, IdeaScout uses the other, then keyword grouping. Keys are stored in the iPhone Keychain.")
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
                        Button("Reset cost tracker", role: .destructive) {
                            UsageTracker.reset()
                            usage = UsageTracker.summary()
                        }
                    }
                } header: {
                    Text("AI costs (Claude)")
                } footer: {
                    Text("Estimated from the token counts Claude reports, at Claude Opus 5.5 list prices ($4 in / $20 out per million tokens). Once today's spending reaches the daily limit, refreshes skip Claude until tomorrow. Apple's on-device AI is free. Check console.anthropic.com for your actual bill.")
                }

                Section {
                    SecretField(title: "Product Hunt developer token", key: .productHuntToken)
                        .focused($keyboardOpen)
                } header: {
                    Text("Product Hunt")
                } footer: {
                    Text("Create a free token at producthunt.com/v2/oauth/applications (use the Developer Token).")
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
                    .disabled(notificationsAllowed == true)
                } header: {
                    Text("Daily notification")
                } footer: {
                    Text("iOS decides exactly when background refreshes run and may skip days, especially if you rarely open the app. The digest is always built when you open IdeaScout.")
                }
            }
            .navigationTitle("Settings")
            .scrollDismissesKeyboard(.interactively)
            .onAppear { usage = UsageTracker.summary() }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { keyboardOpen = false }
                }
            }
        }
    }
}

/// Entry for a secret stored in the Keychain. Shows whether one is saved (last 4 characters only).
/// Only non-empty input is saved, so the field clearing itself when tapped again (normal for
/// password fields) can't erase a saved key; removing one is a deliberate tap.
private struct SecretField: View {
    let title: String
    let key: Keychain.Key
    @State private var input = ""
    @State private var saved = ""

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
                    Button("Remove", role: .destructive) {
                        Keychain.set(nil, for: key)
                        saved = ""
                        input = ""
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
        }
        .onAppear { saved = Keychain.get(key) ?? "" }
    }
}

private struct WeightSlider: View {
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

private struct SourceToggle: View {
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
