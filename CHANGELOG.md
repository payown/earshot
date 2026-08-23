# Changelog

All notable changes to Earshot will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Earshot now provides Skip Forward and Skip Back actions to Siri and the Shortcuts app. The built-in Siri phrases use your configured intervals; in Shortcuts, either leave Seconds empty to use that setting or enter any custom interval from 1 second to 10 minutes, then invoke the shortcut by voice. Siri reports clearly when no episode is loaded. (closes #551)
- Downloads can now notify you when an episode finishes downloading. Turn on “Notify when downloads finish” under Settings > Downloads; it is off by default, uses only an on-device notification, and explains how to enable iOS notification permission if it is unavailable. (closes #453)
- Quick Actions can now be removed and restored, not only reordered. Settings separates Enabled and Available actions for episodes, podcasts, and Queue rows; Add, Remove, and move controls all work without dragging, preserve VoiceOver focus, and keep at least one default action enabled. (closes #834)
- Episode rows now have a separate Remove from Inbox action in their Actions rotor and swipe actions. It dismisses the episode without marking it played, and that independent dismissal synchronizes through private iCloud without a newer feed refresh being lost. (closes #824)
- Playback can optionally close the full player after an episode naturally finishes with no next episode to play. The new default-off setting is under Settings > Playback and does not dismiss for pauses, seeks, interruptions, sleep timers, Stop After This Episode, or queue advancement. (closes #718)
- Inbox and Queue options now include Download All. Earshot confirms the exact count for the current folder and search filter, skips downloads already saved or active, retries failed episodes, and gives one final VoiceOver summary of eligible, started, skipped, and failed items. (closes #835)
- Transcripts can now be exported as UTF-8 Markdown from the transcript viewer or an episode’s configurable Actions rotor. Export preserves timestamps and speaker names from WebVTT, SRT, and Podcasting 2.0 JSON, uses a safe Podcast - Episode filename, and shares through the system sheet. (closes #717)
- Every podcast episode list now has in-place search across titles and full feed descriptions. Search composes with the existing heard filter, sort order, selection mode, and Quick Actions, and VoiceOver announces the count when Search is submitted. (closes #457)
- Earshot’s required test gate now includes a UI integration smoke test that launches an isolated seeded library and verifies accessible Library, Inbox, and Queue navigation in addition to the native unit suite. (closes #388)
- Listening Places can write this iPhone's episode positions and played state to a folder in iCloud Drive, Dropbox, or another Files provider using the open `listening-places/1` format shared with QUILL Cast. Earshot 1.2.0 writes outward only; importing another device's changes is deferred. Readable podcast and episode names are optional and off by default.
- Clearing the Inbox now removes those episodes' downloaded audio when “Delete downloads when done” is enabled, without marking the episodes played.

### Changed

- Manual Download All now starts at most 50 eligible episodes per confirmation and states the exact eligible, started, skipped, and deferred counts. Repeating the action starts the next bounded batch instead of silently creating hundreds of background transfers. Settings > Downloads adds a separate Cancel active downloads action that preserves completed audio, while Clear all downloads now reports the approximate device storage it will free. (#835)
- In-progress episode rows now show and speak both time remaining and total duration when the Time remaining VoiceOver detail is enabled. Untouched, completed, and unknown-duration episodes keep their previous wording. (closes #552)
- Downloads settings now labels the new-episode auto-download count explicitly as per podcast and explains that it applies after following and refreshing, includes new Inbox and Queue episodes, is not a global storage cap, and is separate from auto-downloading manually queued episodes. (closes #719)
- Earshot now keeps bounded, aggregate-only on-device evidence about media transport after full refreshes and bulk imports. It records only HTTP, HTTPS, other-scheme, and total counts—never a URL, host, show, episode, or account value—so the remaining ATS media exception can be evaluated without telemetry. (#709)
- Playback’s audio-session boundary is injectable and covered directly for playback category, AirPlay, both Bluetooth profiles, activation, stereo, and Voice Enhance’s spoken-audio/mono configuration. This is test coverage and architecture hardening; playback policy and spoken UI are unchanged. (closes #388)

### Fixed

- Repeated skip-forward and skip-back actions no longer bounce to an earlier position when an older seek completion, periodic playback tick, or private-iCloud handoff arrives late. Rapid skips accumulate from the newest requested position, and near-end seeks use the loaded media duration instead of a stale feed duration. (build 214)
- Played episodes left in Inbox by older builds are repaired in restart-safe background batches. Current natural episode completion remains covered end to end so a played episode cannot silently stay in Inbox. (closes #729)
- Earshot now excludes both current and legacy podcast download directories from device and iCloud backups, and repairs the exclusion on existing download folders. Downloaded audio remains reproducible and does not consume backup storage. (closes #710)
- Clear Queue now matches removing episodes individually and keeps deliberately removed episodes from returning to the Inbox.
- The Library's Published order no longer gets rewound by an older iCloud high-water mark.
- Automatic and manual Library refreshes share one in-progress state. The manual refresh control now says “Refreshing library” and is disabled during a launch or foreground refresh, preventing overlapping feed writers and duplicate candidates.

## [1.1.1] - 2026-08-20

### Added

- OPML imports that reach the free-plan limit can continue from the saved file after a verified Earshot Plus purchase or restore, including after relaunch.
- Settings now includes device-local VoiceOver controls for episode-row details, episode description length, and Library podcast descriptions.

### Changed

- Episode speech is consistent across Inbox, Queue, Downloads, folders, search, podcast episode lists, and multi-select rows while preserving mandatory playback and interaction state.
- Library rows can speak a brief or full sanitized podcast description without changing their accessible names, actions, or selection behavior.

### Folders Phase 3 complete — listening lens, Queue grouping, context menus, and OPML

- Folders now work throughout listening: filter the Inbox by a folder subtree, review and play or queue a folder's new episodes, group the Queue by folder, and preserve nested folders in OPML exports. New subscriptions can be filed immediately, and episode or podcast rows offer touch context menus that mirror the VoiceOver Actions rotor. Large scrolling lists defer Quick Action work until activation so VoiceOver navigation stays responsive. (#761, #762, #763, #764)

### Added

- Listening Stats: choose All folders, any folder subtree, or Unfiled to view listening totals, completed episodes, streaks, and the per-podcast breakdown through the same folder lens. A show filed in several places is counted once, and historical listening follows the show's current folder membership.
- Now Playing: playback started with Play all from a folder, or Play Group from a folder-grouped Queue, now shows a concise “Playing from” folder path. Activate it to return directly to that folder in Library. The context follows Queue advancement only while playback remains inside that folder tree, and clears on ordinary playback, folder deletion, or relaunch.
- Downloads: choose All folders or any folder subtree to narrow both downloaded and Recently Expired episodes. The folder filter composes with All/Unheard and search, announces the visible count for VoiceOver, and keeps the live episode query bounded to actual download candidates.
- Folders: the folder browser now starts with a compact top-level list and lets you expand or collapse nested folders in place. VoiceOver reads each folder's full path and expanded state, offers matching Expand/Collapse Actions rotor commands, and returns focus to the folder after the tree changes. Reordering stays within the folder's current parent, so dragging can never accidentally reparent it.
- OPML: exporting subscriptions now preserves nested folders, and subscribing from Search or Add Podcast offers to file the new show when folders exist. (#764)
- Queue: choose no grouping, group by podcast, or group by folder. Folder grouping includes nested subfolders under their top-level folder, keeps unfiled shows together, and gives every folder heading the same VoiceOver Play, Move, Sort, and Shuffle actions as podcast groups. Existing "Group by podcast" choices carry forward automatically. (#762)
- Folders: filter the Inbox to any folder and its nested subfolders, review the same scoped episodes in a new "New episodes" section on the folder screen, and Play all or Add all to queue. Folder listening actions now include every eligible episode—not just one per podcast—and honor the folder's queue expiration setting, with counts announced for VoiceOver. (#763)
- Quick Actions: press and hold any normal episode row, a Library podcast row,
  or a podcast inside a folder to open the same actions available from the
  VoiceOver Actions rotor, in the same configured order. A normal tap still
  performs the row's existing primary action. (#761)
- Folders: the folders feature is now complete. You can nest folders inside folders to any depth, and VoiceOver reads a spoken breadcrumb of where you are with a "Go up one level" control to step back out. Assign a podcast to one or more folders straight from its own settings screen. "Add to another folder" and "Move to one folder" are available everywhere on the VoiceOver actions rotor — in the Inbox, a podcast's episode list, Downloads, and the Library. Multi-select lets you pick many podcasts or many episodes and file the whole group in one move, with the count and result spoken. Folders can also hold hand-picked individual episodes in their own Episodes section. All of it is VoiceOver-first and accessibility-reviewed.
- Downloads: episodes you add to the queue now download automatically for offline playback, whether they were queued by hand or by auto-queue. It's on by default and respects your "Download on Wi-Fi only" setting, so a queued episode waits for Wi-Fi just like any other download. You can turn it off under Settings, Downloads ("Auto-download queued episodes"). Episodes already downloaded or downloading are left as-is, so nothing downloads twice.
- Downloads: a new "Delete downloads after played" setting (Settings, Downloads) automatically removes an episode's download once you finish it or mark it played, so storage clears itself as you listen. It's off by default and applies to every show. It covers all the ways an episode gets marked played: finishing playback, the "Mark as played" swipe or action, and "Mark all as played". Only completed downloads are removed, so an in-progress download is never interrupted.
- Downloads: a new "Clear all downloads" option removes every downloaded episode from your device in one step, so you can reclaim storage fast. It's on the Downloads screen (the trash button in the top corner) and under Settings, Downloads. Both ask you to confirm first and tell you how many episodes will be removed, and the Settings version shows a running count of what you have downloaded. Any download still in progress is cancelled too. It doesn't touch Recently Expired.
- Export audio from a list: you can now export an episode's audio file straight from its actions in the Inbox, Library episode list, and Downloads, without playing it first. Reach the episode's actions (the VoiceOver actions rotor, or your configured Quick Actions) and choose "Export audio" — Earshot downloads the episode if it isn't already saved, then hands the file to the system share sheet so you can save it to Files, AirDrop it, or open it in another app. It's a configurable Quick Action, so you can move it earlier or later in your action order under Settings. VoiceOver says "Preparing audio file for export" while it downloads, and the share sheet appears when the file is ready. (#689)
- Downloads: a new Unheard / All filter at the top of the Downloads screen lets you hide episodes you've already played, so a big list of downloads stays focused on what you haven't heard yet. It's set to All by default (you see everything), applies across all your shows, and remembers your choice. When you switch to Unheard, VoiceOver tells you how many played episodes it hid; if you've played everything, you get a short message and a one-tap way back to All. It only affects the Downloaded list, not Recently Expired. (#641)
- Settings: a "Leave a Tip" option under Help & About lets you make a one-time $1.99, $4.99, or $9.99 tip to support Earshot's development. It's available to everyone, whether or not you're on Earshot Plus, and each preset shows its real App Store price before you tap it — no surprises. (closes #636)
- Podcast settings: a new "Skip intro" option lets you automatically skip a set amount of time (5 seconds up to 1.5 minutes, or off) at the start of every episode of that podcast — handy for shows with a long musical intro or ad read before the content starts. It only applies the first time you play an episode; resuming an episode you already started never skips ahead again. (closes #456)
- Inbox: a new "Select" button lets you check several episodes at once and add just those to the queue in one step, in the order they appear in your inbox. Rows switch to checkboxes while selecting, VoiceOver announces "selected"/"unselected" as you check each one, and an "Add to Queue" button in the toolbar (which shows how many you've picked) does the rest. "Clear inbox" is unaffected and still works on its own. (#595)
- Background refresh: Earshot now checks your subscribed shows for new episodes on its own, so new episodes can land in your inbox without you pulling to refresh. To avoid checking too often, an automatic refresh is skipped if your feeds were already refreshed in the last 15 minutes or so; pulling to refresh yourself always forces an immediate check. Episodes found in the background flow into the inbox and through the same auto-queue and auto-download handling as a manual refresh (#380). Note for maintainers: how often the background check actually runs is decided by iOS based on usage and battery, and can only be confirmed on a real device. (#381)
- Settings: a new "About" screen shows that Earshot is a Payown Media LLC project, acknowledges BITS (Blind Information Technology Solutions) and the ACB community, and thanks Michael's wife and the beta testers. It notes that Earshot is open source and MIT licensed, with a "View source on GitHub" link to the public repo, and shows the version and build number you're running. VoiceOver reads the credits top to bottom, and the GitHub link warns that it opens in your browser outside Earshot. (#410)
- Settings: a "Send Feedback" option now opens a pre-filled email to the Earshot team (michael@payown.media). You can choose to include anonymized system info (app version, iOS version, device model) to help with debugging, and nothing personal is sent. If you don't have email set up, Earshot shows the address so you can still reach out. (#392)
- Now Playing: press and hold the player artwork to scan forward at 4× while you hold, then let go to drop back to whatever speed you were playing at. Earshot announces "Fast forward at 4 times speed" when you start and "Fast forward stopped" when you release. If you use VoiceOver with Direct Touch turned on, a "Start Fast Forward" / "Stop Fast Forward" action shows up in the actions rotor so you can scan without holding. (#373)
- Chapters: you can now mark chapters to skip from the player controls, and Earshot jumps past them automatically as you listen, announcing "Skipping chapter: …" each time it does. Your skip choices clear when you restart the app. (#373)
- Sleep timer: an "Extend +5 min" button now appears on the Now Playing bar and the player screen while a timer is counting down, so you can add time without reopening the timer picker. (#379)
- Bookmarks: you can now open the current episode's bookmarks straight from the player, either from the overflow menu or the VoiceOver actions rotor. Each bookmark lets you jump to that spot, delete it, or share it. Sharing sends the episode title, the timestamp, your note, and the audio link. (#372)
- Now Playing: you can change playback speed directly from the player screen. Tap the speed badge below the controls to open a picker with quick shortcuts (0.5×, 1×, 1.25×, 1.5×, 2×) and a stepper for 0.1× precision anywhere from 0.5× to 5.0×. Set the speed for just the current podcast or for all podcasts from the same sheet. When a per-podcast speed is active, the badge shows a * so you can tell it differs from your global setting. VoiceOver announces the speed you chose and which scope you applied it to, and focus returns to the badge when the sheet closes. The global speed picker in Settings also covers the full 0.5× to 5.0× range now. (closes #368)
- Coming from the previous version of Earshot: the first time you open this
  build over your existing install, Earshot brings your subscribed shows across
  automatically and drops you straight into your Library, skipping setup. Your
  shows appear almost instantly; their episodes then load in the background, so
  the app stays responsive the whole time (a progress indicator at the top shows
  how many shows have loaded, and each show reads "Loading episodes…" until its
  episodes arrive). VoiceOver confirms how many shows were restored and announces
  when episodes have finished loading. It reads your old subscription list from
  the app's own storage on your device, so nothing leaves your phone and no extra
  steps are needed. Your inbox starts empty; new episodes published from now on
  arrive in it as usual. Only your subscriptions move over (not play positions or
  queue); if anything can't be brought across, you can still export an OPML file
  and import it.
- Coming from the previous version of Earshot: your play queue now comes across
  too, in the same order you left it, so you can pick up where you were without
  rebuilding the queue by hand.
- Inbox limits: each podcast can now cap how many episodes stay in the inbox and
  auto-remove episodes older than a set time (6 hours up to 2 weeks), both set on
  the podcast's settings page in the Library. A global "Default episodes per
  podcast in inbox" choice under Inbox settings sets the default (No limit by
  default, so nothing changes unless you opt in). Trimmed episodes aren't
  deleted; they stay unplayed in the show's episode list. Anything you've
  played, started, or queued is never touched.
- Queue: in the "Group by podcast" view, each podcast group now has "Move
  group to top/up/down/bottom" actions in the VoiceOver/TalkBack actions
  rotor, mirroring the per-episode move actions.
- OPML: Earshot now appears as "Open in Earshot" in Mail/Files and "Share to
  Earshot" in the share sheet for `.opml` files exported from other podcast
  apps (e.g. Castro, Overcast). Tapping or sharing an OPML file opens the
  Import OPML screen pre-loaded with the file; multiple shared files are
  imported one after another. (iOS only for now.)
- Now Playing: an AirPlay button lets you pick your audio output device directly from the player screen. Tap it to switch to AirPlay speakers, headphones, or any Bluetooth device without leaving the app. VoiceOver labels it "AirPlay" with the hint "Choose audio output device." (closes #370)
- Per-podcast settings: tap the gear icon on any podcast's episode list to set its playback speed, auto-queue, inbox limits, and notification preference. Changes take effect immediately. (closes #399)
- Player: three new actions are available from the full-screen player's overflow menu and the VoiceOver actions rotor. "Mark as played" marks the current episode played and moves you on without playing to the end, and Earshot announces "Marked as played". (#371)
- Player: "Export audio file" shares the current episode's audio through the system share sheet, so you can save it to Files, AirDrop it, or open it in another app. If the episode isn't downloaded yet, Earshot downloads it first and then shares the local file. (#371)
- Player: "Stop after this episode" is a one-off that stops playback when the current episode finishes instead of auto-advancing, then clears itself. It also resets if you restart the app. Earshot announces "Will stop after this episode" when you turn it on. (#371)
- New episode notifications: turn on "Notify on new episodes" for any show from its settings page, and Earshot sends you a notification when a background refresh finds new episodes for it. The notification shows the show name and how many new episodes there are, and gives you "Add to queue" and "Play now" buttons right on it. Tapping the notification opens that show in your Library. Earshot asks for notification permission the first time you turn the toggle on. These are on-device notifications only, so nothing is sent to a server, and Earshot never pesters you about your inbox, queue, downloads, or how long it's been since you last listened. (closes #72)
- Inbox: the Inbox tab title now shows how many episodes are waiting, like "Inbox (12)", and updates live as you triage or clear the inbox. When the inbox is empty the title is just "Inbox", never "Inbox (0)". (#422)
- Settings: a new "Data" section has an "Import older data" action that re-runs
  the import of your shows, your played and inbox state, and your queue from the
  previous version of Earshot. Coming from the previous version of Earshot, this
  is here for the times your data didn't fully come across on the first launch.
  It's always available, not just during a one-time setup window, and it's safe
  to run more than once, so you won't end up with duplicate shows or queue items.
  The row shows where things stand (not imported, imported on a date, or import
  failed), and the import sheet tells you how it went when it finishes. A clean
  install with nothing to bring over is treated as up to date, not a failure.
  (closes #429)
- Behind the scenes: laid the groundwork for an upcoming paid tier, Earshot Plus (monthly, yearly, or one-time lifetime unlock). This is engineering foundation only, nothing to see or buy yet. No paywall, no purchase button, no change to how the app works today. (closes #631)
- Behind the scenes: Earshot Plus entitlement is now checked and verified entirely on-device using StoreKit 2, with no backend involved. Still engineering foundation only — no paywall or purchase UI yet. (closes #634)
- Podcast episode list: a "Mark all as played" toolbar button marks every unplayed episode in that show as played in one step, and dismisses newly-played episodes from your inbox the same way marking a single episode played does. It's disabled with an explanatory hint when there's nothing unplayed left. A confirmation dialog always asks first, naming the podcast and the episode count, and makes clear it can't be undone. (closes #640)
- Behind the scenes: every pull request into the SwiftUI rewrite now automatically builds the app and runs the full native test suite before it can merge, instead of relying on someone remembering to run tests by hand. Nothing to see or do differently as a user. (closes #656)
- Settings: a new "Earshot Plus" section adds a "Restore Purchases" action at the top of Settings. Tap it to re-sync your purchase history with your Apple ID and restore Earshot Plus if you've already bought it, whether as the lifetime unlock or a monthly or yearly subscription. While it's working, the button shows a busy state so a slow connection or an Apple ID sign-in prompt doesn't look like nothing happened. (closes #633)
- The free plan's 10-podcast limit is now enforced. Adding an 11th podcast — from Add Podcast, search, a directory preview, or OPML import — is blocked with a message telling you how many podcasts you can have on the free plan and that Earshot Plus removes the limit. Importing an OPML file that would put you over the limit imports as many as fit and tells you how many were skipped and why, with an upgrade mention, instead of silently dropping the rest. If you already had more than 10 podcasts from before this limit shipped, you keep every one of them, fully usable — the limit only affects podcasts added from now on. If a Plus subscription lapses while you're over the limit, the extra podcasts go read-only rather than being deleted (no new episodes download for them, though you can still unfollow one if you choose), and the Library marks them "Read-only" with an icon and text (not color alone) that VoiceOver reads out. (closes #635)
- Earshot Plus paywall: hitting the free plan's 10-podcast limit, or opening the new "Upgrade to Earshot Plus" row in Settings, now shows an upgrade screen with Monthly, Yearly, and Lifetime options, all shown with equal size and styling — Yearly gets a small factual "best value" note based on the real prices, nothing more. Price, billing period, and cancellation terms are shown before you can tap to buy, and Lifetime is clearly marked as a one-time purchase, not a subscription. Closing the screen works the same way at every point, with no pressure to buy. (pending design/copy review, not yet merged) (closes #632)

### Changed

- Folder actions now say “Add to another folder” when existing folder assignments will be kept and “Move to one folder” when all other assignments will be removed. The destination picker explains the difference, and Move asks for confirmation while naming the folders that will be removed. Podcast settings now calls its multi-membership editor “Manage folders.”
- New episode notifications: when a new episode is found while Earshot is open, the notification no longer interrupts you with a banner and sound. It goes quietly to Notification Center so it doesn't talk over what you're doing or pull screen reader focus away. (closes #421)
- Data model: the per-podcast new-episode notification setting is now stored as an optional value so the database can move to the new format with a lightweight, automatic upgrade. Your saved notification choices are unchanged. (closes #425)
- Networking: feed refresh and podcast search now hold up better on a flaky connection. When a request hits a temporary problem (a server 5xx error, a dropped connection, or a timeout), Earshot waits briefly and tries again, twice, before giving up (1 second then 2 seconds). Permanent errors like a 404 or a bad address still fail right away instead of retrying for no reason. All network requests now use the same timeouts, so you should see fewer "couldn't load" failures when the network hiccups. (#386)
- Settings: removed the Skip Silence toggle. AVPlayer doesn't support silence trimming natively, so the toggle had no effect on playback. Removing a control that silently does nothing is better than leaving it there. (closes #369)
- Quick Actions: your configured episode-action order now drives the VoiceOver
  Actions rotor too, not just the menu and default double-tap. Reorder your
  actions in Settings and the rotor follows the same order (the menu and default
  update instantly; the rotor applies the next time you open Earshot, which the
  app announces when you save).
- Episode actions are now identical across Inbox, Queue, Library, and Downloads.
  Every tab uses one shared "Play now" path, one shared actions bottom sheet, and
  the same VoiceOver rotor actions in the order set in Quick Actions settings.
  Queue keeps its move/remove actions; Downloads tiles gain a "more actions"
  button. Downloaded episodes now always play the local file instead of streaming.
  Destructive actions (Remove from queue, Delete download) show a leading icon in
  the sheet so danger is not signaled by color alone.

### Fixed
- Large libraries: fixed the phone running hot during long listening sessions. Earshot saved your exact playback position into its database every few seconds while you listened (more often at faster speeds), and on a large library every one of those saves forced the whole app to re-read your unplayed episodes — sustained work that warmed the phone over an hour or two. Now, while an episode is playing, your position is kept in fast lightweight storage and only committed to the database when you pause, skip, switch episodes, or leave the app — so continuous listening does almost no database work and stays cool. Your place is just as safe as before: the position still updates every few seconds, and if the app is ever interrupted, it resumes within a few seconds of where you were. The Inbox unread badge was reworked the same way, so it no longer recounts as you listen either; its number is unchanged. (#736)
- Large libraries: fixed Earshot crashing a minute or two into playback for people who follow a lot of shows. The unread-count badge on the Inbox tab sits on every screen, and during playback it was re-counting episodes every few seconds. It counted your whole episode history, not just unheard episodes, and because finished episodes were never dropped from that count, the work grew with everything you'd ever played. On a large library that pinned the processor until iOS force-quit the app, which looked like audio stopping and getting dropped back to the Home Screen a minute or so after you started listening (worse with the screen locked). The badge now counts only unplayed episodes, so its cost stays small no matter how big your library or listening history gets. The number it shows is unchanged. (#731)
- Bluetooth earbuds: fixed the play/pause button on single-button Bluetooth earbuds not pausing reliably. On some earbuds (like the Bose Ultra Open) a press did nothing to pause, and on others (like the Shokz OpenFit) it took two presses. Play and skip always worked. The cause was Earshot telling the system it was paused for a moment while audio was actually starting, which confused earbuds that decide whether to send "play" or "pause" based on that. Earshot now reports its playing state from what you actually intend, and a single press pauses the first time on these devices. (build 153)
- Large libraries: fixed the main cause of Earshot crashing or becoming unusable after importing a very large library (hundreds to over a thousand shows). After every background update — launch, resume, pull-to-refresh, and OPML import — Earshot used to re-read its entire episode database into memory at once just to refresh what was on screen. On a big library that was a huge, sudden memory spike (measured on device at roughly 580 MB for 400 shows and about 1.7 GB for 1,200 shows), which iOS responds to by force-quitting the app — so shortly after a big import the app would slow down and then crash every time it was reopened. Earshot now refreshes only the shows that actually changed, which stays flat as your library grows (about 7 MB at 1,200 shows instead of 1.7 GB). No change to what you see or how episodes sync. (#696)
- Large libraries: importing a big OPML (hundreds of shows) is faster and less likely to run the app out of memory. Earshot no longer resolves every episode of every imported show just to pick the few most recent ones to auto-download — it now keeps only the newest handful per show for that step. Part of a larger effort to make very large libraries stable (#696).
- Playback: fixed a crash that could hit a few seconds into an episode, especially early in a session when a Bluetooth device (like AirPods or a car) connected just after you started playing. Earshot no longer reconfigures the audio session on every incidental audio-route change, and it reverts to the steadier time-stretch algorithm while we confirm the fix on devices. If you use Voice Enhance, it's still reapplied when your headphones or speaker change. (closes #695)
- Dev tooling: the `pre-commit` hook now formats only the Dart files actually staged for a commit, instead of unconditionally reformatting every file under `lib/` and `test/`. Previously, Dart formatter drift between contributor SDK versions could rewrite dozens of unrelated Flutter files as a side effect of a Swift-only or docs-only commit, blocking it outright. Install with `git config core.hooksPath tool/hooks` (applies repo-wide, including git worktrees). (closes #660)
- Podcast settings: turning on "Opt-in podcasts only" under Settings > Inbox no longer leaves every show locked out of the inbox with no way back in. You can now opt a podcast in from the "Include in Inbox" toggle on its settings page, from a new swipe action on Library rows, or from the VoiceOver actions rotor. Thanks to beta tester Bel for reporting this one. (closes #668)
- Podcast settings: with "Opt-in podcasts only" left off (the normal, default mode), you can now keep one noisy podcast out of your inbox without switching your whole library to opt-in. Use the "Exclude from Inbox" toggle on its settings page, a new swipe action on Library rows, or the VoiceOver actions rotor. (closes #671)
- Playback: closed a narrow, cosmetic timing gap where a finished episode could very briefly show a stale resume position instead of the start. Right around the moment an episode is marked played, the app now stops writing any further position updates for it, so the just-cleared "start from the beginning" state can never get overwritten by a position captured a split second earlier. No visible change for normal playback. (closes #653)
- Downloads: auto-download of newest episodes now actually works for shows you're already subscribed to. Two bugs combined to make it silently do nothing: an ordinary refresh (pull-to-refresh, cold launch, coming back to the app, or the background check) never triggered a download, only your first time subscribing did, and even then most of the app built its own downloader instead of using the real one, so downloads still didn't start. Auto-download now fires from every refresh path using the same shared downloader throughout the app. (closes #639)
- Queue: playing an episode that wasn't at the top of the queue (leaving earlier episodes in place) now correctly continues to the next episode below it when it finishes, instead of jumping back to the top of the queue. This also fixes the same wrong jump for "Mark as played," removing the playing episode from the queue, and which episode gets buffered ahead of time for gapless playback. With "Group by podcast" turned on in the Queue tab, "next" now also follows that same grouped, same-show order shown on screen instead of the app's real (and possibly interleaved-with-other-shows) queue order — except an episode you "Play Next"-ed always plays immediately next regardless of grouping, exactly as it always has. (closes #627)
- Your data is no longer at risk of being silently wiped when a store can't be opened. Before, any failure to open the on-device database triggered an automatic reset that deleted everything and started fresh, with no backup and no warning. Now Earshot never destroys your data on its own: if you open an older build over data written by a newer one, it leaves everything untouched and asks you to update the app; and if the data is genuinely unreadable, it shows a recovery screen that makes a backup copy first and only clears the data after you explicitly choose "Reset local data." The recovery screen is fully VoiceOver-accessible and scales with Dynamic Type. (closes #529)
- New episode notifications: turning on a show's "Notify on new episodes" toggle now reliably asks for notification permission the first time. Before, the permission prompt never appeared, so the notifications could never be delivered. (closes #421)
- New episode notifications: notifications now fire from a pull-to-refresh and from launch, not just from the background check. Before, only the background refresh sent them, which rarely ran, so new episodes you found yourself never produced a notification. (closes #421)
- New episode notifications: a notification is no longer dropped when a background check is skipped because your feeds were refreshed in the last 15 minutes. Notification delivery is now separate from that refresh window, so an expected notification still goes out. (closes #421)
- Coming from the previous version of Earshot, the move now brings your full reading state across, not just your subscriptions. Each episode's played status, inbox membership, and where you left off all carry over, matched by episode GUID (or audio URL if there's no GUID). Before this fix a returning user's inbox came back empty and nothing showed as played, because the restore wiped those out as it ran. Played episodes are correctly kept out of the inbox. (#426)
- The first-launch import no longer locks you out of a library that's still on your device. If that first read found no data it used to mark the move "done" for good, so your shows never appeared. The import now only finishes when it actually brings something across; an empty read is retried on the next launch, up to three times, so a one-off miss recovers on its own. (#426)
- Earshot now self-heals a stuck move. If an earlier version already marked the move complete but your Library is empty while the old database is still on your device, Earshot spots this on launch and runs the import again automatically. No reinstall needed. (#426)
- Coming from the previous version of Earshot, a library that arrived with your shows but lost its played, inbox, and queue state now repairs itself on a later launch. This covers a first launch with no earshot.db to read and a move that started but didn't finish. Earshot notices the missing history and quietly runs the restore again, so you get your reading state and queue back without redoing setup or re-downloading anything. (#426)
- Updating from an older build no longer risks a crash on launch for existing users. Earshot's on-device database now upgrades to the new format through a tested, step-by-step path that keeps your subscriptions, episodes, queue, played status, bookmarks, and folders intact. A test that mimics a real older install proves the upgrade finishes without crashing, and a separate check now blocks any future change that could reintroduce this kind of launch failure. (closes #425)
- Settings: Send Feedback now sends to michael@payown.media instead of the old beta@payown.media address. This corrects the mail composer recipient, the mailto fallback, and the address shown when no mail app is set up, so feedback reaches the project owner as the release notes said it would. VoiceOver's hint on the button now reads "Opens an email to michael at payown dot media". (closes #418)
- Playback: the device now runs cooler and uses less battery during playback. Earshot was updating the lock screen and Control Center elapsed time every second, which kept the system media server busy in the background; it now refreshes that time every 5 seconds (and right away when you play, pause, seek, or change speed). The lock screen still shows the correct elapsed time because the system fills in the seconds between updates. (#412)
- Sleep timer: starting a different episode now cancels any running sleep timer. VoiceOver announces "Sleep timer cancelled" when this happens. (#379)
- Player: podcast artwork now appears on the lock screen and in Control Center while an episode is playing. Earshot checks its local cache first, so no extra network request is needed if you've already seen the artwork in the app. (closes #378)
- Artwork: podcast artwork is now cached to disk instead of re-downloading every time you cold-launch the app. Artwork loads faster and uses less data, especially with large libraries, and the same cache feeds the lock-screen and Control Center artwork. (closes #385)
- Player: tabs now switch instantly while audio is playing. Before, tapping a tab
  did nothing until you paused, which left VoiceOver users unable to move around
  the app during playback. The fix throttles how often the playback position is
  saved to disk (it was saving every second on the main thread and starving the
  UI). Position is still saved on pause, seek, and episode change, so nothing is
  lost. (closes #362)
- Player: the mini player no longer covers the tab bar during playback. The Now
  Playing bar now sits above the tab bar, so all five tabs stay visible and
  tappable while audio is playing. The bar still respects the home indicator and
  hides when nothing is loaded. (closes #366)
- Quick Actions: reordering your episode or podcast actions now saves reliably.
  Some setups (carried over from an older app version) could hit a hidden
  conflict that silently rolled back the save, so the order reverted every time
  you reopened the app. The save now collapses that conflict, and the
  configurator confirms "Quick actions saved" (or tells you if a save fails)
  instead of failing without a word.
- Playback: with both "Continue after…" switches off, playback now stops at the
  end of the current episode instead of rolling on to another one. And when
  playback does continue, finishing an episode you started from the middle of the
  queue now moves to the next episode below it, not back to the top of the queue.
  "Continue after group ends = off" now reliably stops when the next episode is a
  different show, even when you started a single episode rather than a whole
  group. (closes #327)
- Queue: the playing episode now stays in its real position in the list with a
  "Now playing" label, instead of being lifted to the top. The list reads in true
  play order.
- Feeds: when a podcast republishes an episode under the same ID with a newer
  date, it now returns to the Inbox instead of staying hidden — but only if it
  was auto-filed backlog you never touched. Episodes you played, started,
  queued, or cleared are left exactly as they were.
- Queue: "Remove from queue" on the episode that's currently playing now marks it
  played, removes it, and moves on to the next episode, the same as the player's
  "Mark as played". Before, it appeared to do nothing (the playing episode stayed
  pinned at the top) and wrongly reset its status. Removing any other queued
  episode is unchanged.
- Performance: the Inbox is now interactive immediately on cold launch instead
  of being unreachable for a minute or more on large libraries. The app no
  longer force-refreshes every feed on every cold start (it skips the refresh if
  the feeds were checked in the last 15 minutes, matching the on-resume
  behavior), episode writes during a refresh are now batched, the inbox query
  and unread badge are backed by a new database index, and the badge is counted
  in the database instead of by loading every unread episode. Pull-to-refresh
  still forces a full refresh.
- Inbox: VoiceOver/TalkBack now reads a short show-notes preview for each
  episode after its title, show, and status, so you can hear what an episode is
  about while browsing without opening it. The full notes remain one rotor
  action away via "Open show notes". HTML and entities are stripped so no markup
  is read aloud.
- Show notes: opening an episode's show notes from the Inbox, Queue, Library, or
  Downloads now announces "Show notes" to VoiceOver/TalkBack when it opens and
  exposes the episode title as a heading, so screen reader users can read an
  episode's notes while browsing without starting playback.
- Player: the sleep timer's increase/decrease (chevron) buttons now meet the
  minimum touch-target size on all platforms. They were slightly under the
  Android 48dp minimum, making them harder to tap accurately.
- Queue: removing the next episode while another is playing no longer lets the
  removed episode play anyway. Earshot preloads the next episode for gapless
  playback; if you removed or reordered that episode out of the next slot, the
  preloaded copy used to still play when the current one finished. It's now
  dropped as soon as the queue changes, and the correct next episode plays.
- Inbox: a podcast with a single mis-dated "future" episode no longer goes
  silent. Previously one episode dated in the future pushed that show's
  high-water mark ahead of real time, so every later, correctly-dated episode
  was treated as old backlog and never reached the Inbox. Future-dated items are
  now ignored when tracking what's new, and a one-time database fix repairs any
  show already affected so new episodes start arriving again.
- Queue: "Move up"/"Move down" Quick Actions on a grouped episode now reliably
  reorder it within its podcast group. Previously they swapped the episode's
  position in the global flat queue, which could land on a different podcast's
  episode and produce no visible change in the grouped view.
- Privacy: crash reporting and anonymous analytics now actually respect the
  opt-out toggles in Privacy & History. Previously these toggles had no effect
  on whether Sentry/PostHog initialized. Privacy settings note that changes
  take effect on next app restart.
- Search: fixed podcast search still returning no results. iTunes API returns
  `Content-Type: text/javascript`; response is now fetched as plain text and
  decoded manually, bypassing Dio's content-type-based auto-parsing entirely.
- Search: moved search entry point from the Library AppBar to the Library screen's
  FAB area. A small search FAB now sits above the "Add by URL" FAB in the bottom
  right corner — both have accessible tooltips for VoiceOver/TalkBack.
- Inbox: removed the folder-queue button from the Inbox AppBar.
- Inbox: "Mark all as played" no longer crashes the app. Any database error is now
  caught and shown as a snackbar instead of crashing the app.
- Search: fixed podcast search returning no results. iTunes API returns
  `Content-Type: text/javascript`; Dio now forces JSON parsing regardless of
  content type.
- Search: tapping a search result now opens a podcast preview screen with title,
  author, description, and episode list from the RSS feed. VoiceOver users can
  flick down on any result to access a "Follow" action directly from the list.
- Search: Clear search (X) button no longer announces twice. Only
  "Clear search, button" is visible to screen readers.
- Inbox: "Add folder to queue" sheet barrier is now labeled "Dismiss folder queue
  sheet" so VoiceOver users know how to dismiss it.
- Inbox: "Add folder to queue" sheet heading no longer announces twice.
- Library screen: "All Podcasts" row no longer appears as an unlabeled button
  in the VoiceOver/TalkBack accessibility tree.
- Folder picker sheet: "Done" button now has an explicit semantic label and hint.
- Manage Folders flow: VoiceOver no longer lands on "scrim" when the folder
  picker sheet opens via a quick action. The barrier is now labeled "Dismiss
  folder picker" and the sheet claims focus on open.
- Play All Unplayed Episodes now starts playback immediately instead of only
  adding episodes to the queue.
- Folder picker sheet: Removed duplicate "Add to Folder" heading, unlabeled
  button after Done, and extra VoiceOver traversal stop. Done button moved to
  sheet footer so it is reachable by swiping forward after selecting folders.
- Folder picker sheet: "Create new folder" no longer appears as two buttons in
  the VoiceOver tree.
- Folder picker sheet: VoiceOver no longer announces "Add to Folder, Done,
  heading" on open. Removed `Focus(autofocus: true)` container wrapper that was
  causing VoiceOver to group and summarise all children on sheet entry.
- Folder picker checkboxes no longer announced as "dimmed, switch button off".
  Replaced custom Semantics/ExcludeSemantics wrappers with plain CheckboxListTile
  whose built-in MergeSemantics correctly maps to "checkbox, checked/unchecked"
  on iOS VoiceOver. Same fix applied to "Create new folder" row.

### Accessibility
- Mini player: the Now Playing bar now hides once playback stops with nothing left to play — a finished episode with an empty queue, an end-of-episode sleep timer, "Stop after this episode", "Mark as played", or removing the playing episode from the queue. Before, it lingered on the finished episode as an extra, meaningless VoiceOver stop. When an episode ends on its own with nothing queued, VoiceOver now hears "Episode finished" so it's clear the episode ended rather than that playback was paused. Pausing mid-episode always keeps the bar, and the bar no longer reappears on a finished episode after you relaunch the app. (#730)
- Mini player: VoiceOver flick (swipe) order now reaches the Now Playing bar last, matching its position just above the tab bar, so swiping through a screen and exploring it by touch agree. Before, the bar was announced first even though it sits at the bottom. (#730)
- VoiceOver announcements no longer garble mid-sentence. When an announcement included a podcast or episode title (for example "Now playing …" or "Downloaded …"), a stray web address or tracking code inside the title from the feed could make VoiceOver think part of the sentence was in another language and switch to a different, oddly-pitched voice partway through. Announcements are now spoken in your own system language throughout. A side effect worth knowing: a title that really is in another language is now read in your system voice too, which may not pronounce it perfectly, but you'll never get the garbled voice-switch again. (#688)
- Add podcast / Search: when following a feed fails, VoiceOver now reads a plain message like "Couldn't reach that feed. Check your connection and try again." instead of a raw technical error string (for example an "NSURLErrorDomain -1009" code or a URL), which VoiceOver could mangle. The detailed error still goes to the logs. (#688)
- Player: VoiceOver now announces "Playing" or "Paused" once when playback state
  changes, instead of repeating the announcement for every tab. (closes #366)
- New episode notifications: notifications use plain, meaningful text with no emoji, so VoiceOver reads something useful like "Show name, 2 new episodes" instead of an icon. Tapping a notification moves focus to that show's detail screen in the Library. (closes #72)
- New episode notifications: a new-episode notification that arrives while you're using the app is now delivered silently to Notification Center instead of taking over with a banner and sound, so it doesn't interrupt VoiceOver or pull your focus mid-task. (closes #421)
- Coming from the previous version of Earshot, VoiceOver users now land in a Library that matches what they left. Their inbox, played episodes, and saved positions all carry over, so the first thing VoiceOver reads after the move is their real state and not an empty, all-unplayed list. (#426)
- The self-heal that restores a missing inbox, queue, and played state on a later launch does its work silently. VoiceOver users are not interrupted by a spurious announcement; the restored state is simply there the next time they look. (#426)
- Inbox: VoiceOver now reads the inbox count as part of the tab title, spoken naturally as "Inbox, 12 episodes" (and "Inbox, 1 episode" for a single item), with the heading role preserved. (#422)
- Settings: the "Import older data" row reads its current status as its
  VoiceOver value, so you hear "not imported", "imported on" a date, or "import
  failed" right after the label without opening anything. When the import sheet
  finishes, VoiceOver announces the outcome out loud. (#429)
- Inbox: the app no longer feels sluggish under VoiceOver while audio is playing.
  The Inbox tab and its list were re-fetching the whole inbox several times on
  every render, and again every few seconds as the playing episode's position was
  saved, which competed with VoiceOver on the main thread. The inbox is now read
  once per render from a maintained query, so flicking through the Inbox stays
  responsive during playback. The inbox contents, order, count, and tab badge are
  unchanged. (#478)
- Lists feel quicker under VoiceOver. Episode, queue, and bookmark rows were doing
  redundant accessibility work on every focus move; that's removed, so flicking
  through the Inbox, Library, Queue, and bookmark lists is more responsive. What
  VoiceOver reads for each row, and its actions rotor, are unchanged. (#479)
- Now Playing: the playback scrubber no longer re-reads its name every second
  during playback. VoiceOver now hears a steady "Playback position" label with the
  live time in its value, spoken as elapsed of total (for example "12 minutes of
  42 minutes"), matching the on-screen times. Swipe up or down still jumps 30
  seconds. (#480)
- Scrolling lists feel smoother under VoiceOver. Podcast artwork was being decoded
  at its full source size (often far larger than it's shown) on the main thread as
  rows drew, which competed with VoiceOver while you scrolled. Artwork is now
  decoded once at the size it's actually displayed, off the main thread, so the
  Library and other artwork lists stay responsive during a flick. The lock-screen
  and Control Center artwork still looks the same. (#481)
- Podcast episode list: "Mark all as played" is also reachable as a VoiceOver actions rotor item from the podcast title header, so you don't need to hunt for the toolbar button. When it finishes, VoiceOver announces the result, comma-grouped and singular-correct, like "Marked 1,204 episodes as played" or "Marked 1 episode as played." (#640)
- Settings: the new "Restore Purchases" button announces "Restoring purchases" and disables itself while the sync is running, then announces one of three clear outcomes when it's done: "Earshot Plus restored," "No purchases to restore," or "Restore failed. Check your connection and try again." (#633)
- Settings: the new "Leave a Tip" screen announces each step of a purchase out loud — "Purchasing $X.XX tip" while it's in progress, then "Thank you for your $X.XX tip," "Tip cancelled," "Purchase pending approval," or "Tip failed. Try again." depending on how it finished. Each preset button's VoiceOver label states the price plainly (e.g. "Leave a $4.99 tip"), and leaving without tipping just uses the normal back button — no separate close control to hunt for. (#636)
- Earshot Plus paywall: each purchase button's VoiceOver label speaks the plan name, price, and billing period together as one phrase (like "Earshot Plus Monthly, $2.99 per month"), and the price/terms disclosure is a separate line VoiceOver reaches before the purchase button, never hidden in a hint. Starting a purchase announces which plan is being purchased; finishing announces "Earshot Plus unlocked," a pending-approval notice, or a calm "Purchase cancelled" that doesn't sound like an error. The close button is always labeled "Close," never just an icon. (pending design/copy review, not yet merged) (#632)
- Library: with "Opt-in podcasts only" turned on, an "Add to Inbox" (or "Remove from Inbox") action now appears in the VoiceOver actions rotor for every podcast, and Earshot announces the change when you use it. This was the only way to opt a podcast into the inbox before the swipe action and settings toggle were added, so it's the primary path for VoiceOver users. (#668)
- Library: with "Opt-in podcasts only" left off, an "Exclude from Inbox" (or "Include in Inbox") action now appears in the VoiceOver actions rotor for every podcast, mirroring the opt-in-mode rotor action above, and Earshot announces the change when you use it. (#671)

### Phase 8 complete — Alpha build prep

- Version set to 0.1.0+1
- Release CI workflow at .github/workflows/release.yml (triggered on v*.*.* tags)
- Android signing config ready (key.properties template provided)
- build_runner codegen step added to all CI jobs (fixes *.g.dart not committed)
- Replaced file_picker with file_selector (Flutter team package, fixes Android namespace error)
- Upgraded sentry_flutter to v9 (fixes Kotlin 1.6 deprecation on CI)
- CI: Analyze and test ✓, Build iOS ✓, Build Android ✓

### Phase 7 complete — Polish: sleep timer, onboarding, bookmarks, telemetry

- Sleep timer: presets (end of episode, 5–60 min), Extend +5 min in now-playing bar and player screen, all actions announced to screen readers
- Onboarding: 7 screens shown on first launch, skippable, "Next" gated on screen 6 until a podcast is added, completion persisted
- Bookmarks: Quick Action captures current playback position, announced "Bookmarked at M:SS"
- Sentry crash reporting wired (opt-out, DSN via compile-time env var, no-op when empty)
- PostHog analytics wired (opt-out, API key via env var, no-op when empty)
- Privacy Settings: crash reports and analytics toggles, history retention, delete all
- CSV stats export from Stats screen via share sheet
- **Deferred to Phase 8 prep:** chapter support, volume boost/mono audio, silence trim, CarPlay/Android Auto, beta build upload

### Phase 6 complete — Search, OPML import/export, podcast discovery

- Search icon in Subscriptions opens podcast directory search (Podcast Index API)
- Debounced search (300ms), result list with per-row Subscribe buttons
- Subscribe confirmation announced via SemanticsService
- OPML import: file picker → bulk subscribe with live progress as semantic live region
- OPML export: generates OPML 2.0 and shares via system share sheet
- Settings → Subscriptions section with Import and Export
- 7 OPML unit tests (parse, edge cases, generate, round-trip)
- **Deferred:** Local audio import (iOS "Open In" / Android SAF) — Phase 7
- **Deferred:** Podcast Index integration — Phase 7 or later
- **Deferred:** In-app subscription filter (type to filter subscribed list) — Phase 7

### Phase 5 complete — Stats, listening history, privacy controls

- App records listening sessions (episode, podcast, duration, speed, date) on pause and stop
- Stats screen: time listened, time saved by speed, episodes completed — all as plain text
- Per-podcast breakdown sorted by time
- Period selector: This Week, This Month, This Year, All Time
- Privacy Settings: history retention (30d/90d/1y/forever), "Delete all history"
- Retention applied automatically on app launch
- Settings → Listening Stats and Settings → Privacy & History navigation
- 10 unit tests for stats aggregations, period filtering, and retention
- **Deferred:** CSV export, year-in-review, streaks — Phase 7 polish

### Phase 4 complete — Downloads, Inbox, queue expiration, bottom navigation

- Subscribe auto-downloads 3 most recent episodes (configurable, default 3)
- Download manager with progress tracking and cancellation via dio
- Inbox tab: all new untriaged episodes with Add to queue, Mark played, Delete actions
- Queue tab: reorderable list with Remove and Move-to-top Quick Actions
- Downloads tab: downloaded episodes + Recently Expired with 7-day restore window
- Queue expiration: items older than per-podcast age limit auto-move to Recently Expired
- Bottom navigation bar with badge count on Inbox
- Schema version 3: app_settings (key-value), recently_expired tables
- **Deferred:** Wi-Fi-only enforcement (connectivity_plus/xml version conflict) — Phase 7
- **Deferred:** Auto-queue toggle and change-queue-age-limit Quick Actions — still stubs

### Phase 3 complete — Quick Actions, Settings, accessibility layer

- Episode and podcast rows expose VoiceOver actions rotor / TalkBack custom actions via `customSemanticsActions`
- Default episode Quick Actions: Play now, Add to queue, Mark played/unplayed, Open show notes
- Default podcast Quick Actions: Open, Toggle notifications, Toggle auto-queue, Unsubscribe
- First action in user's list is the default double-tap action
- Settings screen accessible via gear icon in app bar
- Quick Action configurator: drag-to-reorder list with up/down button alternatives for screen readers
- Quick Action order persists to SQLite and takes effect immediately
- `ReduceMotion` extension on `BuildContext` ready for all future animations
- High-contrast theme wired to system setting via `MaterialApp.highContrastTheme`
- **Deferred:** Toggle notifications and Toggle auto-queue actions (stubs — need Phase 4 backend)
- **Deferred:** Share action (Phase 7)
- **Deferred:** Manual VoiceOver/TalkBack test — carry into Phase 4

### Phase 2 complete — Playback engine, queue, player UI

- Tap any episode to play it — audio streams via `just_audio` with background playback
- Lock screen and Control Center controls wired via `audio_service` (iOS and Android)
- Now-playing bar on subscriptions list and podcast detail screens: artwork, title, skip, play/pause
- Full player screen: large artwork, progress bar with position announced for screen readers, speed selector (0.5x–3.0x), skip controls
- Playback position auto-saves on pause and restores on resume
- Episode marked played at completion
- Queue data model persists across restarts
- Platform configuration: iOS background audio mode, Android foreground service and media permissions
- **Deferred:** Periodic position save while playing (every 10s) — Phase 7 polish
- **Deferred:** VoiceOver/TalkBack manual test — carry into Phase 3

### Phase 1 complete — Core data model, RSS, subscriptions

- Subscribe to any podcast by RSS URL
- RSS parser handles RSS 2.0, iTunes namespace, and Podcasting 2.0 (chapters, transcripts)
- Subscriptions list with podcast artwork, title, and author
- Podcast detail screen with episode list (most recent first)
- Episode rows show title, duration, and relative date
- Pull-to-refresh updates all subscribed feeds
- Subscriptions and episodes persist in SQLite via drift
- All screens accessible: semantic labels on every interactive element, error messages announced via SemanticsService
- **Deferred:** Background feed refresh (every 6 hours) — moved to Phase 4 alongside download manager and background services
- **Deferred:** VoiceOver/TalkBack manual test — carry into Phase 2 PR checklist

### Phase 0 complete — Project setup, tooling, CI

- Flutter 3.41.9 project scaffolded (bundle ID `media.payown.earshot`, iOS + Android)
- Core dependencies added: `flutter_riverpod`, `just_audio`, `audio_service`, `drift`, `dio`, `logging`, `package_info_plus`, `path_provider`, `sqlite3_flutter_libs`
- Dev dependencies added: `mocktail`, `build_runner`, `drift_dev`, `very_good_analysis`
- Feature-first folder structure in place (`lib/core/`, `lib/features/`, `lib/data/`)
- Light, dark, and high-contrast themes wired to system settings
- Spacing token constants defined
- "Welcome to Earshot" screen with accessible `Semantics(header: true)` heading
- Widget test verifying semantic heading label
- CI passing: lint, format check, tests, iOS + Android debug builds
- Accessibility enforcement hooks installed via Community Access agents
- **Deferred:** Manual VoiceOver test on welcome screen (carry into Phase 1 PR checklist)

### Added
- Initial project structure
- Product requirements document (`docs/PRD.md`)
- Phase plans (`docs/phases/`) with just-in-time progression
- Repository hygiene: LICENSE, README, CONTRIBUTING, CODE_OF_CONDUCT, SECURITY
- GitHub Actions CI workflow
- Issue and PR templates
- Phase progression rule (`.claude/rules/phase-progression.md`) for just-in-time phase doc generation
- Integration with Community Access Accessibility Agents (community-access.org)
