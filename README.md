# IdeaScout

An iPhone and iPad app. IdeaScout finds the killer app idea in your interest area that you can vibe-code yourself and sell for a fraction of what competitors charge. It must make money even if only a small group of customers ever buys it. Growth is a bonus, not the goal. Each idea comes with a starter kit to build it.

An idea is killer only if it passes all five tests:
1. **Must be vibe-codable:** one person can build all of it with their AI coding tool, as a web app or an iPhone/iPad app. Any idea that fails this is dropped before you see it.
2. **People will pay for it:** they already pay for an app that does this, or pay for a workaround such as a pricier tool, a service or their own time.
3. **Real pain:** people complain about the apps they use for this (too expensive, too bloated, or missing the one thing they need), or that no app does it.
4. **Must be materially cheaper:** half the price of the cheapest competitor or less.
5. **Sales cover the build cost:** the likely sales from a small number of customers, found in a named place where they already look, recover the build cost and then keep making money.

The devil's advocate also asks: would the competitors follow, what stops another vibe coder copying it, and will customers keep paying? Each idea says which features to keep and which to leave out compared with the competitors, to size and price it.

(The idea engine is being reworked to match this purpose; the sections below describe how it works today.)

Native Swift / SwiftUI / SwiftData. No backend: everything runs on the phone.

## What it does

- **Ideas** (opens first): a leaderboard of killer ideas and near-misses, with today's refresh status and step-by-step progress at the top. Ideas rank on their score alone; one that comes back shows how many days it was seen. The AI is asked for new ideas, not repeats. Each card shows its weakest score; swipe left to dismiss (with confirmation). A dismissed idea comes back only if a later scan cites evidence it didn't have, marked "Back with new evidence".
- **Killer ideas:** your chosen AI proposes 5 ideas from the trends and pain clusters, all in your interest area (if set) and of the kind of app you chose in Settings (iPhone & iPad app, or web app), built with your chosen coding tool. Each names a buyer, the one job it does, features to keep and to leave out compared with the competitors, 1–3 competitors with their cheapest comparable plan, a recommended price per month, where buyers already look, and its evidence. A second, sceptical pass checks the competitors and prices, estimates build days and likely first-year customers, and answers three questions: would competitors follow, what stops copying, will customers keep paying. The app's code then judges each idea on the **five principles**: vibe-codable (a must: anything else is dropped), people will pay, real pain, materially cheaper (half the cheapest competitor's price or less; worked out in code), and sales cover the build cost (a first year of sales: the build, yearly costs such as hosting (Apple's developer fee isn't counted), each customer's running cost, and whether the app is sold once or by subscription, counting half the AI's customer guess to be cautious, with customers arriving evenly and subscribers leaving; scored on payback and held back by a weak sales channel). Each idea says whether to sell it once or by subscription, and why. The killer score is their average; up to 3 a day are kept and marked **Killer** or **Near-miss**. Without matching evidence, pain and willingness to pay can't score above 3; a 5 needs two different supporting items. "People will pay" passes only with proof (a paid competitor, or posts showing people pay); without it, it shows "Unproven". A coloured tag shows whether an idea undercuts competitors (blue) or fills a gap (purple). Ideas found before the principles keep their older score, are marked "older scoring" and rank below new ones.
- **Starter kit:** on an idea, one AI request (cost shown first, counts towards the daily limit, needs the trial or unlock) plans the first version: a one-paragraph spec, the screens, the data it stores, a cheap stack for one person with a rough running cost, what to leave out, the first slice with checks, and rules for the coding tool. It's saved on the idea. Pick Claude Code, Cursor, Replit or Lovable and **Share build prompt**: the kit as a prompt worded for that tool (rewording is free, on the phone; the share sheet includes Copy). Making it again asks first.
- **Improve this idea:** on an idea, up to 3 rounds (cost shown first as an upper guide, counts towards the daily limit, needs the trial or unlock). Each round the AI rewrites the idea to answer the devil's advocate's strongest objection, then the devil's advocate scores the rewrite. It stops when the score stops rising, reaches the quality bar, the rewrite is rejected, or after 3 rounds. Pain and willingness to pay can't rise above the original's, because a rewrite adds no new evidence. It's reached from the button under the idea's pitch. Every version is shown beside the original, and the one in use is marked **In use**; nothing changes until you tap **Keep this version**, which confirms the score change, and **Undo improvement** puts the original back. If the daily scan proposes the idea again, its new text replaces the kept improvement.
- **History:** one row per day with its best idea and pain clusters; tap a day for that day's ideas, pain clusters and trends.
- **Saved:** ideas you've bookmarked (bookmark button, or swipe right in Ideas) and projects you've starred, with notes, AI-suggested monetisable variants, and a copyable "flesh out this idea" prompt.
- **Settings:** About me, interest area, your AI coding tool (it decides the app type: Claude Code or Cursor for on-device iPhone/iPad apps, Lovable or Replit for web apps), My pain points and the daily digest time up front; under **Advanced**: sources and topics, scan windows, items the AI reads, quality bar and ranking weights, and AI provider, model, key, costs and daily limit.
- **Refreshing:** a button at the bottom of Ideas and History shows the estimated cost; a second refresh on the same day asks first.

All output is in English. Non-English items are translated by Claude, or filtered out when Apple's on-device model is used.

## Sources

| Source | What it gives |
|---|---|
| My pain points | Problems you type in Settings, one per line; treated as strong demand evidence |
| App Store complaints | 1–2 star reviews (last 60 days) of 12 top-grossing business, finance and productivity apps a day, AU and US stores |
| Consumer app complaints | The same for 12 top-grossing health and fitness, education, food and drink, and travel apps a day (on by default) |
| Hacker News on your area | Up to 40 recent stories and comments matching your **Interest area**, over the complaints window (on by default; skipped when the interest area is blank). The interest area is the only text of yours sent to a source. From every source, items that mention the interest area's words are read first. The App Store's own search isn't used: Apple's terms limit it to promoting the store |
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

Developer and game sources, GitHub, Show HN, AI research and AusTender start switched off: builder-side sources show what's already made rather than what buyers need, and government contracts are out of reach for a solo builder. Turn any of them back on in Settings. Vibe-code showcases, Y Combinator and the marketplaces stay on, and the AI treats what other builders have made as competition, not inspiration.

Sources are grouped as **demand** (complaints, your challenges, government spending), **supply** (things being built) and **timing** (new startups and research). Claude reads about 40% demand, 40% supply and 20% timing, with unused share going to demand first. Claude also groups demand items into **pain clusters** (one problem, one buyer) that the idea step must draw on, and flags noise so it's left out of "Other projects".

## AI summarisers

- **Cloud AI** (choose one in Settings → Advanced → AI & costs, each with its own API key in the Keychain and a recommended model preselected): Claude ("Mixed" default: Haiku 5.5 reads the day's items, Sonnet 5.5 writes ideas, Opus 5.5 is the devil's advocate; or one model for everything: Sonnet 5.5, Haiku 5.5, Opus 5.5, Fable 5.2), ChatGPT (GPT-6.1 Sol, GPT-6 Astra), Gemini (4 Argon, Gemma 4 31B), Grok 4.3, DeepSeek V4.1, Qwen 3.8 Max, GLM-5.3, Kimi K3, MiMo-V2.6-Pro, or any other model name with its own price. Claude talks to Anthropic's API; the others use one OpenAI-compatible client. Reads up to 300 projects per refresh (configurable: 100–500) and powers the killer ideas and the devil's advocate. A full refresh at 300 items costs about $0.20–0.25 with Claude Sonnet 5.5 (about $0.40–0.45 with Opus 5.5). Costs are tracked per model, and a daily limit (default $1.00; choose $1, $2, $3, $5, $10 or no limit) applies to every provider. If the chosen provider isn't set up, the app uses Apple's on-device AI, never another paid provider.
- **Apple Intelligence**: on-device and free, but reads only about 20 projects and can't generate killer ideas.
- **Keyword grouping**: the fallback when no AI is available.

## Trial, purchase and privacy

- Free download with a **7-day free trial** (a $0 non-consumable "7-Day Trial", as Apple requires) and a one-off **$1.99 unlock** (StoreKit 2). After the trial only new refreshes are locked; history and saved ideas stay readable. Debug builds without store products run as a "Developer build". `IdeaScout/IdeaScout.storekit` lets purchases be tested from Xcode.
- A **welcome flow** on first launch, and a **consent screen** before any data goes to a cloud AI (asked per provider, withdrawable in Settings).
- **About & privacy** screen with data-source credits; `PrivacyInfo.xcprivacy` privacy manifest; export-compliance flag set.
- Submission drafts in `docs/`: privacy policy, App Store listing, App Privacy answers, review notes, in-app purchase setup, and a data-source terms check.

## Reliability

- Claude replies are streamed, and dropped connections, timeouts and busy-server errors are retried twice (3 s, then 15 s, or the server's retry-after) for every provider.
- Other providers: if a model rejects a request with error 400, it's sent once more without the optional settings (reasoning effort, reply length), since some models refuse them. That second request may be billed.
- Claude requests use Anthropic's server-side fallback: if the chosen Claude model declines a request, Anthropic may answer with another Claude model. It's the same company, key and consent, never a different provider.
- The trends are saved as soon as they're ready, before the idea step, so a later failure can't lose them.
- A good digest is never replaced by a weaker one (Claude > Apple > keywords) on the same day; the failure is noted on the kept digest instead.
- Background refreshes stop cleanly when iOS ends the app's background time.
- **Works across your iPhone and iPad:** scans, ideas, starred projects, the main settings and AI spending sync through your own iCloud account. API keys stay on each device. An automatic scan waits if your other device has just started today's, so it isn't paid for twice.
- If the database can't save, the app shows a plain message instead of failing silently (the error is logged on the device, with details kept private).

## Secrets and configuration

See [SECURITY.md](SECURITY.md) for what data the app holds, how it's protected and the remaining risks.


API keys are **never** stored in source. Each AI provider's key is entered by the user in the app (Settings → Advanced → AI & costs, or the welcome screens) and saved in the device Keychain.

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

Swift Testing tests in `IdeaScoutTests/` (shared stand-ins in `TestSupport.swift`; no network calls; samples of each source and AI reply format). They cover source parsing, theme building and ranking, the Claude and OpenAI-style request and reply handling, streaming and retries, the killer-idea rules and evidence caps, costs and the daily limit, digest replacement rules, the English filter, scan settings, business-focus rules, demand sources, signal-based selection, pain clusters, saving ideas, and the trial and consent rules.

**Screen (UI) tests** in `IdeaScoutUITests/` cover first launch with consent, a refresh (and the "ask before a second refresh" rule), the paywall after the trial, "Delete all my data", saving an idea, and (on iPad) rotation. They run the app in a sealed test mode (`IdeaScout/Support/TestMode.swift`, active only in Debug builds) with an in-memory database, a separate settings store and Keychain area, fake sources and a scripted AI, so they never touch real data, the network or AI costs. Keep the device unlocked while they run.

Run them in Xcode with ⌘U, or on a connected iPhone or iPad:

```sh
xcodebuild -project IdeaScout.xcodeproj -scheme IdeaScout -destination 'id=<device-id>' build-for-testing
xcodebuild -project IdeaScout.xcodeproj -scheme IdeaScout -destination 'id=<device-id>' test-without-building
```

(The iOS simulator on the development Mac has hung in the past; since 31 Oct 2026 the shared "iPhone 17" simulator and the iPad Pro 13-inch simulator have worked. Use a physical device if a simulator run hangs.)

## Project layout

```
IdeaScout/
  App/        IdeaScoutApp (entry point), DigestService (the refresh: fetch → select → AI → save),
              DigestService+Selection (which items reach the AI), DigestService+Ideas (merging ideas into
              the leaderboard), DigestService+StarterKit (making a kit), DigestService+Housekeeping (delete all, starring and variant suggestions,
              background refresh scheduling)
  AI/         Summarizer protocol and prompts, LLMSummarizer (cloud AI, Claude client, retries),
              OpenAICompatibleClient (all other providers), AIProviders (provider and model catalogue),
              AppleSummarizer (on-device), KillerEngine (ideas and devil's advocate), StarterKit and
              StarterKitPrompts (the kit, its checks, and its wording for each coding tool)
  Sources/    SourceSupport (shared helpers), CommunityFetchers, CodeAndAIFetchers, MarketFetchers,
              GamesFetchers, DemandFetchers (one file per source family)
  Models/     Values (sources, signals, items, scores) and StoredModels (SwiftData: Digest, Theme, Item, Idea) and KillerIdea
  Store/      StoreManager (free trial and one-off unlock)
  Support/    AppSettings (+Costs: cost estimates), Keychain, UsageTracker (costs), Persistence (saving with error reporting),
              SecureClipboard (local-only, expiring copies), TestMode (sealed UI-test mode, active only
              in Debug builds). Notifier (the "ideas are ready" notification) is in AppSettings.swift
  Views/      SwiftUI screens: tabs, Ideas, day view, Saved, Settings, welcome/consent, paywall, About
  PrivacyInfo.xcprivacy, IdeaScout.storekit (test only, not shipped)
IdeaScoutTests/    Unit tests (Swift Testing)
IdeaScoutUITests/  Screen tests (XCUITest)
docs/         Privacy policy, App Store kit, data-source terms check
project.yml   XcodeGen project definition
ARCHITECTURE.md  How the app fits together
SECURITY.md   What data is held, how it's protected, remaining risks
CLAUDE.md     Conventions for working on this repo
```

## Status and open items

Version 1.0 is feature-complete. All 129 tests pass (124 unit, 5 screen) with no compiler warnings; the tests cover 83% of the non-screen code. The latest internal quality review (31 Oct 2026, round 2 of the review loop) scored 79.0 / 100; progress is tracked in `docs/review/PROGRESS.md`.

Still to do:
- **Before App Store release (owner):** choose a support email and host the privacy policy publicly, then fill in `AppInfo` in `AboutView.swift`; create the two in-app purchases in App Store Connect; decide whether to keep Y Combinator data (see `docs/source-terms.md`); archive, TestFlight and submit.
- **Reddit** as a source, once Reddit approves API access.
- **Model list upkeep:** a future admin routine to update providers, models and prices automatically (today they're hand-maintained in `AI/AIProviders.swift`).
- **Code quality backlog:** a screen test for History; split the seven files over 300 lines; Swift 6 strict concurrency; typed JSON schemas for AI replies. The killer-idea leaderboard loads every saved idea to rank it, because its score is calculated rather than stored; that's fast at today's volumes (a few ideas a day), and storing the score would add a new database field.
