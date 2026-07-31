# App Store screenshots — capture set and descriptions (#643)

This documents the 6.9-inch iPhone screenshot set for the Earshot 1.0 App Store
submission, and gives a plain-text description of every capture (Michael reviews
by screen reader).

- **How they're produced:** `EarshotSwift/scripts/screenshots/capture.sh`
  (repeatable, deterministic). See `EarshotSwift/scripts/screenshots/README.md`.
- **Device / size:** iPhone 17 Pro Max, 6.9-inch, **1320 × 2868 px** — the
  current App Store Connect reference class for iPhone. Upload as-is.
- **Data:** seeded from Michael's real Pinecast feeds (Technically Working, Our
  Perspective). Provenance and the one synthesized element (the demo episode's
  chapter timestamps) are documented in
  `EarshotSwift/Earshot/App/Screenshots/ScreenshotFixtures.swift`.
- **Status bar:** overridden to the standard 9:41, full battery/signal/Wi-Fi.

Earshot 1.0 targets iPhone only (`TARGETED_DEVICE_FAMILY = 1`), so no iPad
screenshots are required for this version.

## App Store Connect upload order

Upload all six images. Use this order so the three images Apple may show on the
installation sheet communicate the core experience first:

1. `inbox.png`
2. `nowPlaying.png`
3. `library.png`
4. `queue.png`
5. `episodeList.png`
6. `settings.png`

The numbered descriptions below document the capture set's production order;
the App Store Connect order above is the release order.

## Paywall shot deferred

The "Earshot Plus" paywall screen (#643 task 4) is intentionally **not** in this
set. It depends on the A2 paywall feature merging first. Add it to the set once
A2 lands; the capture script already isolates each screen, so it's a one-screen
addition.

---

## The six captures

### 1. `inbox.png` — Inbox
Title bar reads **"Inbox (3)"** with a Select button and a "restore dismissed"
button. A tip banner explains new episodes land here. Three real episodes:
- **No For Right Now** — Our Perspective — 33 min, July 7 2026, Streaming.
- **#169 – Apple's Price Hikes, Smart Glasses, and AI Policy Whiplash** —
  Technically Working — **40 min left** (in progress), June 29 2026, Downloaded.
- **#167 – We're Going to Atlanta** — Technically Working — 49 min, June 15 2026,
  Downloaded.

Tab bar (5 tabs): Inbox (badge 3, selected), Queue (badge 3), Library,
Downloads, Settings. Shows the inbox, mixed streaming/downloaded/in-progress
states, and the unread badges.

### 2. `queue.png` — Queue (grouped by show)
Title "Queue" with an options button and a tip banner about play order and
VoiceOver Move actions. Episodes grouped under show headers:
- **Technically Working**
  - #166 – If You Used a Passkey, Why Are You Asking for a Code? — 46 min,
    Downloaded.
  - #165 – No Excuses Left for Inaccessible Apps — 53 min, Streaming.
- **Our Perspective**
  - Welcome to Our Perspective — 41 min, Downloaded.

Demonstrates the grouped queue layout spanning two shows and the
downloaded/streaming distinction.

### 3. `library.png` — Library
Title "Library" with search, folder, sort, and add buttons. Two subscribed shows
with real cover art:
- **Our Perspective** — Kolby & Michael — 3 episodes.
- **Technically Working** — Michael Babcock & Damashe Thomas — 6 episodes.

### 4. `episodeList.png` — Episode list with states (Technically Working)
Show detail pushed from Library. Real cover art, title **Technically Working**,
author **Michael Babcock & Damashe Thomas**, and the show description. An
**Unheard / All** segmented filter (Unheard selected), a "Play oldest first"
button, and a **"5 unheard episodes"** heading. Episode rows show per-episode
state:
- #170 – Turn the Right Knob, People Hear You — **23 min left** (in progress),
  July 3 2026, Downloaded.
- #169 – Apple's Price Hikes, Smart Glasses, and AI Policy Whiplash —
  **40 min left**, June 29 2026, Downloaded.

Shows the show header, the accessible filter control, and in-progress + download
states.

### 5. `nowPlaying.png` — Now Playing with chapters (Technically Working #170)
Full player sheet. Header "Now Playing" with Close, a controls/sleep/chapters
button, and an episode-actions button. Large real cover art. Title
**#170 – Turn the Right Knob, People Hear You**, show **Technically Working**,
**Downloaded**. A **chapter row** shows the active chapter
**"Getting your levels right so people hear you"** flanked by previous/next
chapter buttons and a chapter-list button. Scrubber at **26:40 / 50:05** (about
halfway). Transport: skip-back, play, skip-forward; a 1x speed control; an
AirPlay route button; "Show notes" begins at the bottom.

> The chapter list on this episode is the one synthesized element in the set:
> its timestamps are authored in the fixture (titles track the episode's real
> segments) so the app's shipped show-notes chapter parser produces a list. The
> chapter feature itself is real.

### 6. `settings.png` — Settings: auto-download
The Downloads settings screen. Heading "Downloads" with two controls:
- **Download on Wi-Fi only** — toggle, on.
- **Auto-download recent** — adjustable value, **3** (VoiceOver flick up/down to
  change).

Tab bar shows Settings selected. Demonstrates the download preferences,
including the accessible adjustable auto-download control.
