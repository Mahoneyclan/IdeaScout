// SettingsView.swift
// The Settings tab as a short list (owner's choice, 12 Nov 2026): one row per setting showing its value. Text settings
// open their own screen (SettingTextScreen); app type and tool are pickers; then the daily time, and links to the Advanced pages (AdvancedSettingsViews.swift). Settings are UserDefaults keys from AppSettings.Keys,
// edited via @AppStorage; API keys go to the Keychain (SecretField in SettingsControls.swift).

import SwiftUI
import SwiftData

// MARK: - Main Settings tab

/// Everyday inputs up front; configuration that rarely changes sits behind links.
struct SettingsView: View {
    @AppStorage(AppSettings.Keys.aboutMe) private var aboutMe = ""
    @AppStorage(AppSettings.Keys.fieldNotes) private var fieldNotes = ""
    @AppStorage(AppSettings.Keys.interestArea) private var interestArea = ""
    @AppStorage(AppSettings.Keys.starterKitTool) private var toolRaw = BuilderTool.claudeCode.rawValue
    /// Empty until chosen; then the tool's default app type applies (see `AppSettings.appType`).
    @AppStorage(AppSettings.Keys.appType) private var appTypeRaw = ""
    @AppStorage(AppSettings.Keys.notifyHour) private var notifyHour = 7
    /// Spending summary for the "AI & costs" row; refreshed when the screen appears.
    @State private var usage = UsageTracker.summary()
    /// Set after the user answers the notification prompt.
    @State private var notificationsAllowed: Bool?

    /// The chosen app type (the tool's default before one is chosen) and a tool that can build it.
    private var appType: BuilderTool.AppType { AppSettings.choice(toolRaw: toolRaw, appTypeRaw: appTypeRaw).appType }
    private var tool: BuilderTool { AppSettings.choice(toolRaw: toolRaw, appTypeRaw: appTypeRaw).tool }

    /// The first line of a text setting, shortened, for its row.
    static func preview(_ text: String, empty: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !first.isEmpty else { return empty }
        return first.count > 24 ? String(first.prefix(22)) + "…" : first
    }

    /// "3 noted", one per non-empty line.
    static func countText(_ text: String) -> String {
        let count = text.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        return count == 0 ? "None" : "\(count) noted"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("About you") {
                    NavigationLink {
                        SettingTextScreen(title: "About me", text: $aboutMe, multiline: true,
                                          prompt: "e.g. Enterprise IT in energy, Swift hobbyist, evenings only, small budget",
                                          help: "Your skills, industry, spare time and budget. Used to score how well each idea fits you.",
                                          sentToAI: true)
                    } label: {
                        LabeledContent("About me", value: Self.preview(aboutMe, empty: "Not set"))
                    }
                    NavigationLink {
                        SettingTextScreen(title: "Interest area", text: $interestArea, multiline: false,
                                          prompt: "e.g. small trades businesses, fitness coaching, home budgeting",
                                          help: "Every idea will be in this area. Leave it blank for ideas in any area.",
                                          sentToAI: true)
                    } label: {
                        LabeledContent("Interest area", value: Self.preview(interestArea, empty: "Any area"))
                    }
                    NavigationLink {
                        SettingTextScreen(title: "My pain points", text: $fieldNotes, multiline: true,
                                          prompt: "e.g. My invoicing app charges $40 a month and I only use the reminders",
                                          help: "Problems you have with apps or tasks, one per line. Each counts as strong evidence of pain.",
                                          sentToAI: true)
                    } label: {
                        LabeledContent("My pain points", value: Self.countText(fieldNotes))
                    }
                }

                Section {
                    Picker("App type", selection: Binding(get: { appType }, set: { option in
                        appTypeRaw = option.rawValue
                        toolRaw = AppSettings.builderTool(tool, for: option).rawValue   // keep a tool that can build it
                    })) {
                        ForEach(BuilderTool.AppType.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Built with", selection: Binding(get: { tool }, set: { toolRaw = $0.rawValue })) {
                        ForEach(appType.tools) { option in
                            Text("\(option.label) · \(FiveTests.money(FiveTests.toolMonthlyCost(option)))/mo").tag(option)
                        }
                    }
                } header: {
                    Text("What you'll build")
                } footer: {
                    Text("Your AI coding tool, not the AI IdeaScout uses. Its plan is the build cost.")
                }

                Section {
                    Picker("Ready around", selection: $notifyHour) {
                        ForEach(5..<12) { hour in
                            // Safe to unwrap: hours 5–11 exist on every day in every calendar.
                            Text(Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)!
                                .formatted(date: .omitted, time: .shortened)).tag(hour)
                        }
                    }
                    .onChange(of: notifyHour) { DigestService.shared.scheduleBackgroundRefresh() }
                    if notificationsAllowed == true {
                        LabeledContent("Notifications", value: "On")
                    } else {
                        Button("Turn on notifications") { Task { notificationsAllowed = await Notifier.requestPermission() } }
                            .frame(minHeight: 44)
                    }
                } header: {
                    Text("Daily ideas")
                } footer: {
                    Text("iOS may skip a day; opening IdeaScout always brings today's ideas.")
                }

                Section {
                    AccessStatusRow()
                    NavigationLink { AboutView() } label: { Text("About & privacy") }
                }

                Section {
                    NavigationLink { SourcesSettings() } label: {
                        LabeledContent("Sources", value: "\(SourceKind.allCases.filter { $0.isScanSource && AppSettings.isEnabled($0) }.count) on")
                    }
                    NavigationLink { ScanRankingSettings() } label: { Text("Scan & ranking") }
                    NavigationLink { AISettings() } label: {
                        LabeledContent("AI & costs", value: "\(AppSettings.provider.shortName) · today \(usage.today.cost.formatted(.currency(code: "USD")))")
                    }
                } header: {
                    Text("Advanced")
                }
            }
            .readableList()
            .navigationTitle("Settings")
            .onAppear {
                usage = UsageTracker.summary()
            }
            .task { notificationsAllowed = await Notifier.isAllowed() }
        }
    }
}

/// Lets the user drag the form to close the keyboard, and adds a Done button above it.
extension View {
    /// Adds interactive keyboard dismissal and a Done button to a form with text fields.
    /// - Parameter focus: The screen's focus state; Done sets it to `false`.
    /// - Returns: The view with both behaviours added.
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

/// One text setting on its own screen: the box, what it's for, and (when it is) a warning that it's sent to the AI.
struct SettingTextScreen: View {
    let title: String
    @Binding var text: String
    let multiline: Bool
    let prompt: String
    let help: String
    /// Security: the text is sent to the chosen AI provider, so steer users away from confidential details.
    let sentToAI: Bool
    @FocusState private var keyboardOpen: Bool

    var body: some View {
        Form {
            Section {
                TextField(prompt, text: $text, axis: multiline ? .vertical : .horizontal)
                    .lineLimit(multiline ? 5...14 : 1...3)
                    .focused($keyboardOpen)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(help)
                    if sentToAI {
                        Label("Sent to your AI provider, so leave out confidential details, client names and personal information.",
                              systemImage: "exclamationmark.shield")
                    }
                }
            }
        }
        .readableList()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDone($keyboardOpen)
        .onAppear { keyboardOpen = text.isEmpty }
    }
}
