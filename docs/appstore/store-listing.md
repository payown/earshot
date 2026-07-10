# App Store listing — Earshot

Status: DRAFT for Michael's review (issue #644). Not final until Michael signs off.

Every feature claim below was verified against the shipped SwiftUI code in
`EarshotSwift/Earshot/` before being included. See "Verification notes" at the
bottom for what was kept, cut, or reworded and why. Character counts are for
Apple's field limits and were measured, not estimated.

---

## Subtitle (30 char max)

**The accessible podcast player** — 29 characters

---

## Description

Earshot is a podcast player built accessibility-first. Every screen, button, and gesture works fully with VoiceOver, so blind and low vision listeners get the same fast, complete experience as everyone else.

Listen your way:
- Follow any podcast by search, RSS feed URL, or OPML import
- A Smart Inbox that gathers new episodes from the shows you choose
- Queue with reordering, grouping by podcast, and auto-advance
- Per-podcast playback speed that remembers your preference
- Chapter support with a chapter list and previous/next navigation
- Sleep timer for winding down
- Bookmarks to save a spot and jump back later
- Transcripts when a podcast provides them
- Auto-download recent episodes so they're ready offline
- Adjustable skip-forward and skip-back intervals
- Listening stats to see how much you've listened

Organize a big library:
- Folders to group your shows
- Mark all as played, plus multi-select to clear things out fast
- Resume right where you left off on every episode
- Import your subscriptions with OPML, and export them any time

Built for VoiceOver from day one:
- Configurable Quick Actions that populate the VoiceOver rotor, so your most-used actions are one flick away
- Clear, consistent labels on every control
- Full Dynamic Type support and respect for your system settings
- No unlabeled buttons, no inaccessible screens

Earshot is free for up to 10 podcast subscriptions. Earshot Plus removes the cap for unlimited subscriptions: $2.99/month, $19.99/year, or $49.99 once for lifetime access. An optional in-app tip jar is there if you'd like to support development. No ads, no third-party trackers, ever.

Earshot is developed by a blind podcaster and assistive technology specialist who uses it every day. Feedback from the blind community shapes every release.

---

## Keywords (100 char max)

```
voiceover,blind,low vision,screen reader,rss,opml,chapters,queue,sleep timer,bookmarks,offline,feeds
```

100 characters. No spaces after commas. Does not repeat "Earshot" (app name)
or "accessible" / "podcast" / "player" (all in the subtitle), since Apple
indexes the name and subtitle separately and repeating them would waste slots.

---

## Promotional text (170 char max)

Earshot is here: a podcast player built VoiceOver-first and shaped by the blind community. Follow, queue, and listen your way. Free for up to 10 shows.

151 characters. (Updatable without app review — swap for timely launch or
event messaging any time.)

---

## Verification notes

Each claim was checked against `EarshotSwift/Earshot/` on the `swift` branch.

### Kept (verified present with real user-facing UI)
- **Search, RSS URL, OPML import** — `Features/Search/`, `AddFeedView.swift`, `AddPodcastView.swift`, `OPMLImportService.swift`. All three add paths ship.
- **OPML export** — added to the copy; `DataSettingsView.swift` "Export podcasts (OPML)". The draft only mentioned import.
- **Queue reorder / group-by-podcast / auto-advance** — `QueueScreen.swift` (`.onMove` + rotor move actions), `PlaybackSettingsView.swift` toggles.
- **Per-podcast playback speed (setter UI)** — VERIFIED as a real, persistent setter, not just a data field. `PodcastSettingsView.swift` `speedPicker` → `podcast.speedOverride`, with a "Use global" option, separate from the global speed control. The old memory note ("no setter UI yet, deferred F7") is stale; the UI shipped. Claim kept.
- **Chapters** — `ChapterService.swift` / `ID3ChapterParser.swift` (parsing) plus `ChapterListView.swift` and prev/next chapter controls in `NowPlayingScreen.swift`. Reworded to name the chapter list and prev/next navigation.
- **Sleep timer** — `PlayerControlsSheet.swift`, `NowPlayingBar.swift`.
- **Auto-download recent episodes** — `DownloadsSettingsView.swift` "Auto-download recent" + `SubscriptionRepository.autoDownloadRecent`. (Shipped via #639.) Reworded to "recent episodes … ready offline" to match what the setting actually does.
- **Custom VoiceOver rotor actions** — `.accessibilityActions` on `EpisodeRow.swift`, `QueueScreen.swift`, etc., driven by the Quick Actions order.

### Cut or reworded (draft claim the code does NOT support)
- **"Home Screen Quick Actions for one-tap access" — CUT as written.** There is NO iOS Home Screen quick action in the app: no `UIApplicationShortcutItem`, no `UIApplicationShortcutItems` in Info.plist, no `shortcutItems` handling anywhere. Long-pressing the app icon does not surface Earshot actions. The draft conflated this with Earshot's in-app "Quick Actions," which is a completely different feature: a configurator (`QuickActionsSettingsView.swift`) that sets the order of the per-row actions feeding the **VoiceOver rotor**. I reworded the claim to describe that real feature honestly. Apple reviewers test icon long-press for this exact claim, so shipping the original wording risked rejection.

### Added (verified shipped, missing from the draft)
- **Inbox** — `Features/Inbox/`, `InboxScreen.swift`, per-podcast opt-in/opt-out and count/age caps in `PodcastSettingsView.swift`.
- **Bookmarks** — `Features/Bookmarks/BookmarksListView.swift`.
- **Transcripts** — `Features/Transcripts/TranscriptView.swift`. Worded conditionally ("when a podcast provides them") because availability depends on the feed.
- **Folders** — `Features/Folders/FoldersScreen.swift`, `FolderDetailScreen.swift`.
- **Mark all as played + multi-select** — `EpisodeListView.swift` (mark all, with confirm), `InboxScreen.swift` (multi-select bulk add to queue).
- **Listening stats** — `Features/Stats/StatsScreen.swift`.
- **Resume playback position** — `PlaybackLogic.swift` resume logic + `Episode.positionSeconds`.
- **Adjustable skip intervals** — `PlaybackSettingsView.swift` skip-forward / skip-back pickers.
- **Offline/downloaded playback** — `PlaybackLogic.swift` plays the on-disk file when present, otherwise streams; `Features/Downloads/`.

### Earshot Plus disclosure (required by Apple + Michael)
- Free tier = up to 10 subscriptions, enforced in code: `PodcastCapPolicy.freeTierLimit = 10`, `SubscriptionRepository` throws `podcastCapReached`.
- Prices verified against `Features/Monetization/Domain/EarshotPlusProduct.swift`: `plusMonthly` $2.99/month, `plusYearly` $19.99/year, `plusLifetime` $49.99 one-time. These match the A1-locked pricing in issue #644. (Note: the global CLAUDE.md rule 5 still reads "$20/year, $49 one-time" — that copy is stale; the code and this listing use $19.99 / $49.99. Flagging so CLAUDE.md can be corrected separately.)
- Tip jar is a real consumable IAP (`TipJarView.swift`, presets $1.99 / $4.99 / $9.99), disclosed low-key as optional.

### Subtitle decision
- Kept Michael's "The accessible podcast player" (29 chars). It's a clear brand
  statement and puts the high-value tokens "accessible," "podcast," "player"
  in the separately-indexed subtitle slot, which is why those three words are
  deliberately absent from the keyword field. Alternative considered:
  "VoiceOver-first podcast player" (30 chars) would move "voiceover" into the
  subtitle and free a keyword slot, but "accessible" reads better as broad
  positioning. Either is defensible; leaving the call to Michael.

### Not claimed (deliberately left out)
- iOS Home Screen quick actions (do not exist — see Cut section).
- Siri Shortcuts, widgets, Dynamic Island, Spotlight indexing, CarPlay — none
  found in code; not claimed. (Candidates for future feature-suggestion issues.)
- "accessibility" as a keyword — omitted because it shares a stem with
  "accessible" (in the subtitle) and would likely be treated as a duplicate.
