# IdeaScout

An iPhone app that hunts for a **killer business software idea**. Every day it scans startup launches, funded B2B startups, top paid apps, open-source projects and places where people complain about missing or overpriced tools. It groups what it finds into trends, scores them, and proposes business product ideas that have survived a devil's-advocate review.

Native Swift / SwiftUI / SwiftData. No backend: everything runs on the phone.

## What it does

- **Ideas** (opens first): a leaderboard of killer ideas and near-misses, with today's refresh status and step-by-step progress at the top. Ideas that come back on several days rank higher. Each card shows its weakest score; swipe left to dismiss (with confirmation).
- **Killer ideas:** Claude suggests 5 business product ideas from the trends and pain clusters. Each names a business buyer, a monthly price and the manual task or costly workaround it replaces; at most 1 may be a developer tool and at least 2 target your industry focus. A second, sceptical pass (given each idea's evidence) tries to kill each one. Up to 3 survivors a day are kept and marked **Killer** (at or above the quality bar) or **Near-miss**. Each idea records every day it was proposed.
- **History:** one row per day with its best idea and pain clusters; tap a day for that day's ideas, pain clusters and trends.
- **Saved:** projects you've starred, with notes, AI-suggested monetisable variants, and a copyable "flesh out this idea" prompt.
- **Settings:** About me, My Business Challenges, industry focus and the daily digest time up front; under **Advanced**: sources and topics, scan windows, items Claude reads, quality bar and ranking weights, AI provider and key, costs and daily limit, and the Product Hunt token.
- **Refreshing:** a button at the bottom of Ideas and History shows the estimated cost; a second refresh on the same day asks first.

All output is in English. Non-English items are translated by Claude, or filtered out when Apple's on-device model is used.

## Sources

| Source | What it gives |
|---|---|
| My business challenges | Problems you type in Settings, one per line; treated as strong demand evidence |
| App Store complaints | 1–2 star reviews (last 60 days) of 12 top-grossing business, finance and productivity apps a day, AU and US stores |
| AusTender | The 15 largest Australian government IT contracts in the window |
| Atlassian Marketplace | Trending and new Jira/Confluence add-ons |
| Pain points | HN comments such as "I wish there was…", "too expensive", "alternative to", plus Ask HN (own window, default 14 days) |
| Y Combinator | B2B companies from the newest batch with 30+ of them, plus Launch HN posts |
| App Store | Top paid iPhone apps |
| GitHub | New repos with traction, searched by your topics |
| Hacker News | Show HN posts |
| Product Hunt | Today's launches (needs a free developer token) |
| Vibe-code showcases | AI-built apps shared on HN and GitHub |
| AI research | Hugging Face daily papers |
| Hugging Face *(off by default)* | Trending AI Spaces |
| DEV *(off by default)* | #showdev posts |
| Games *(off by default)* | itch.io, Steam, HN, GitHub and Hugging Face game projects |
| Lobsters *(off by default)* | "Show" posts |

Developer and game sources start switched off so ideas lean towards business buyers; turn any of them back on in Settings.

Sources are grouped as **demand** (complaints, your challenges, government spending), **supply** (things being built) and **timing** (new startups and research). Claude reads about 40% demand, 40% supply and 20% timing, with unused share going to demand first. Claude also groups demand items into **pain clusters** (one problem, one buyer) that the idea step must draw on, and flags noise so it's left out of "Other projects".

## AI summarisers

- **Claude** (default, recommended): reads up to 300 projects per refresh (configurable: 100–500) and powers the killer ideas and the devil's advocate. A full refresh at 300 items costs about $0.40–0.45. Settings → AI costs tracks spending, and a daily limit (default $1.00) skips Claude once it's reached.
- **Apple Intelligence**: on-device and free, but reads only about 20 projects and can't generate killer ideas.
- **Keyword grouping**: the fallback when no AI is available.

## Reliability

- Claude replies are streamed, and dropped connections, timeouts and busy-server errors are retried twice (3 s, then 15 s, or the server's retry-after).
- The trends are saved as soon as they're ready, before the idea step, so a later failure can't lose them.
- A good digest is never replaced by a weaker one (Claude > Apple > keywords) on the same day; the failure is noted on the kept digest instead.
- Background refreshes stop cleanly when iOS ends the app's background time.

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

65 Swift Testing tests in `IdeaScoutTests/`, covering source parsing, theme building, ranking, Claude request, streaming and retry handling, the killer-idea filter and evidence caps, the cost tracker and daily limit, digest replacement rules, the English filter, scan settings, the business-focus rules, the demand sources, signal-based selection and pain clusters. Run them in Xcode with ⌘U, or:

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
