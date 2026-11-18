# IdeaScout

## About the app

IdeaScout is a free iPhone and iPad app for people who want to build and sell a small app of their own with an AI coding tool.

- Every day it reads public complaints and listings (App Store and WordPress plugin reviews, Hacker News and more) and suggests app ideas in your area, each with a buyer, a price at most a quarter of the competition's, and where to find customers.
- A second, sceptical AI tries to knock every idea down first. Each idea shows why it passes four simple tests, and comes with a starter kit you can paste into your coding tool.
- "Reimagine an app" explains an app you name, then suggests gaps beside it that you could fill.
- It uses the AI you choose, with your own key, shows the cost before every paid step and has a daily spending limit.

## Get help

Questions, problems or ideas? Email **[mahoneyclanapps+ideascout@gmail.com](mailto:mahoneyclanapps+ideascout@gmail.com)**.

If you're reporting a problem, please include:

- what you were doing and what happened
- your iPhone or iPad model and iOS version
- the app version (shown in the app's Settings or About screen, or in the App Store)
- a screenshot, if it helps

**Please note:** I'm a novice developer and make this app as a hobby, in my spare time. I'm happy to help and I read every message, but replies and fixes may take a while, and some problems may be beyond what I can fix.

## Support the app

My apps are free. I make them as a hobby, so I can't promise regular updates or new features. If an app is useful to you and you'd like to say thanks, you can shout me a coffee from the Support section in the app's Settings. It's completely optional, and the app works the same either way.

## Privacy

See the [privacy policy](PRIVACY.md).

---

# How it works (for developers)

An iPhone and iPad app. IdeaScout finds the killer app idea in your interest area that you can vibe-code yourself and sell for a quarter of what competitors charge, or less. It must make money even if only a small group of customers ever buys it. Growth is a bonus, not the goal. Each idea comes with a starter kit to build it.

An idea is killer only if it passes these tests:
1. **Must be vibe-codable:** one person can build all of it with their AI coding tool, as a web app or an iPhone/iPad app. Any idea that fails this is dropped before you see it.
2. **People will pay for it:** they already pay for an app that does this, or pay for a workaround such as a pricier tool, a service or their own time.
3. **Real pain:** people complain about the apps they use for this (too expensive, too bloated, or missing the one thing they need), or that no app does it.
4. **Sales cover the build cost:** the likely sales from a small number of customers, found in a named place where they already look, recover the build cost and then keep making money.

The devil's advocate also asks: would the competitors follow, what stops another vibe coder copying it, and will customers keep paying? Each idea says which features to keep and which to leave out compared with the competitors, to size and price it. The recommended price is at most 25% of the cheapest competitor's comparable plan: a fixed rule applied in code, not a scored test (owner, 16 Nov 2026; it replaced the half-price test).

Native Swift / SwiftUI / SwiftData. No backend: everything runs on the phone.

## What it does

- **Ideas** (opens first): a leaderboard of killer ideas and ideas that are almost there, with today's refresh status at the top. During a refresh, a **Today's refresh** checklist lists all five steps from the start (read the sources, find complaints and trends, come up with ideas, devil's advocate checks them, check competitor prices). Each shows waiting, working, done, skipped or didn't work (an icon and a word), a one-line result, and opens for detail; skipped or failed steps say why, and VoiceOver announces each finished step. Afterwards it folds into a "How it went" row until the next refresh. Ideas rank on their score alone; one that comes back shows how many days it was seen. The AI is asked for new ideas, not repeats. Each card shows its weakest score; swipe left, or use **Dismiss this idea** at the bottom of the idea, to dismiss it (with confirmation). With no ideas, the tab says why (no cloud AI key, the spending limit, or nothing passed) and what to do. A dismissed idea comes back only if a later scan cites evidence it didn't have, marked "Back with new evidence".
- **Killer ideas:** your chosen AI proposes 5 ideas from the trends and common complaints (pain clusters), all in your interest area (if set) and of the kind of app you chose in Settings (iPhone & iPad app, or web app), built with your chosen coding tool. Each names a buyer, the one job it does, features to keep and to leave out compared with the competitors, 1–3 competitors with their cheapest comparable plan, a recommended price per month, where buyers already look, and its evidence. A second, sceptical pass checks the competitors and prices, estimates build days and likely first-year customers, and answers three questions: would competitors follow, what stops copying, will customers keep paying. The app's code caps the recommended price at 25% of the cheapest competitor's comparable plan (a higher price, or none, is set to the cap; with no paid competitor there's no cap), then judges each idea on the **four principles**: vibe-codable (a must: anything else is dropped), people will pay, real pain, and sales cover the build cost (a first year of sales: the build, yearly costs such as hosting (Apple's developer fee isn't counted), each customer's running cost, and whether the app is sold once or by subscription, counting half the AI's customer guess to be cautious, with customers arriving evenly and subscribers leaving; scored on payback and held back by a weak sales channel). Each idea says whether to sell it once or by subscription, and why. The killer score is their average; up to 3 a day are kept and marked **Killer** or **Almost there**, with the score shown out of 5. The idea screen puts the answer first: why it's a killer idea (the four tests), price against competitors, the money (the working behind "Show the sums") and the doubts, then the opportunity, one-week test and evidence, with Improve and Dismiss at the bottom. Without matching evidence, pain and willingness to pay can't score above 3; a 5 needs two different supporting items. "People will pay" passes only with proof (a paid competitor, or posts showing people pay); without it, it shows "No proof yet". A coloured tag shows whether an idea undercuts competitors (blue) or fills a gap (purple), and a line under the competitors says how the price compares with the 25% cap. Ideas found before the principles keep their older score, are marked "older scoring" and rank below new ones.
- **Starter kit:** on an idea, one AI request (cost shown first, counts towards the daily limit) plans the first version: a one-paragraph spec, the screens, the data it stores, a cheap stack for one person with a rough running cost, what to leave out, the first slice with checks, and rules for the coding tool. It's saved on the idea. Pick Claude Code, Cursor, Replit or Lovable and **Copy prompt** (then paste it into the tool) or **Share…**: the kit as a prompt worded for that tool (rewording is free, on the phone; the share sheet includes Copy). Making it again asks first.
- **Reimagine an app:** on the Ideas tab, in steps, each shown as soon as it's ready. **0)** Paste a link to the app (its App Store page via Share → Copy Link, its website or GitHub page) or type its name, plus an optional note on what bugs you about it or who you'd build for (counted as your own pain point). **1) About this app:** Claude's web search (up to 7 searches, never Apple's or Replit's sites) explains what it does, who it's for, its plans, what people like and complain about (and who complains), the alternatives and what solo builders already made, each with its link; with an App Store link, the app's recent 1–2 star reviews are also read from Apple's public review feed (the one the daily App Store source uses; Apple's search and pages are never used). **2) Ways to reimagine it:** up to 4 directions, each a group of people and a job the app serves badly, kept only when at least two different sources back it ("No clear gap found" otherwise); you pick one or write your own. **3) Your idea:** a short web check of that group, then one idea for it with a "Compared with what they use now" list, judged by the devil's advocate, price-checked and capped at 25%. A backed idea is saved, marked "Gap spotted in …"; a rejected one shows why and is saved only if you tap "Save anyway". Research is kept on this device (the last 10 apps), so another direction costs no new research. Claude only; each step's cost is shown first (about $0.13 for steps 1–2 and $0.15 for step 3 with Mixed, upper guides) and counts towards the daily limit.
- **Web price check:** with Claude, each refresh looks up the kept ideas' competitors and cheapest plans on the web (Claude Haiku 5.5 with web search: up to 3 searches per idea, then a cheap call to format the answer; about $0.10 a refresh at most, included in the refresh estimate and the daily limit). A price counts as checked only if its link is a page the search really returned; checked prices show their link, and the 25% price cap is worked out from them. With other providers, or if the check fails, prices stay "unconfirmed" and the refresh carries on.
- **Improve this idea:** on an idea, up to 3 rounds (cost shown first as an upper guide, counts towards the daily limit). Each round the AI rewrites the idea to answer the devil's advocate's strongest objection, then the devil's advocate scores the rewrite. It stops when the score stops rising, reaches the quality bar, the rewrite is rejected, or after 3 rounds. Pain and willingness to pay can't rise above the original's, because a rewrite adds no new evidence. It's reached from the button under the idea's pitch. On iPad at full or wide width, the original and a chosen round are shown side by side, row by row, with changed rows marked "Changed" and the rest "(same)". Every version is shown beside the original, and the one in use is marked **In use**; nothing changes until you tap **Keep this version**, which confirms the score change, and **Undo improvement** puts the original back. If the daily scan proposes the idea again, its new text replaces the kept improvement.
- **History:** one row per day with its best idea and common complaints; tap a day for that day's ideas, common complaints and trends.
- **Saved:** ideas you've bookmarked (bookmark button, or swipe right in Ideas) and projects you've starred, with notes, AI-suggested monetisable variants, and a copyable "flesh out this idea" prompt.
- **Settings:** About me, interest area, your AI coding tool (it decides the app type: Claude Code or Cursor for on-device iPhone/iPad apps, Lovable or Replit for web apps), My pain points and the daily digest time up front; under **Advanced**: sources and topics, scan windows, items the AI reads, quality bar and ranking weights, and AI provider, model, key, costs and daily limit.
- **Refreshing:** pull down on Ideas or History (or tap ↻ in the top bar). Every refresh asks first in a pop-up showing its estimated cost and today's spending, because a refresh costs money and a pull is easy to make by accident.

All output is in English. Non-English items are translated by Claude, or filtered out when Apple's on-device model is used.

## Sources

| Source | What it gives |
|---|---|
| My pain points | Problems you type in Settings, one per line; treated as strong demand evidence |
| App Store complaints | 1–2 star reviews (last 60 days) of 16 business, finance and productivity apps a day, ranked 26–100 in the AU and US top-grossing charts (below the giants, whose complaints are too general); apps whose name or genre mentions your interest area are read first |
| Consumer app complaints | The same for 16 health and fitness, education, food and drink, and travel apps a day (on by default) |
| WordPress plugin complaints | 1–2 star reviews (last 90 days) of 8 popular WordPress.org plugins a day in business tags (shops, bookings, invoices, memberships, CRM, courses, events, donations, inventory, forms), at most 4 per plugin and 30 in all; plugins that mention your interest area are read first. The interest area is matched on your device, not sent |
| Hacker News on your area | Up to 40 recent stories and comments matching your **Interest area**, over the complaints window (on by default; skipped when the interest area is blank). The interest area is the only text of yours sent to a source. From every source, items that mention the interest area's words are read first. The App Store's own search isn't used: Apple's terms limit it to promoting the store |
| AusTender | The 15 largest Australian government IT contracts in the window |
| Atlassian Marketplace *(off by default for new installs)* | Trending and new Jira/Confluence add-ons |
| Pain points | HN comments such as "I wish there was…", "too expensive", "alternative to", plus Ask HN (own window, default 14 days) |
| App Store | Top paid iPhone apps |
| GitHub | New repos with traction, searched by your topics |
| Hacker News | Show HN posts |
| Vibe-code showcases | AI-built apps shared on HN and GitHub |
| AI research | Hugging Face daily papers |
| Hugging Face *(off by default)* | Trending AI Spaces |
| DEV *(off by default)* | #showdev posts |
| Games *(off by default)* | itch.io, Steam, HN, GitHub and Hugging Face game projects |
| Lobsters *(off by default)* | "Show" posts |

Developer and game sources, GitHub, Show HN, AI research and AusTender start switched off: builder-side sources show what's already made rather than what buyers need, and government contracts are out of reach for a solo builder. Atlassian Marketplace starts off on new installs (it shows what enterprise teams buy, which is rarely a solo builder's market); if you'd already set the app up, your choice is kept. Turn any of them back on in Settings. Vibe-code showcases, the App Store and the complaint sources stay on, and the AI treats what other builders have made as competition, not inspiration.

Sources are grouped as **demand** (complaints, your challenges, government spending), **supply** (things being built) and **timing** (new startups and research). Claude reads about 40% demand, 40% supply and 20% timing, with unused share going to demand first. Claude also groups demand items into **pain clusters** (one problem, one buyer) that the idea step must draw on, and flags noise so it's left out of "Other projects".

## AI summarisers

- **Cloud AI** (choose one in Settings → Advanced → AI & costs, each with its own API key in the Keychain and a recommended model preselected): Claude ("Mixed" default: Haiku 5.5 reads the day's items, Sonnet 5.5 writes ideas, Opus 5.5 is the devil's advocate; or one model for everything: Sonnet 5.5, Haiku 5.5, Opus 5.5, Fable 5.2), ChatGPT (GPT-6.1 Sol, GPT-6 Astra), Gemini (4 Argon, Gemma 4 31B), Grok 4.3, DeepSeek V4.1, Qwen 3.8 Max, GLM-5.3, Kimi K3, MiMo-V2.6-Pro, or any other model name with its own price. Claude talks to Anthropic's API; the others use one OpenAI-compatible client. Reads up to 300 projects per refresh (configurable: 100–500) and powers the killer ideas and the devil's advocate. A full refresh at 300 items costs about $0.20–0.25 with Claude Sonnet 5.5 (about $0.40–0.45 with Opus 5.5). Costs are tracked per model, and a daily limit (default $1.00; choose $1, $2, $3, $5, $10 or no limit) applies to every provider. If the chosen provider isn't set up, the app uses Apple's on-device AI, never another paid provider.
- **Apple Intelligence**: on-device and free, but reads only about 20 projects and can't generate killer ideas.
- **Keyword grouping**: the fallback when no AI is available.

## Free, tips and privacy

- **Free**, with no trial, unlock or locked features (owner, 15 and 17 Nov 2026). An optional **"Shout me a coffee"** section at the bottom of Settings offers three consumable tips (StoreKit 2): small coffee, large coffee, coffee and cake. They unlock nothing, and the section hides itself when Apple can't supply the products. `IdeaScout/IdeaScout.storekit` lets the tips be tested from Xcode without real money.
- A **welcome flow** on first launch (what the app does, your interest area and coding tool, and guided AI key setup with a Paste button and a plain warning if you finish without a key), and a **consent screen** before any data goes to a cloud AI (asked per provider, withdrawable in Settings).
- **About & privacy** screen with data-source credits; `PrivacyInfo.xcprivacy` privacy manifest; export-compliance flag set.
- The privacy policy is [`PRIVACY.md`](PRIVACY.md); App Store screenshots are in `store/screenshots/`.

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

Set your own signing team in `project.yml` (`DEVELOPMENT_TEAM`) if you aren't the original author, then build to a device. Running from Xcode uses `IdeaScout/IdeaScout.storekit`, so the tips can be tested without real purchases. Without it (or before the products exist in App Store Connect) the Support section simply doesn't appear.

## Tests

Swift Testing tests in `IdeaScoutTests/` (shared stand-ins in `TestSupport.swift`; no network calls; samples of each source and AI reply format). They cover source parsing, theme building and ranking, the Claude and OpenAI-style request and reply handling, streaming and retries, the killer-idea rules and evidence caps, costs and the daily limit, digest replacement rules, the English filter, scan settings, business-focus rules, demand sources, signal-based selection, pain clusters, saving ideas, consent, Reimagine, the tips and the 25% price cap.

**Screen (UI) tests** in `IdeaScoutUITests/` are kept to three, run before a release: first launch with consent; the main action (a refresh, the idea's principles and 25% price cap, and the "ask before a second refresh" rule); and "Delete all my data". Other screens are checked by hand from the release list. They run the app in a sealed test mode (`IdeaScout/Support/TestMode.swift`, active only in Debug builds) with an in-memory database, a separate settings store and Keychain area, fake sources and a scripted AI, so they never touch real data, the network or AI costs. Keep the device unlocked while they run.

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
  Store/      TipStore (optional "Shout me a coffee" tips)
  Support/    AppSettings (+Costs: cost estimates), Keychain, UsageTracker (costs), Persistence (saving with error reporting),
              SecureClipboard (local-only, expiring copies), TestMode (sealed UI-test mode, active only
              in Debug builds). Notifier (the "ideas are ready" notification) is in AppSettings.swift
  Views/      SwiftUI screens: tabs, Ideas, day view, Saved, Settings, welcome/consent, Support, About
  PrivacyInfo.xcprivacy, IdeaScout.storekit (test only, not shipped)
IdeaScoutTests/    Unit tests (Swift Testing)
IdeaScoutUITests/  Screen tests (XCUITest)
PRIVACY.md    The privacy policy
store/        App Store screenshots
project.yml   XcodeGen project definition
ARCHITECTURE.md  How the app fits together
SECURITY.md   What data is held, how it's protected, remaining risks
```

## Status and open items

Version 1.0 is feature-complete and free. All 226 unit tests and the 3 screen tests pass, with no compiler warnings.

Still to do:
- **Before App Store release (owner):** create the three coffee tips in App Store Connect; archive, TestFlight and submit.
- **Reddit** as a source, once Reddit approves API access.
- **Model list upkeep:** a future admin routine to update providers, models and prices automatically (today they're hand-maintained in `AI/AIProviders.swift`).
- **Code quality backlog:** split the seven files over 300 lines; Swift 6 strict concurrency; typed JSON schemas for AI replies. The killer-idea leaderboard loads every saved idea to rank it, because its score is calculated rather than stored; that's fast at today's volumes (a few ideas a day), and storing the score would add a new database field.

## Licence

© 2026 Mahoneyclan. This is free software, released under the [GNU General Public License v3.0](LICENSE)
(GPL-3.0). You may share and change it under that licence; it comes with no warranty.
