// SettingsView.swift
// The Settings tab: About me, interest area, what you'll build and with which tool, My pain points, the daily digest time, and links to
// the Advanced pages (AdvancedSettingsViews.swift). Settings are UserDefaults keys from AppSettings.Keys,
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
    /// Whether a text field has the keyboard (the Done button clears it).
    @FocusState private var keyboardOpen: Bool

    /// The chosen app type (the tool's default before one is chosen) and a tool that can build it.
    private var appType: BuilderTool.AppType { AppSettings.choice(toolRaw: toolRaw, appTypeRaw: appTypeRaw).appType }
    private var tool: BuilderTool { AppSettings.choice(toolRaw: toolRaw, appTypeRaw: appTypeRaw).tool }

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
                    TextField("e.g. small trades businesses, fitness coaching, home budgeting", text: $interestArea)
                        .focused($keyboardOpen)
                } header: {
                    Text("Interest area")
                } footer: {
                    Text("Every idea will be in this area. Leave it blank for any area.")
                }

                Section {
                    FlowLayout(spacing: 8) {
                        ForEach(BuilderTool.AppType.allCases) { option in
                            ChoiceChip(title: option.label, isSelected: option == appType) {
                                appTypeRaw = option.rawValue
                                toolRaw = AppSettings.builderTool(tool, for: option).rawValue   // keep a tool that can build it
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("What you'll build")
                } footer: {
                    Text(appType.screenText)
                }

                Section {
                    FlowLayout(spacing: 8) {
                        ForEach(appType.tools) { option in
                            ChoiceChip(title: option.label, isSelected: option == tool) { toolRaw = option.rawValue }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Built with")
                } footer: {
                    Text("The AI coding tool you'll build ideas with, not the AI IdeaScout uses. Starter kits are worded for it, "
                         + "and its plan (about \(FiveTests.money(FiveTests.toolMonthlyCost(tool))) a month) is the build cost."
                         + (appType == .onDevice ? " Replit and Lovable make web apps only." : ""))
                }

                Section {
                    TextField("e.g. My invoicing app charges $40 a month and I only use the reminders", text: $fieldNotes, axis: .vertical)
                        .lineLimit(3...10)
                        .focused($keyboardOpen)
                } header: {
                    Text("My pain points")
                } footer: {
                    // Security: sent to the chosen AI provider; describing problems generically avoids leaking employer secrets.
                    Text("Problems you have with apps or tasks, one per line. Each is treated as strong evidence of pain. Sent to your AI provider, so describe them in general terms: no confidential company information or client names.")
                }

                Section {
                    Picker("Daily digest around", selection: $notifyHour) {
                        ForEach(5..<12) { hour in
                            // Safe to unwrap: hours 5–11 exist on every day in every calendar.
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
            .readableList()
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
