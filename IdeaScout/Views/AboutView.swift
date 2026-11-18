// AboutView.swift
// Settings → About & privacy: version, privacy policy and support links, a plain privacy summary, and
// credits for every data source (AusTender's CC BY 4.0 licence requires attribution).

import SwiftUI

/// Contact details and links shown in the app. They must match `store/LISTING.md` and the public
/// support repo (`IdeaScout-support`).
enum AppInfo {
    /// The privacy policy in the public support repo. Optional only because `URL(string:)` is; a nil
    /// value hides the link row.
    static let privacyPolicyURL = URL(string: "https://github.com/Mahoneyclan/IdeaScout-support/blob/main/PRIVACY.md")
    /// The app's support inbox. An empty value hides the contact row.
    static let supportEmail = "mahoneyclanapps+ideascout@gmail.com"

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
        Credit(name: "Hacker News", note: "Show HN, Ask HN and comments, via the Algolia HN Search API."),
        Credit(name: "GitHub", note: "Public repositories, via the GitHub Search API."),
        Credit(name: "Apple App Store", note: "Top charts and customer reviews, via Apple's public RSS feeds."),
        Credit(name: "WordPress.org", note: "Popular plugins and their recent reviews, via the WordPress.org Plugins API and review feeds."),
        Credit(name: "AusTender", note: "Australian Government contract notices. Contains information from AusTender (www.tenders.gov.au), licensed under Creative Commons Attribution 4.0."),
        Credit(name: "Atlassian Marketplace", note: "Trending and new apps, via the Marketplace REST API. Off by default."),
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
                Text("IdeaScout has no server and no tracking. Your refreshes, ideas, saved projects, main settings and AI spending sync between your devices through your own iCloud account; I can't see them. Your API keys stay on each device. When you use a cloud AI, your About me, interest area, pain points and the collected public posts are sent directly to the provider you chose, using your own key.")
                    .font(.subheadline)
                if CloudSync.databaseSyncFailed {
                    Label("iCloud sync isn't working, so your refreshes and ideas are on this device only. Check you're signed in to iCloud, then restart IdeaScout.",
                          systemImage: "icloud.slash")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
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
                        Text("This can't be undone. It also deletes your IdeaScout data from iCloud and your other devices. Your API keys will need to be entered again.")
                    }
                if deleteBlocked {
                    Text("A refresh is running. Try again when it finishes.").font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("Removes your history, ideas, saved projects, settings and cost records from this device, iCloud and your other devices, and your API keys from this device.")
            }
        }
        .readableList()
        .navigationTitle("About")
    }
}
