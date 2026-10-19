# IdeaScout

An iPhone app that hunts for a **killer product idea**. Every day it scans open-source projects, AI "vibe-coded" apps, startup launches and places where people complain about missing tools. It groups what it finds into trends, scores them, and proposes a few product ideas that have survived a devil's-advocate review.

Native Swift / SwiftUI / SwiftData. No backend: everything runs on the phone.

## What it does

- **Today:** the past 7 days of activity grouped into 4–6 themes. Each theme is scored for novelty, momentum, viability and opportunity gap, and comes with money-making variants.
- **Killer ideas:** Claude suggests 5 product ideas from the trends. A second, sceptical pass tries to kill each one. Only ideas that survive and clear the quality bar are kept, at most 2 a day.
- **Top Ideas:** a leaderboard of every killer idea found so far. Ideas that come back on several days rank higher.
- **History:** past daily digests.
- **Ideas:** projects you've starred, with notes, AI-suggested monetisable variants, and a copyable "flesh out this idea" prompt.
- **Settings:** topics, an "About me" profile (used to score how well an idea fits you), sources on/off, quality bar, ranking weights, AI provider, an AI cost tracker, and the daily notification time.

All output is in English. Non-English items are translated by Claude, or filtered out when Apple's on-device model is used.

## Sources

| Source | What it gives |
|---|---|
| GitHub | New repos with traction, searched by your topics |
| Hacker News | Show HN posts |
| Product Hunt | Today's launches (needs a free developer token) |
| Vibe-code showcases | AI-built apps shared on HN and GitHub |
| Hugging Face | Trending AI Spaces |
| DEV | #showdev posts |
| Games | itch.io, Steam, HN, GitHub and Hugging Face game projects |
| Pain points | HN comments such as "I wish there was…", plus Ask HN |
| Y Combinator | The latest YC batch and Launch HN posts |
| App Store | Top paid iPhone apps |
| AI research | Hugging Face daily papers |
| Lobsters | "Show" posts |

## AI summarisers

- **Claude** (default, recommended): reads up to 150 projects per refresh and powers the killer ideas and the devil's advocate. Costs roughly 10 cents a day; Settings → AI costs tracks it.
- **Apple Intelligence**: on-device and free, but reads only about 20 projects and can't generate killer ideas.
- **Keyword grouping**: the fallback when no AI is available.

## Secrets

API keys are **never** stored in source. The Claude API key and the Product Hunt token are entered in Settings and saved in the iPhone Keychain. `.gitignore` excludes `*.xcconfig` and `.env`.

## Building

Requirements: Xcode 27+, iOS 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate        # creates IdeaScout.xcodeproj from project.yml (the project file isn't committed)
open IdeaScout.xcodeproj
```

Set your own signing team in `project.yml` (`DEVELOPMENT_TEAM`) if you aren't the original author, then build to a device.

## Tests

43 Swift Testing tests in `IdeaScoutTests/`, covering source parsing, theme building, ranking, the Claude request and reply handling, the killer-idea filter, the cost tracker, the English filter and the quality bar. Run them in Xcode with ⌘U, or:

```sh
xcodebuild test -project IdeaScout.xcodeproj -scheme IdeaScout -destination 'platform=iOS,id=<device-id>'
```

## Project layout

```
IdeaScout/
  App/        App entry point, DigestService (fetch → filter → summarise → save)
  AI/         Claude, Apple and keyword summarisers; prompts; KillerEngine
  Sources/    One fetcher per source
  Models/     SwiftData models (Digest, Theme, Item, Idea, KillerIdea)
  Support/    Settings, Keychain, cost tracker, notifications
  Views/      SwiftUI screens
IdeaScoutTests/
project.yml   XcodeGen project definition
```
