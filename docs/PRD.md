# Earshot Product Requirements Document

**Document version:** 1.0
**Last updated:** May 17, 2026
**Owner:** Michael Babcock, Payown Media LLC
**Status:** Draft, pre-development

---

## 1. Executive summary

Earshot is a power-user podcast player built fully accessible from day one. It targets iOS first, then Android, with Flutter as the cross-platform framework. The app is free, open source, and positioned as a community contribution from Payown Media with acknowledgement of BITS (Blind Information Technology Solutions) and the American Council of the Blind (ACB).

Earshot is differentiated by three things: user-configurable Quick Actions on every content type, per-podcast queue expiration with a Recently Expired safety net, and a comprehensive listening stats package including time saved from silence trimming and speed adjustments.

The launch goal is 1,000 downloads across iOS and Android combined, at which point v1.1 development (cloud sync) begins.

---

## 2. Mission and positioning

**Mission:** Make the best possible podcast listening experience for screen reader users, and in doing so, make the best possible podcast player for everyone.

**Positioning statement:** Earshot is a podcast player that treats accessibility as a baseline, not an afterthought. It is built by an assistive technology specialist for the community he serves.

**Brand voice:** Direct, conversational, friendly, never corporate. No "instrumental," "crucial," "game changer," "mastering," or "fulfilling." Contractions are fine. First person where appropriate.

**Tagline candidates (final pick during marketing prep):**
- "Earshot. Podcasts, the way you listen."
- "A podcast player built for the way you listen."
- "Earshot. Accessible by design."

---

## 3. Audience

**Primary users:**
- Blind and low-vision listeners who rely on VoiceOver (iOS) or TalkBack (Android)
- Power users who consume many hours of podcasts weekly
- Members of the BITS and ACB communities

**Secondary users:**
- Sighted users who value privacy, customization, and a clean experience
- Accessibility professionals, educators, and trainers

**Not the target:**
- Casual listeners who want algorithmic recommendations
- Video podcast watchers
- Audiobook listeners (Earshot focuses on podcasts)

---

## 4. Platforms and tech stack

### Platforms

- **iOS:** Launch platform. iOS 16+ minimum target.
- **Android:** Second platform, shipped within 6 months of iOS launch. Android 10 (API 29)+ minimum target.
- **Web:** Not in scope for v1 or v1.1. May be revisited later.

### Tech stack

- **Framework:** Flutter (latest stable; currently Flutter 3.41.x)
- **Language:** Dart
- **State management:** Riverpod (chosen for testability and Flutter team's adoption)
- **Audio engine:** `just_audio` package + `audio_service` for background playback
- **Local storage:** SQLite via `drift` package (typed, queryable, supports migrations)
- **HTTP client:** `dio` package
- **Logging:** `logging` package with structured output
- **DI:** Riverpod providers, no separate DI framework
- **Lints:** `very_good_analysis` for strict static analysis
- **Testing:** Flutter's built-in test framework, plus `mocktail` for mocks

### Why Flutter

- Single codebase, native accessibility on both iOS and Android
- `customSemanticsActions` API maps to VoiceOver actions rotor and TalkBack custom actions
- Dart is one language to learn rather than Swift + Kotlin
- Strong community, ongoing Google investment in accessibility

---

## 5. Core features (v1)

### 5.1 Subscriptions and discovery

- Search **Apple Podcasts** directory (iTunes Search API, no key required)
- Search **Podcast Index** (free API key required, supports Podcasting 2.0 metadata)
- Add podcast by **RSS URL**
- Import subscriptions from **OPML** file
- Export subscriptions to **OPML** file

### 5.2 Content flow

When a user subscribes to a podcast:
- The most recent N episodes auto-download (default 3, configurable globally and per-podcast: 0, 1, 3, 5, 10, all available)
- New episodes auto-download as they publish (Wi-Fi only by default)

When new episodes arrive:
- By default, they land in the **Inbox** for user triage
- If the podcast is marked **"Auto-Queue,"** new episodes bypass Inbox and go straight to Queue

Navigation structure:
- **Inbox:** new, untriaged episodes
- **Queue:** what's playing next
- **Subscriptions:** all podcasts you follow
- **Library:** imported audio (see section 5.8)
- **Downloads:** everything downloaded, including Recently Expired
- **Stats:** listening data
- **Settings:** all configuration

### 5.3 Queue management

- Episodes play in queue order, top to bottom
- User can reorder, remove, move to top/bottom
- **Per-podcast queue age limit:** if an episode sits in the queue longer than a configured number of days, Earshot auto-removes it
- Default: off (no auto-removal)
- Per-podcast setting only (no global age limit)
- Removed episodes move to **Recently Expired** for 7 days, then files are deleted automatically
- User can restore from Recently Expired before 7 days elapse

### 5.4 Quick Actions

Quick Actions are user-reorderable shortcuts available on every content item. They map to VoiceOver actions rotor on iOS and TalkBack custom actions on Android, plus swipe-from-edge gestures for sighted users.

**Episode Quick Actions (user-reorderable):**
- Play now
- Add to queue (top)
- Add to queue (bottom)
- Open show notes
- Download / Remove download
- Mark played / unplayed
- Bookmark current spot
- Share
- Delete

**Podcast Quick Actions (user-reorderable):**
- Open podcast detail
- Toggle notifications
- Toggle auto-queue
- Unsubscribe
- Change download count
- Change queue age limit
- Edit per-podcast speed
- Share podcast

**Queue item Quick Actions (user-reorderable):**
- Play now
- Remove from queue
- Move to top
- Move to bottom
- Move up
- Move down
- Open show notes

The **first action** in the user's configured list is the default action (plain double-tap or single click).

### 5.5 Playback

- **Speed range:** 0.5x to 5.0x in 0.1x increments
- **Per-podcast speed memory**
- **Skip controls:** default 30s forward, 15s back, user-configurable
- **Sleep timer:** end of episode, 5, 10, 15, 30, 45, 60 minutes. Always-visible "Extend +5 min" button while running. No shake gesture.
- **Chapter support:**
  - Podcasting 2.0 chapters (from RSS feed)
  - ID3 chapters in MP3 files
  - Chapter list view with name, start time, duration
  - Tap any chapter to jump
  - Skip forward/back by chapter from playback controls
- **Silence trimming:** toggleable per podcast and globally, time saved counted
- **Volume boost:** per-episode and global
- **Mono audio:** accessibility feature for users with hearing loss in one ear
- **Bookmarks:** mark any timestamp with optional note, share as timestamp link
- **System integration:**
  - Lock screen, Control Center (iOS), media notification (Android)
  - CarPlay
  - Android Auto
  - AirPlay
- **Bluetooth/headphone handling:**
  - Resume after Bluetooth reconnect
  - Pause on headphone unplug
  - Handle phone call and other interruptions correctly

### 5.6 Transcripts

- **v1:** Display transcripts when provided by podcast (Podcasting 2.0 spec, found in RSS)
- Search within provided transcripts
- **v1.2+:** Cloud-based generation for podcasts without provided transcripts (paid feature)

### 5.7 Search

**Context-aware by default:**
- Search in Queue → searches queue
- Search in Subscriptions → searches subscribed podcasts
- Search in Downloads → searches downloaded episodes
- Search in Inbox → searches inbox
- Search in a podcast's episode list → searches that podcast's episodes

**Search Everywhere button:**
- Always available below the search field
- Expands scope to: all podcasts (subscribed and via directory search), all episodes, all transcripts, all bookmarks
- Results grouped by type with clear section headers

### 5.8 Local audio import

Users can import MP3 and other audio files directly into Earshot.

**Supported formats:** MP3, M4A/AAC (priority), plus WAV, OGG/OPUS, FLAC.

**Sources (iOS):**
- iOS Files app share sheet
- Drag-and-drop on iPad (free via Files integration)
- Designated **iCloud Drive folder** (`iCloud Drive/Earshot/Imports`) auto-watched for new files
- Universal "Open In" support from any app that exposes audio files

**Sources (Android):**
- System file picker / Share sheet
- Designated folder via Storage Access Framework (user picks Drive, Dropbox, Nextcloud, OneDrive, or local Downloads)

**Behavior:**
- Imported audio lives in **Library** section
- Treated as a synthetic "podcast" so all Quick Actions, queue, stats, bookmarks, speed memory work identically
- ID3 metadata read automatically
- Filename used if metadata missing
- User can edit title, artist, notes per imported file
- User can organize into folders/collections

**v1.1 evolution:**
- Web upload at earshot.payown.media (drag-and-drop in browser)
- Imported audio syncs to all user devices via Earshot Cloud

### 5.9 Stats

**Core stats:**
- Total time listened (all-time, this week, this month, this year)
- Time saved by silence trimming
- Time saved by speed adjustments (vs. 1.0x baseline)

**Additional stats:**
- Per-podcast breakdowns
- Streaks and patterns (opt-in, off by default)
- Episodes completed counter
- Year-in-review summary
- Export stats as CSV

**Accessibility requirements:**
- All stats readable as plain text
- Numbers spoken naturally ("three hours, forty-seven minutes")
- Charts (if present) have a text-equivalent as primary representation

### 5.10 Notifications

**Defaults:** all optional notifications **off**.

**Per-podcast notification toggle:**
- Each subscribed podcast has a "Notify on new episodes" toggle
- Available as a Quick Action on podcast rows
- Also accessible from podcast detail screen
- When on: push notification with action buttons ("Add to queue" / "Play now")

**Never sent:**
- Inbox reminders
- Queue reminders
- Inactivity reminders
- "Download complete" digests

**Always on (system-required):**
- Now-playing lock screen / Control Center / media notification
- Sleep timer warning (in-app audio fade plus on-screen Extend button, no push notification)

### 5.11 Sharing

- Bookmarks and episodes share as **timestamp links**
- Format: `https://earshot.payown.media/episode/{episode_id}?t={seconds}`
- Universal Links (iOS) and App Links (Android) so the link opens directly in Earshot if installed
- Otherwise, a public web page at earshot.payown.media shows episode metadata and a "Get Earshot" link

---

## 6. Onboarding

Seven-screen guided flow. All screens fully accessible. No screen reader detection or branching; same experience for everyone.

### Screen 1: Welcome
- "Welcome to Earshot, a podcast player built for the way you listen."
- Buttons: "Get Started" / "Skip Setup"

### Screen 2: How content flows in Earshot
- Brief explanation: subscribe → download → Inbox → Queue
- Mention auto-queue for favorite shows
- Button: "Next"

### Screen 3: Your Privacy
- Three toggles:
  - Crash reports (default ON)
  - Anonymous usage analytics (default ON)
  - Listening history retention (default 90 days, dropdown for: Don't keep, 30 days, 90 days, 1 year, Keep forever)
- Links: "Read full privacy policy" / "What does Earshot collect?"
- Button: "Continue"

### Screen 4: Quick Actions
- Explanation: shortcuts on episodes and podcasts, user picks order
- "To use a Quick Action, focus on an episode or podcast and swipe up or down."
- Button: "Customize now" (inline configurator) / "Use Defaults"

### Screen 5: Queue expiration
- "Tired of stale news episodes piling up?"
- Explanation: per-podcast freshness limit, episodes auto-move to Recently Expired
- "Daily news show? Set it to 2 days. Weekly long-form? Set it to 2 weeks. Or leave it off entirely."
- Button: "Got it"

### Screen 6: Add your first podcast
- Three options, equal weight: Search / Add by RSS / Import OPML
- Button: "Start Listening" (enabled once user adds one)

### Screen 7: You're all set
- "You can revisit any of these settings any time."
- Button: "Start Listening"

### Contextual tips
- Dismissable, shown once per category, never repeat
- Triggered on first-use moments: first subscribe, first inbox triage, first sleep timer, first speed change, queue grows past 10
- Master toggle in settings: "Show tips when I discover new features" (default on)
- Implemented as non-modal banners; focus stays where user was, announced via polite live region

---

## 7. Visual design

### Guiding principle
Earshot follows the user's system settings by default and never overrides them.

### Themes
- **Light, dark, and high-contrast (auto-detected from system)**
- iOS: respect `UITraitCollection` for light/dark and `UIAccessibilityDarkerSystemColors` / `UIAccessibilityIncreaseContrast` for high-contrast
- Android: respect system day/night mode and high-contrast accessibility settings
- Manual override: Settings → Appearance → "Follow System (default)" / "Light" / "Dark" / "High Contrast Light" / "High Contrast Dark"

### Color
- System-neutral palette with one accent color
- Accent defaults to system accent (iOS) or Material You-derived (Android)
- User override: small set (blue, green, orange, purple, red, system default)
- All text and meaningful UI meets **WCAG AAA** contrast (7:1 normal, 4.5:1 large)
- Interactive elements: min 3:1 against adjacent colors
- High-contrast modes push to 14:1 or higher where possible
- **Color is never the only signal** (played state, downloaded state, error state, selection all use icon + label + color)

### Typography
- **System fonts only** (San Francisco on iOS, Roboto on Android)
- **Full Dynamic Type / font scaling support**, including extra-large accessibility sizes (iOS AX1-AX5)
- Layout adapts: rows grow, controls reflow, nothing clips
- Respect iOS "Bold Text" and Android equivalent

### Iconography
- SF Symbols (iOS) and Material Symbols (Android)
- Small custom set only for Earshot-specific concepts (logo, cloud badge)
- Icons never the only signal for any control

### Motion
- Respect Reduce Motion: instant transitions, no parallax, no springs, no auto-scroll
- Default animations 200-300ms

### Touch targets
- Minimum 44x44 pt (iOS), 48x48 dp (Android)
- Visible icon can be smaller; hit area extends via padding

### Layout density
- Settings option: Comfortable (default) / Compact
- Compact still respects minimum touch targets

### Status announcements
- New episode downloaded, queue changes, playback state, speed changes, sleep timer events all announced via accessibility notifications

---

## 8. Accessibility requirements (non-negotiable)

All features must meet these baselines:

1. **Screen reader compatibility:** Every interactive element has a proper accessibility label, role, and state. Custom Quick Actions are exposed via `customSemanticsActions` on Flutter, mapping to VoiceOver actions rotor and TalkBack custom actions.
2. **Focus management:** Logical focus order matches visual order. Modal dialogs trap focus correctly. Returning from a screen restores focus to the originating element.
3. **Dynamic Type:** All text scales with system font size, including largest accessibility sizes.
4. **Contrast:** WCAG AAA where possible, AA minimum everywhere.
5. **Color independence:** No information conveyed by color alone.
6. **Motion respect:** Reduce Motion setting fully respected.
7. **Touch targets:** Minimum sizes enforced.
8. **Keyboard support:** External keyboard fully usable on iPad and Android, with visible focus indicators.
9. **No accessibility regressions:** Pull requests that introduce regressions are not merged.

---

## 9. Privacy and data handling

### Core principle
Minimum data required for a good experience. User has maximum control. Plain-English explanations throughout.

### Stored locally (essential)
- Subscriptions, queue, playback positions, inbox state, downloads, per-podcast settings, Quick Action configurations, bookmarks, notes

### User-controlled retention
- Listening history: Don't keep / 30 days / 90 days (default) / 1 year / Keep forever
- Always-available "Delete all history" button in privacy settings

### Sent off-device (with user control)

**Crash reports (anonymized):**
- Service: Sentry (privacy-respecting, can self-host)
- Default: ON, opt-out in privacy settings
- Contains: device model, OS version, app version, stack trace, anonymized event breadcrumbs
- Never contains: user identifier, email, podcast names, episode titles

**Anonymous usage analytics:**
- Service: PostHog (privacy-respecting, self-hostable)
- Default: ON, opt-out in privacy settings
- Captures: feature usage counts, aggregate stats, version adoption
- Never captures: subscriptions, episodes played, search queries, bookmark text, names, emails, location

### Never collected
- Advertising IDs (no IDFA, no AAID)
- Third-party tracking SDKs
- Location data
- Microphone, camera, contacts
- Other apps' data

### Transparency
- Privacy policy at earshot.payown.media/privacy
- Plain-English summary in app: Settings → Privacy → "What does Earshot collect?"
- App Store Privacy Nutrition Label and Google Play Data Safety form: clean disclosures
- Export user data button: JSON export of listening history, bookmarks, subscriptions
- Delete all local data button: factory reset with strong confirmation

---

## 10. Business model

### v1 launch
**Completely free, no monetization.**
- No ads
- No donation prompts
- No tip jar
- No upgrade nags
- No in-app purchases
- Marketing position: "Earshot is free because accessibility shouldn't have a price tag."

### v1.1 (sync release)
- Still free
- Optional **"Support Earshot"** link in Settings → About that opens browser to earshot.payown.media/support
- Web page offers GitHub Sponsors, Ko-fi, or similar external donation methods
- **No donation flow inside the app** (Apple and Google policy compliance)
- Copy: "Support development" (never "Purchase features" or "Unlock premium")

### v1.2+ (transcript generation)
- Paid feature: cloud transcript generation
- Pay-per-use credits or monthly subscription
- Processed through Apple In-App Purchase (iOS) and Google Play Billing (Android) as required by both stores
- Free tier keeps everything that's free today
- API cost (Whisper/Deepgram) passed through with small margin

### Platform compliance research summary

**Apple App Store:**
- Apps that collect funds for charities/fundraisers must be free and collect funds outside the app via Safari or SMS, unless an approved nonprofit (3.2.2 iv)
- Tip jars for developers sit in murky territory; some approved, some rejected
- External donation links via browser are allowed when clearly labeled as supporting development, not buying app functionality

**Google Play:**
- Does not support in-app charitable donations as a built-in mechanism
- In-app billing not permitted for donations
- External links to donation platforms require policy-careful implementation

**Bottom line:** External web link to support page in v1.1+. No in-app donation flow ever (unless Payown Media becomes an approved nonprofit, which it won't as a for-profit LLC).

### Legal structure
- Earshot is a Payown Media LLC project
- Any future revenue is to Payown Media, not personal
- Open source ownership: Payown Media holds the copyright on the original Earshot code

---

## 11. Open source

- **License: MIT**
- **Repository:** github.com/payownmedia/earshot
- **Public from day one** of development (not after launch)

### Repository includes
- LICENSE (MIT)
- README.md with mission, build instructions, accessibility statement
- CONTRIBUTING.md with code of conduct, PR guidelines, accessibility requirements
- CODE_OF_CONDUCT.md (Contributor Covenant)
- SECURITY.md with vulnerability reporting process
- Issue templates: bug, accessibility issue, feature request
- PR template with accessibility checklist
- GitHub Actions CI: lint, test, build for iOS and Android

### What stays closed
- Earshot Cloud backend code (v1.1)
- Signing keys, API keys, secrets
- App Store / Play Store assets are mirrored in repo but the stores are the source of truth

### Contributing rules
- Accessibility is non-negotiable; PRs introducing regressions are rejected
- All new UI requires accessibility labels and screen reader testing notes
- All new features require a CHANGELOG entry

---

## 12. Beta testing plan

### Phase 1: Private alpha
- 20-50 hand-picked testers
- Sourced from: BITS members, ACB Community Builder power users, Technically Working and Our Perspective listeners, CSUN accessibility contacts
- Mix of: heavy/light podcast users, VoiceOver users, TalkBack users, low-vision users, sighted a11y professionals
- 6-8 weeks
- iOS: TestFlight. Android: Google Play Internal Testing.

### Phase 2: Public beta
- TestFlight public link + Google Play Open Testing
- Cap: 1,000 testers initially
- Promoted via: BITS, ACB Community newsletter, Michael's podcasts, Payown Media website
- 4-6 weeks before App Store / Play Store launch

### Feedback structure
- **In-app feedback form:** Settings → Send Feedback. Sends to beta@payown.media with optional anonymized system info.
- **Discord server** for Earshot beta. Channels: announcements, general-feedback, bugs, accessibility, feature-requests, ios-beta, android-beta.
- **Weekly office hours** (Zoom audio + transcript posted after)
- Commitment: respond to all feedback within 48 hours during beta
- Beta tester credits in About screen with consent

---

## 13. Success metrics

### Launch goal (gates v1.1)
- **1,000 downloads across iOS and Android combined**
- **Or 18 months post-launch**, whichever first, triggers v1.1 decision

### Supporting metrics (tracked, not gates)
- Crash-free session rate (target: 99.5%+)
- App Store rating (target: 4.5+)
- Google Play rating (target: 4.5+)
- Zero critical accessibility bugs open
- Daily and weekly active users
- Average listening time per active user
- Quick Action usage rate and customization rate
- Queue expiration adoption rate
- OPML import/export usage
- Beta-to-launch conversion
- Mentions in BITS, ACB, accessibility communities

---

## 14. Out of scope for v1

The following are **explicitly NOT in v1**:

- **Video podcasts** (audio only)
- **Live podcasts / live streaming**
- **Social features** (comments, friends, in-app sharing to other Earshot users)
- **Audiobook support** (podcasts only)
- **AI summaries** of episodes
- **Smart playlists** (auto-generated "for you" lists)
- **Apple Watch / Wear OS** apps
- **iPad / Android tablet optimized layouts** (use phone layout scaled up)
- **Multi-user / family accounts**
- **Cross-device sync without account** (v1.1 brings sync)
- **Migration from specific competitor apps** beyond OPML
- **Custom user-defined themes** (themes are system-driven)
- **Plugin / extension system**
- **iOS Shortcuts integration** (potential v1.2+)
- **Aggressive background download via push** (standard background fetch only)
- **Chromecast / Sonos / native casting protocols** (AirPlay only)
- **Web app** (potential future)

---

## 15. Roadmap

### v1 (launch)
Everything in this document.

### v1.1 (post-launch, triggered at 1,000 downloads)
- **Earshot Cloud sync** via Supabase backend
  - Subscriptions, queue, progress, settings, history (within retention window)
  - Account portal at earshot.payown.media
  - Web upload for imported audio files
- **gpodder protocol** as alternative sync method
- **Support page** at earshot.payown.media/support with GitHub Sponsors / Ko-fi
- Settings to choose sync method: None / Earshot Cloud / gpodder server

### v1.2+
- **Cloud transcript generation** (paid)
- iOS Shortcuts integration (candidate)
- Apple Watch app (candidate)
- Wear OS app (candidate)

### Long-term considerations (no commitment)
- Web app
- Lifetime purchase or subscription tier with extra features
- Tablet-optimized layouts
- Video podcast support

---

## 16. Phased development plan

See `docs/phases/` for detailed phase-by-phase breakdowns:

- **Phase 0:** Project setup, tooling, CI, repo hygiene
- **Phase 1:** Core data model, RSS parsing, subscription management
- **Phase 2:** Playback engine, queue, basic UI
- **Phase 3:** Accessibility layer, Quick Actions, theme system
- **Phase 4:** Downloads, Inbox, queue expiration, Recently Expired
- **Phase 5:** Stats and year-in-review
- **Phase 6:** Search, OPML, local audio import
- **Phase 7:** Polish, performance, beta build
- **Phase 8:** Private alpha
- **Phase 9:** Public beta
- **Phase 10:** App Store and Play Store launch

---

## 17. Credits and acknowledgements

In-app About screen text:

> Earshot is a Payown Media LLC project.
>
> Built with thanks to the communities that shaped it: BITS (Blind Information Technology Solutions), an affiliate of the American Council of the Blind, and the broader ACB community.
>
> Thank you to every beta tester who helped make Earshot real. [Beta tester names with consent.]
>
> Open source. MIT licensed. Source at github.com/payownmedia/earshot.

---

## 18. Open questions and decisions deferred to development

These are intentionally not decided in the PRD and will be resolved during development:

- Exact backend hosting choice for Earshot Cloud in v1.1 (Supabase free tier vs paid, vs DIY on existing infrastructure)
- Pricing for transcript generation in v1.2+ (per-minute vs subscription, exact rates)
- App icon design
- Final tagline
- Specific copy for store listings
- Whether Discord or Matrix (or both) hosts the community channel post-launch

---

## 19. Glossary

- **Quick Action:** A user-configurable shortcut available on a content item (episode, podcast, queue item). Mapped to VoiceOver actions rotor on iOS and TalkBack custom actions on Android.
- **Inbox:** Untriaged new episodes from non-auto-queue podcasts.
- **Queue:** Episodes in playback order.
- **Recently Expired:** Episodes auto-removed from queue by age limit, recoverable for 7 days before file deletion.
- **Auto-Queue:** Per-podcast setting where new episodes skip Inbox and go straight to Queue.
- **Library:** Section containing imported (non-podcast) audio files.
- **Earshot Cloud:** Optional sync service introduced in v1.1, hosted at earshot.payown.media.
- **gpodder:** Open podcast sync protocol supported as alternative to Earshot Cloud in v1.1.
