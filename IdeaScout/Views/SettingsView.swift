import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.Keys.topics) private var topics = AppSettings.defaultTopics
    @AppStorage(AppSettings.Keys.aiProvider) private var provider = AIProvider.claude.rawValue
    @AppStorage(AppSettings.Keys.notifyHour) private var notifyHour = 7
    @AppStorage(AppSettings.Keys.weightNovelty) private var wNovelty = 1.0
    @AppStorage(AppSettings.Keys.weightMomentum) private var wMomentum = 1.0
    @AppStorage(AppSettings.Keys.weightViability) private var wViability = 1.0
    @AppStorage(AppSettings.Keys.weightGap) private var wGap = 1.0

    @State private var claudeKey = Keychain.get(.claudeAPIKey) ?? ""
    @State private var productHuntToken = Keychain.get(.productHuntToken) ?? ""
    @State private var notificationsAllowed: Bool?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. ai agent, llm, mcp", text: $topics, axis: .vertical)
                } header: {
                    Text("Topics")
                } footer: {
                    Text("Comma-separated. Used to search GitHub (first \(GitHubFetcher.maxTopics) topics) and to group items when no AI is available.")
                }

                Section("Sources") {
                    ForEach(SourceKind.allCases) { kind in
                        SourceToggle(kind: kind)
                    }
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
                    SecureField("Claude API key", text: $claudeKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Keychain.set(claudeKey, for: .claudeAPIKey) }
                        .onChange(of: claudeKey) { _, value in Keychain.set(value, for: .claudeAPIKey) }
                } header: {
                    Text("AI")
                } footer: {
                    Text("Claude is recommended: it reads up to 150 projects and finds stronger trends (about 10 cents a day). Apple's on-device model is free but reads only about 20. If your choice isn't available, IdeaScout uses the other, then keyword grouping. Keys are stored in the iPhone Keychain.")
                }

                Section {
                    SecureField("Product Hunt developer token", text: $productHuntToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: productHuntToken) { _, value in Keychain.set(value, for: .productHuntToken) }
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
        }
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
    @AppStorage private var isOn: Bool

    init(kind: SourceKind) {
        self.kind = kind
        _isOn = AppStorage(wrappedValue: true, AppSettings.Keys.sourceEnabled(kind))
    }

    var body: some View {
        Toggle(isOn: $isOn) { Label(kind.label, systemImage: kind.symbol) }
    }
}
