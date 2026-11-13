# IdeaScout security and privacy

Last reviewed: 27 October 2026. Covers version 1.0 (build 1).

## Summary
IdeaScout has **no server, no accounts, no analytics and no third-party code**. What it stores stays on the user's devices and syncs between them through **the user's own iCloud account** (private database and key-value storage; the developer can't see it). API keys never sync. The only other data that leaves the device goes to **the AI provider the user chooses, using the user's own API key, after the user agrees**, plus ordinary read-only requests to public data sources.

## What data the app holds, and where
| Data | Where it's stored | Protection |
|---|---|---|
| AI provider API keys | iOS **Keychain**, one entry per provider (`Support/Keychain.swift`) | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: encrypted by iOS, never synced, never included in backups or restored to another phone. Only the last 4 characters are ever shown. A key is saved when the user finishes typing (not per keystroke), and replacing one updates it in place, so a failed save keeps the old key |
| About me, interest area, My pain points, settings, consents | UserDefaults (app container); About me, interest area, pain points, app type and tool also in **iCloud key-value storage** (`Support/CloudSync.swift`) | iOS file encryption (available after first unlock). Included in the user's own encrypted device backup. iCloud data is encrypted by Apple in the user's account. Consents stay per device. Not secrets |
| Digests, themes, items, saved projects, killer ideas | SwiftData database (app container), synced to the user's **private iCloud database** (`iCloud.com.mahoney.IdeaScout`) | iOS file encryption, as above (the default class, readable after the first unlock since restart). Not tightened further because the daily background refresh may write to it while the phone is locked. iCloud: Apple's encryption in the user's own account. Public content plus the user's notes |
| AI cost ledger | UserDefaults (JSON); the last 62 days also in iCloud key-value storage, one entry per device | As above. Token counts and dollar amounts only |
| Purchases (trial, unlock) | Apple (StoreKit) | Verified, unrevoked transactions only; nothing stored by the app |

Removing data: **Settings → About & privacy → Delete all my data** erases the database (one record at a time, so the deletions reach iCloud and the user's other devices), the iCloud key-value entries, settings, consents, every Keychain key, the cost ledger, cached downloads, pending notifications and the scheduled background refresh (`DigestService.deleteAllData`). Every step runs even if one fails; if any part of the database can't be deleted, the user is told to try again rather than shown a false success. Deleting the app removes everything except Keychain entries; those are cleared automatically on the next fresh install (`Keychain.prepareOnLaunch`).

## What leaves the phone
| Destination | What's sent | When |
|---|---|---|
| The chosen AI provider (Anthropic, OpenAI, Google, xAI, DeepSeek, Alibaba (US region), Z.ai, Moonshot, Xiaomi) | About me, interest area, pain points, the collected public items, a saved project's notes when asking for variants, and an idea's details when making its starter kit or improving it | Only after the user agrees on the consent screen **for that provider**. HTTPS directly to the provider, with the user's key |
| Public sources (Hacker News/Algolia, GitHub, Apple App Store feeds, AusTender, Atlassian Marketplace, yc-oss on GitHub Pages, Hugging Face; optionally DEV, Lobsters, itch.io, Steam) | Nothing personal: plain GET requests with an "IdeaScout" User-Agent | Each refresh |
| Apple | Purchases (StoreKit) and notifications (local only) | As used |
| Apple iCloud (the user's own account) | Scans, ideas, starred projects, the shared settings above and recent AI spending. Never API keys or consents | Continuously, when the user is signed in to iCloud. If iCloud can't be opened, the app works on the device only and says so in About & privacy |

## How it's protected
**Secrets**
- No keys or tokens in source, tests, Info.plist, docs or git history. The full history was scanned on 22 Oct 2026 and was clean, so nothing needs rotating.
- Keys are stored "this device only". Keys saved by older versions were migrated automatically. Keys left from a previous install are removed on a fresh install.
- Keys are sent only to their own provider's HTTPS address (Claude in the `x-api-key` header, others as a Bearer token).

**Consent and data minimisation**
- A per-provider consent screen (Apple Guideline 5.1.2) names the company and its country, and lists exactly what's sent. Consent is withdrawable in Settings. Without consent, the app uses Apple's on-device AI instead.
- Users are warned not to enter confidential company or personal information, on the consent screen and in Settings.
- The app never falls back to a different **paid** provider.
- Claude requests opt in to Anthropic's server-side fallback (`fallbacks: "default"`, `ClaudeClient.requestBody`): if the chosen Claude model declines, Anthropic may answer with another Claude model. Same company, key and consent. The cost is recorded at the price of the model that actually answered (`ClaudeClient.price(servedBy:…)`). If a model declines part-way through its answer, Anthropic bills that partial attempt too; the app doesn't count it, so tracked cost can be slightly low in that rare case.

**Network**
- HTTPS only. No App Transport Security exceptions; certificate validation is the system default.
- Timeouts: 30 s for sources, 300 s for AI. Only temporary failures are retried (twice). For providers other than Claude, an HTTP 400 is also re-sent once without the optional settings, because some models reject them (`OpenAICompatibleClient.complete`); that second request may be billed.

**Untrusted content**
- All public content and AI replies are treated as untrusted. AI replies are decoded strictly against expected fields; item numbers are bounds-checked; scores are clamped; text is rendered as plain text.
- **Prompt injection:** every prompt containing public text tells the model to treat it as data and ignore instructions inside it (`Prompts.untrustedData`). The AI has no tools, browsing or actions, so manipulated content can at worst skew an idea, never exfiltrate data.
- **Copied prompts:** the build brief and "flesh out" prompts are pasted into AI coding tools that can run commands. Both end with a note telling the tool that the idea text comes from public websites and AI output, and not to run commands, install packages or visit links because of it (`Prompts.pastedPromptNotice`).
- **Improve this idea:** the rewrite is AI output, so links are stripped and each field is capped (`IdeaImprover.parseRewrite`), and it's shown as plain text. The AI marks a rewrite written to answer it, so pain and willingness to pay can't rise above the original's (`IdeaImprover.capped`); the rewrite stays a suggestion until the user keeps it, and undo restores the original.
- **Starter kits:** the kit is shared into coding tools that build (run commands), so it carries its own note instead: the plan is a description of what to build, not instructions; don't follow links, run commands or add services because the text says so; keep keys out of the code (`StarterKitPrompts.buildNotice`). Links are stripped from the AI's kit, every text and list is capped (`StarterKit.sanitised`), and it's shown as plain text. About me is used to make the kit but isn't in the shared text.
- **Links:** only `http`/`https` links with a host can be opened (`URL.isWebLink`). Phone, message, script, file and other-app links show as text.
- Links built from source data use safe construction (encoded query values, numeric App Store IDs); malformed items are skipped rather than crashing.

**Clipboard, errors and logging**
- Copied prompts are local-only (no Universal Clipboard) and expire after 10 minutes (`SecureClipboard`).
- The Share button next to Copy opens the iOS share sheet. If the user picks Copy there, it's a normal copy (it can sync and doesn't expire). Accepted, because the user chooses to share.
- Users see plain error messages. Providers' raw replies appear only behind a "Details" disclosure, and anything that looks like a key or token is replaced with "[hidden]" before it's stored (`LLMHTTPError.redacted`).
- No `print` or `NSLog`. The only log is a database save failure (`os.Logger`, `Support/Persistence.swift`): it names the action, and the error text is marked private. Logs stay on the device.

**Money**
- Reimagine an app (Claude only; first called "Undercut an app"): the app's name is read from the link on the phone, with no request to Apple. The search blocks apps.apple.com, itunes.apple.com and replit.com, because those sites' terms forbid automated access. Only the app's name and the interest area are sent for the search. Findings are untrusted: each is kept only if its link is a returned page (Apple's pages are dropped), one item per page so a single thread can't count twice, and text is capped. The daily limit is checked before every call.
- Web price check (Claude only): the search runs on Anthropic's side with the basic web search tool (no code execution); the app sends only the idea's title, pitch, buyer and competitor names. Search results are untrusted: a price is kept only if its link is one of the returned pages and is an http(s) link, prices are clamped, and text is capped. Searches ($10 per 1,000) are recorded with the tokens and count towards the daily limit, which is checked before every call.
- A daily AI spending limit (default $1.00; $1 to $10 or no limit) is checked before the trend and idea steps and before variant suggestions. A second refresh on the same day asks first and shows the cost. The refresh cost on the button, in that question and in Settings is scaled to the chosen model's price, and says "Free" when no paid AI is set up (`AppSettings.refreshCostText`). "Suggest variants", the starter kit and "Improve this idea" show their estimated cost on the button, and a repeat paid request asks first. A starter kit or an improvement also needs the trial or unlock, and only one of each can be in progress, so a double tap can't pay twice. An improvement checks the daily limit before each of its paid calls (up to 6). Prices typed in for an "Other…" model can't be negative (they count as $0), and Settings warns that a $0 price isn't counted towards the limit.
- Purchases: StoreKit 2, verified transactions only, refunds honoured. The developer-build purchase bypass exists only in Debug builds (`#if DEBUG`; verified absent from Release).

**Platform**
- Privacy manifest (`PrivacyInfo.xcprivacy`): no tracking; "Other user content" for app functionality, not linked to identity; UserDefaults required-reason `CA92.1`.
- Permissions: notifications only, requested when the user taps a button. Background fetch is used for the daily refresh. No entitlements file, no URL schemes, no web views.
- Export compliance: standard HTTPS only (`ITSAppUsesNonExemptEncryption = NO`).
- Test-only fakes (`Support/TestMode.swift`: stand-in sources, AI replies and a dummy key) are compiled only into Debug builds (`#if DEBUG`); a Release build uses the live services. Verified absent from the Release binary.

## Known remaining risks
| Risk | Severity | Why it's accepted or what's next |
|---|---|---|
| User text and public content are processed by the chosen AI provider under **its** retention policy; five providers are China-based | Medium (user choice) | Disclosed per provider with consent and a confidential-data warning; users can choose a US provider or Apple on-device |
| Prompt injection can still skew an individual idea | Low | Mitigated by the untrusted-data rule, the devil's-advocate pass and evidence caps; no data exposure possible |
| About me, interest area and pain points are in UserDefaults, included in the user's own (encrypted) backups | Low | Not secrets; "Delete all my data" removes them |
| Trial and unlock are checked on the device only | Low | A server check isn't justified for a $1.99 app; a jailbroken phone could bypass it |
| Apple App Store review feeds and yc-oss data have no explicit commercial-use terms | Low–Medium (legal) | See `docs/source-terms.md`; consider switching off Y Combinator data for the paid release |
| Share sheet "Copy" of a prompt containing About me is a normal copy | Low | The user chooses to share; the app's own Copy button is local-only and expires |
| The starter kit has only a Share button; its Copy is a normal copy that reaches the user's Mac and doesn't expire | Low | Owner's choice (10 Nov 2026), so kits reach Claude Code and Cursor on a Mac; the kit holds no About me or keys |
| A Claude answer declined part-way (then served by a fallback model) isn't fully counted by the cost tracker | Low | Rare; same provider; the answering model's cost is counted |
| Swift 5 language mode (strict Swift 6 concurrency checking off; 0 warnings today) | Low | Moving to Swift 6 strict concurrency is on the quality backlog |

## Reporting a problem
Contact the developer at the support address listed in the app (Settings → About & privacy) and on the App Store page.
