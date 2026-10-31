// BuildBrief.swift
// The "build brief" for a killer idea: a ready-to-paste prompt that turns the idea into a first-version
// plan for a solo builder using AI coding tools (Claude Code, Cursor and similar). Copied or shared from
// the idea detail screen (KillerViews).

import Foundation

extension Prompts {
    /// A ready-to-paste prompt that asks an AI tool for a small, buildable first version and a launch plan
    /// through the idea's sales channel.
    /// - Parameter idea: The killer idea.
    /// - Returns: The prompt. Includes About me, so the Copy button uses `SecureClipboard`.
    static func buildBrief(_ idea: KillerIdea) -> String {
        var lines = ["Act as an experienced product strategist and senior engineer. I will build this product on my own "
                     + "with AI coding tools, and sell it without a sales team. Help me plan a first version I can ship in 4 weeks.", ""]
        lines += ["Idea: \(idea.title)", "Pitch: \(idea.pitch)", "Buyer: \(idea.buyer)", "Pricing: \(idea.pricing)"]
        if !idea.replaces.isEmpty { lines.append("Replaces: \(idea.replaces)") }
        if !idea.channel.isEmpty { lines.append("Sales channel: \(idea.channel)") }
        lines += ["Why now: \(idea.whyNow)", "Strongest objection so far: \(idea.objection)",
                  "Known competitors: \(idea.competitors)"]
        let about = AppSettings.aboutMe
        if !about.isEmpty { lines.append("About me: \(about)") }
        if !idea.evidenceTitles.isEmpty {
            lines.append("Evidence:")
            lines += idea.evidence.map { "- \($0.title)" + ($0.url.map { " (\($0.absoluteString))" } ?? "") }
        }
        lines += ["", "Please produce:",
                  "1. The single best first customer segment and a one-line positioning statement",
                  "2. The smallest first version that a buyer would pay for: the screens, the data it stores and the one job it does",
                  "3. What not to build yet (features to leave out of the first version)",
                  "4. A suggested tech stack that one person can run cheaply, plus the risky parts (security, payments, "
                  + "integrations) and how to keep them simple",
                  "5. A build plan in weekly steps, with the first prompt I should give my AI coding tool",
                  "6. A launch plan for the sales channel: listing title, first 10 customers, and a landing-page headline",
                  "7. How to answer the strongest objection, and what would have to be true to reach 100 paying customers",
                  "Be specific and practical.", "", pastedPromptNotice]
        return lines.joined(separator: "\n")
    }
}
