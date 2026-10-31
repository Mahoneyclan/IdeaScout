// SettingsControls.swift
// Reusable Settings controls: SecretField (API keys in the Keychain), WeightSlider, SourceToggle and
// ModelChooser.

import SwiftUI

// MARK: - Reusable controls

/// Entry for a secret stored in the Keychain. Shows whether one is saved (last 4 characters only).
/// Only non-empty input is saved, so the field clearing itself when tapped again (normal for
/// password fields) can't erase a saved key; removing one is a deliberate tap. The key is saved once the
/// user finishes (Return, Save, leaving the field or the screen), not on every keystroke, so a half-typed
/// key never replaces a working one.
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
    /// Whether the field has the keyboard; losing it saves what was typed.
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField(saved.isEmpty ? title : "Replace \(title.lowercased())", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($editing)
                    .onSubmit(save)
                    .onChange(of: editing) { _, isEditing in if !isEditing { save() } }
                if !trimmedInput.isEmpty {
                    Button("Save", action: save)
                        .frame(minWidth: 44, minHeight: 44)
                        .buttonStyle(.borderless)
                }
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
        .onDisappear(perform: save)
    }

    /// The typed text without surrounding spaces or line breaks (often picked up when pasting a key).
    private var trimmedInput: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Saves the typed key if there is one. The field is cleared once it's saved, so the same text isn't saved
    /// twice and only the "Saved · ends …" label shows it.
    private func save() {
        let value = trimmedInput
        guard !value.isEmpty, Keychain.set(value, for: key) else { return }
        saved = value
        input = ""
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
    /// - Parameters:
    ///   - kind: The source.
    ///   - count: Items it gave in the last digest, if known.
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
    /// Output price typed in for an "Other…" model, per million tokens.
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
            if AppSettings.sanitizedPrice(customInput) == 0 || AppSettings.sanitizedPrice(customOutput) == 0 {
                // Money: a $0 (or negative) price hides this model's spending from the daily limit.
                Text("With a $0 price, this model's spending isn't counted towards your daily limit.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Button("Use recommended model") { useOther = false; model = provider.recommendedModel }
                .frame(minHeight: 44)
        }
    }
}
