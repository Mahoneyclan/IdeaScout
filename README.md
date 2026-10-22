# IdeaScout

An iPhone app that hunts for a **killer business software idea**. Every day it scans startup launches, funded B2B startups, top paid apps, open-source projects and places where people complain about missing or overpriced tools. It groups what it finds into trends, scores them, and proposes business product ideas that have survived a devil's-advocate review.

Native Swift / SwiftUI / SwiftData. No backend: everything runs on the phone.

## What it does

- **Ideas** (opens first): a leaderboard of killer ideas and near-misses, with today's refresh status and step-by-step progress at the top. Ideas that come back on several days rank higher. Each card shows its weakest score; swipe left to dismiss (with confirmation).
- **Killer ideas:** Claude suggests 5 business product ideas from the trends and pain clusters. Each names a business buyer, a monthly price and the manual task or costly workaround it replaces; at most 1 may be a developer tool and at least 2 target your industry focus. A second, sceptical pass (given each idea's evidence) tries to kill each one. Up to 3 survivors a day are kept and marked **Killer** (at or above the quality bar) or **Near-miss**. Each idea records every day it was proposed.
- **History:** one row per day with its best idea and pain clusters; tap a day for that day's ideas, pain clusters and trends.
- **Saved:** ideas you've bookmarked (bookmark button, or swipe right in Ideas) and projects you've starred, with notes, AI-suggested monetisable variants, and a copyable "flesh out this idea" prompt.
- **Settings:** About me, My Business Challenges, industry focus and the daily digest time up front; under **Advanced**: sources and topics, scan windows, items the AI reads, quality bar and ranking weights, and AI provider, model, key, costs and daily limit.
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
| Vibe-code showcases | AI-built apps shared on HN and GitHub |
| AI research | Hugging Face daily papers |
| Hugging Face *(off by default)* | Trending AI Spaces |
| DEV *(off by default)* | #showdev posts |
| Games *(off by default)* | itch.io, Steam, HN, GitHub and Hugging Face game projects |
| Lobsters *(off by default)* | "Show" posts |

Developer and game sources start switched off so ideas lean towards business buyers; turn any of them back on in Settings.

Sources are grouped as **demand** (complaints, your challenges, government spending), **supply** (things being built) and **timing** (new startups and research). Claude reads about 40% demand, 40% supply and 20% timing, with unused share going to demand first. Claude also groups demand items into **pain clusters** (one problem, one buyer) that the idea step must draw on, and flags noise so it's left out of "Other projects".

## AI summarisers

- **Cloud AI** (choose one in Settings → Advanced → AI & costs, each with its own API key in the Keychain and a recommended model preselected): Claude (Sonnet 5.5 default, Opus 5.5, Fable 5.1), ChatGPT (GPT-6.1 Sol, GPT-6 Astra), Gemini (4 Argon, Gemma 4 31B), Grok 4.3, DeepSeek V4.1, Qwen 3.8 Max, GLM-5.3, Kimi K3, MiMo-V2.6-Pro, or any other model name with its own price. Claude talks to Anthropic's API; the others use one OpenAI-compatible client. Reads up to 300 projects per refresh (configurable: 100–500) and powers the killer ideas and the devil's advocate. A full refresh at 300 items costs about $0.20–0.25 with Claude Sonnet 5.5 (about $0.40–0.45 with Opus 5.5). Costs are tracked per model, and a daily limit (default $1.00) applies to every provider. If the chosen provider isn't set up, the app uses Apple's on-device AI, never another paid provider.
- **Apple Intelligence**: on-device and free, but reads only about 20 projects and can't generate killer ideas.
- **Keyword grouping**: the fallback when no AI is available.

## Trial, purchase and privacy

- Free download with a **7-day free trial** (a $0 non-consumable "7-Day Trial", as Apple requires) and a one-off **$0.99 unlock** (StoreKit 2). After the trial only new refreshes are locked; history and saved ideas stay readable. Debug builds without store products run as a "Developer build". `IdeaScout/IdeaScout.storekit` lets purchases be tested from Xcode.
- A **welcome flow** on first launch, and a **consent screen** before any data goes to a cloud AI (asked per provider, withdrawable in Settings).
- **About & privacy** screen with data-source credits; `PrivacyInfo.xcprivacy` privacy manifest; export-compliance flag set.
- Submission drafts in `docs/`: privacy policy, App Store listing, App Privacy answers, review notes, in-app purchase setup, and a data-source terms check.

## Reliability

- Claude replies are streamed, and dropped connections, timeouts and busy-server errors are retried twice (3 s, then 15 s, or the server's retry-after).
- The trends are saved as soon as they're ready, before the idea step, so a later failure can't lose them.
- A good digest is never replaced by a weaker one (Claude > Apple > keywords) on the same day; the failure is noted on the kept digest instead.
- Background refreshes stop cleanly when iOS ends the app's background time.

## Secrets and configuration

API keys are **never** stored in source. Each AI provider's key is entered by the user in the app (Settings → Advanced → AI & costs, or the welcome screens) and saved in the iPhone Keychain.

**No configuration file is required to build.** The project has no `.xcconfig` keys today. If one is ever needed (for example a signing override), put it in an untracked `*.xcconfig` file: `.gitignore` already excludes `*.xcconfig` and `.env`. Never commit key values.

Placeholders to fill in before an App Store release: `AppInfo.privacyPolicyURL` and `AppInfo.supportEmail` in `IdeaScout/Views/AboutView.swift` (the matching rows stay hidden while they're empty).

## Building

Requirements: Xcode 27+, iOS 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate        # creates IdeaScout.xcodeproj from project.yml (the project file isn't committed)
open IdeaScout.xcodeproj
```

Set your own signing team in `project.yml` (`DEVELOPMENT_TEAM`) if you aren't the original author, then build to a device. Running from Xcode uses `IdeaScout/IdeaScout.storekit`, so the trial and unlock can be tested without real purchases. Debug builds installed another way show "Developer build" and skip the purchase check until the products exist in App Store Connect; Release builds never do.

## Tests

Swift Testing tests in `IdeaScoutTests/IdeaScoutTests.swift` (no network calls; samples of each source and AI reply format). They cover source parsing, theme building and ranking, the Claude and OpenAI-style request and reply handling, streaming and retries, the killer-idea rules and evidence caps, costs and the daily limit, digest replacement rules, the English filter, scan settings, business-focus rules, demand sources, signal-based selection, pain clusters, saving ideas, and the trial and consent rules.

Run them in Xcode with ⌘U, or on a connected iPhone:

```sh
xcodebuild -project IdeaScout.xcodeproj -scheme IdeaScout -destination 'id=<device-id>' build-for-testing
xcodebuild -project IdeaScout.xcodeproj -scheme IdeaScout -destination 'id=<device-id>' test-without-building
```

(The iOS simulator on the original development Mac hangs, so tests are run on a physical iPhone.)

## Project layout

```
IdeaScout/
  App/        IdeaScoutApp (entry point), DigestService (the refresh: fetch → select → AI → save)
  AI/         Summarizer protocol and prompts, LLMSummarizer (cloud AI, Claude client, retries),
              OpenAICompatibleClient (all other providers), AIProviders (provider and model catalogue),
              AppleSummarizer (on-device), KillerEngine (ideas and devil's advocate)
  Sources/    Fetchers (supply, timing, pain points, shared helpers), DemandFetchers (demand sources)
  Models/     Value types and SwiftData models (Digest, Theme, Item, Idea, KillerIdea)
  Store/      StoreManager (free trial and one-off unlock)
  Support/    AppSettings, Keychain, UsageTracker (costs), notifications
  Views/      SwiftUI screens: tabs, Ideas, day view, Saved, Settings, welcome/consent, paywall, About
  PrivacyInfo.xcprivacy, IdeaScout.storekit (test only, not shipped)
IdeaScoutTests/
docs/         Privacy policy, App Store kit, data-source terms check
project.yml   XcodeGen project definition
ARCHITECTURE.md  How the app fits together
CLAUDE.md     Conventions for working on this repo
```
