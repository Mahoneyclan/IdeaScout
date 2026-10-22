# IdeaScout architecture

A plain-language map of how the app fits together. File names are in `IdeaScout/`.

## What the app does
Once a day (or when the user asks), IdeaScout:
1. reads public sources: complaints, startups, launches, government spending;
2. asks the user's chosen AI to group them into **pain clusters** (problems one type of buyer has) and **trends** (things being built);
3. asks the AI for **business ideas**, then asks it again, as a devil's advocate, to try to kill them;
4. saves what survives and shows it.

There is **no server**. Everything runs on the iPhone; AI calls go directly from the phone to the provider the user chose, with the user's own API key.

## Screens
| Tab / screen | File | What it shows |
|---|---|---|
| **Ideas** (first tab) | `Views/KillerViews.swift` (`LeaderboardView`) | Today's status and progress, killer ideas then near-misses, and the bottom refresh button |
| Idea detail | `KillerViews.swift` (`KillerIdeaDetailView`) | Who pays, price, what it replaces, why now, one-week test, devil's advocate, scores, evidence, plan prompt, save |
| **History** | `Views/RootView.swift` (`HistoryView`) | One row per day with its best idea and pain clusters |
| Day view | `Views/DayView.swift` (`DigestContentView`) | That day's ideas, pain clusters, ranked trends with projects, notes |
| **Saved** | `Views/IdeasView.swift` | Bookmarked ideas, then starred projects (notes, AI variants, prompt) |
| **Settings** | `Views/SettingsView.swift` | About me, My Business Challenges, industry focus, digest time; Advanced: sources, scan and ranking, AI and costs |
| Welcome / consent | `Views/WelcomeView.swift` | First launch: intro, trial, AI choice; consent before data goes to a cloud AI |
| Paywall / About | `Views/StoreViews.swift`, `Views/AboutView.swift` | Trial and unlock; version, privacy, source credits |

## Data model (`Models/Models.swift`, SwiftData)
```
Digest (one per day) ──owns──▶ Theme (trend, pain cluster or "Other projects") ──owns──▶ Item (post, review, contract…)
Idea        – a starred Item, copied so it outlives the digest (Saved projects)
KillerIdea  – an AI business idea that survived the devil's advocate; updated when it comes back on later days
```
- Deleting or replacing a Digest deletes its Themes and their Items (cascade). Idea and KillerIdea are independent and survive.
- A KillerIdea records every day it was proposed (`daysSeen`), so History can show each day's ideas. Dismissing hides it; saving bookmarks it.
- Settings live in UserDefaults (`Support/AppSettings.swift`); API keys live in the Keychain (`Support/Keychain.swift`); the cost ledger is JSON in UserDefaults (`Support/UsageTracker.swift`).

## Services
| Service | File | Role |
|---|---|---|
| `DigestService` | `App/DigestService.swift` | Runs a refresh end to end, saves results, schedules background refreshes |
| Fetchers | `Sources/` (one file per source family; shared helpers in `SourceSupport.swift`) | One per source; keyless public APIs; return `FetchedItem`s |
| `Summarizer` implementations | `AI/LLMSummarizer.swift`, `AI/AppleSummarizer.swift`, `AI/Summarizer.swift` | Cloud AI, Apple on-device, keyword fallback |
| AI clients | `AI/LLMSummarizer.swift` (`ClaudeClient`), `AI/OpenAICompatibleClient.swift` | Claude (streamed) and every other provider; shared retries |
| Provider catalogue | `AI/AIProviders.swift` | Providers, models, prices, countries, API details |
| `KillerEngine` | `AI/KillerEngine.swift` | Idea generation, devil's advocate, evidence caps |
| `StoreManager` | `Store/StoreManager.swift` | Free trial and one-off unlock (StoreKit 2) |
| `UsageTracker` | `Support/UsageTracker.swift` | Cost per call, daily limit |

## How data flows in one refresh
```
Trigger: app opens (once a day), refresh button, or background refresh
   │
   ▼
StoreManager: trial/unlock allows it? ── no ──▶ message, stop
   │
   ▼
Fetch all enabled sources in parallel ──▶ remove duplicates and non-products
   │
   ▼
selectBySignal: up to N items (default 300) — 40% demand, 40% supply, 20% timing
   │
   ▼
AppSettings.makeSummarizer: chosen cloud AI (if key + consent, under the daily limit)
                            else Apple on-device, else keyword grouping
   │
   ▼
Trend step (1 AI call): trends + pain clusters + translations + noise
   │   on failure: keyword grouping; a weaker digest never replaces a better one from earlier today
   ▼
Save the Digest immediately
   │
   ▼
Idea step (cloud AI only, 2 calls): 5 ideas ─▶ devil's advocate ─▶ evidence caps ─▶ up to 3 survivors
   │
   ▼
Merge into KillerIdeas (new, or update returning ones) ─▶ screens update automatically (SwiftData @Query)
```

## Key rules and why
- **Signal shares (40/40/20):** stop developer-heavy sources crowding out evidence of demand.
- **Evidence caps:** pain and willingness to pay can't score above 3 without matching evidence (models score generously).
- **Never a paid fallback:** if the chosen provider isn't usable, the app uses Apple's free AI, never another paid provider.
- **Consent first:** no personal data goes to a cloud provider until the user agrees for that provider.
- **Save early:** trends are saved before the idea step, so a failure or iOS ending the app can't lose them.
- **Daily spending limit:** checked before the trend and idea steps (default $1.00).

## Testing seams
- `DigestService.Dependencies` holds everything a refresh needs from outside (sources, AI, trial state, spending limit, consent, notifications). The app uses `.live`; unit tests pass stand-ins, so the whole refresh runs offline in `RefreshRoutineTests`.
- `TestMode` (Debug builds only) seals the app for UI tests: in-memory database, separate UserDefaults suite (`AppSettings.defaults`, also applied to `@AppStorage` via `.defaultAppStorage`), separate Keychain service, fake sources and a scripted AI.

## Threading
`DigestService` and `StoreManager` are `@MainActor` and `@Observable` (they drive the UI and use the main SwiftData context; views read them with `@Environment`). Network and AI work is `async` and awaited, so the UI stays responsive. Pure helpers that tests call are marked `nonisolated`.
