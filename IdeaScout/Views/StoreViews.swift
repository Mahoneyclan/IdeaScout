// StoreViews.swift
// The "Support IdeaScout" section at the bottom of Settings (owner, 17 Nov 2026): three optional coffee tips with
// Apple's prices. No pop-ups or nags, and nothing is locked; it hides itself when Apple can't supply the tips.
// The logic lives in TipStore.

import SwiftUI

/// "Shout me a coffee": shown only when the tips loaded.
struct SupportSection: View {
    @Environment(TipStore.self) private var store

    var body: some View {
        if !store.tips.isEmpty {
            Section {
                ForEach(store.tips) { tip in
                    Button {
                        Task { await store.buy(tip) }
                    } label: {
                        HStack {
                            Label(tip.name, systemImage: "cup.and.saucer")
                            Spacer()
                            if store.buying == tip.id { ProgressView() } else { Text(tip.price).monospacedDigit() }
                        }
                        .frame(minHeight: 44)
                    }
                    .disabled(store.buying != nil)
                    .accessibilityLabel("\(tip.name), \(tip.price)")
                }
                if let message = store.message {
                    Label(message, systemImage: store.details == nil ? "heart.fill" : "exclamationmark.triangle")
                        .foregroundStyle(store.details == nil ? Color.pink : .orange)
                    if let details = store.details { ErrorDetailsDisclosure(details: details) }
                }
            } header: {
                Text("Support IdeaScout")
            } footer: {
                Text("IdeaScout is free and always will be. If it's useful to you, you can shout me a coffee. It helps "
                     + "cover my developer fees. It's completely optional and unlocks nothing. Thank you!")
            }
        }
    }
}
