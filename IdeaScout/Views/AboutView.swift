// AboutView.swift
// Settings → About & privacy: version, privacy policy and support links, a plain privacy summary, and
// credits for every data source (AusTender's CC BY 4.0 licence requires attribution).

import SwiftUI

/// Contact details and links shown in the app and on the App Store. Fill in before release.
enum AppInfo {
    /// Empty until the privacy policy is hosted publicly; while nil, the link row is hidden.
    static let privacyPolicyURL = URL(string: "")
    /// Empty until a support address is chosen; while empty, the contact row is hidden.
    static let supportEmail = ""

    /// "1.0 (1)": marketing version and build number from Info.plist.
    static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}

/// Version, privacy, support and credits for the data sources IdeaScout reads.
struct AboutView: View {
    @Environment(DigestService.self) private var service
    /// Shows the "Delete all my data?" confirmation.
    @State private var confirmDelete = false
    /// Set if deletion couldn't run (a refresh was in progress).
    @State private var deleteBlocked = false

    /// One data source and how it's used or licensed.
    private struct Credit: Identifiable {
        let name: String
        let note: String
        var id: String { name }
    }

    private let credits = [
        Credit(name: "Hacker News", note: "Show HN, Ask HN, Launch HN and comments, via the Algolia HN Search API."),
        Credit(name: "GitHub", note: "Public repositories, via the GitHub Search API."),
        Credit(name: "Apple App Store", note: "Top charts and customer reviews, via Apple's public RSS feeds."),
        Credit(name: "AusTender", note: "Australian Government contract notices. Contains information from AusTender (www.tenders.gov.au), licensed under Creative Commons Attribution 4.0."),
        Credit(name: "Atlassian Marketplace", note: "Trending and new apps, via the Marketplace REST API."),
        Credit(name: "Y Combinator", note: "Company directory data via the open yc-oss project."),
        Credit(name: "Hugging Face", note: "Daily papers and Spaces, via the Hugging Face Hub API."),
        Credit(name: "DEV, Lobsters, itch.io, Steam", note: "Optional sources, off by default."),
    ]

    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: AppInfo.version)
                if let url = AppInfo.privacyPolicyURL { Link("Privacy policy", destination: url).frame(minHeight: 44) }
                if !AppInfo.supportEmail.isEmpty, let mail = URL(string: "mailto:\(AppInfo.supportEmail)") {
                    Link("Contact support", destination: mail).frame(minHeight: 44)
                }
            }
            Section {
                Text("IdeaScout has no server and no tracking. Your settings, history and keys stay on this device. When you use a cloud AI, your About me, business challenges and the collected public posts are sent directly to the provider you chose, using your own key.")
                    .font(.subheadline)
            } header: {
                Text("Privacy")
            }
            Section {
                ForEach(credits) { credit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(credit.name).font(.subheadline.bold())
                        Text(credit.note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Data sources")
            } footer: {
                Text("Trademarks belong to their owners. IdeaScout isn't affiliated with or endorsed by these services.")
            }
            Section {
                Button("Delete all my data", role: .destructive) { confirmDelete = true }
                    .frame(minHeight: 44)
                    // Attached to the button so on iPad the question points at it.
                    .confirmationDialog("Delete all your IdeaScout data?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Delete everything", role: .destructive) { deleteBlocked = !service.deleteAllData() }
                    } message: {
                        Text("This can't be undone. Your API keys will need to be entered again. Purchases are kept and can be restored.")
                    }
                if deleteBlocked {
                    Text("A refresh is running. Try again when it finishes.").font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("Removes your history, ideas, saved projects, settings, API keys and cost records from this device. Purchases are kept.")
            }
        }
        .readableList()
        .navigationTitle("About")
    }
}
