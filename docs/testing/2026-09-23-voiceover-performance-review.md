# VoiceOver responsiveness review — September 23, 2026

## Scope and evidence

Michael reports occasional sluggishness while flicking through Earshot,
especially on launch. Reviewed main `564c2658` and the changes on
`codex/voiceover-performance-pass`, using Xcode 27.0 (27A266a), Swift 6.4,
and XcodeGen 2.46.0. This is a code-first review, not an Instruments trace or a
measurement of VoiceOver latency on Michael's phone.

The review covered root activation and tab construction; Inbox snapshots; Queue
grouping; Library snapshots/counts; podcast episode paging; Downloads rendering;
folder presentation; player/chapter updates; Search loaders; Stats loading; and
artwork loading. `docs/perf-baseline.md`, referenced by AGENTS.md, is absent from
this revision. Historical device notes and the July security/stability review
were read as background, not treated as measurements of this build.

## Changes

1. **Defer unopened Queue and Downloads content.** RootView built both data-bound
   screens as tab children, including their live SwiftData query properties.
   DeferredTabContent now constructs them only when first selected. Tab items and
   NavigationStacks remain present. Once opened, content stays mounted so a tab
   switch does not reset navigation, filtering, or focus identity. This removes
   those screen-construction/query opportunities from launch when another tab is
   selected; selected Queue/Downloads launch still loads its required content.
   It does not eliminate background services, tab badges, or all later query work.

2. **Stop resolving download identities during every render.** DownloadsScreen
   performed LocalStateStore.episodes(matching:) in a computed property consumed
   by body and the toolbar. A snapshot now resolves on the actual completed-
   download key list changing, subscriptions changing, or Cloud projection
   applying. Appearance retries a previous failure without refetching a successful
   unchanged snapshot. Same-count replacements are detected by full keys. Search, row
   focus, and toolbar evaluation read the snapshot. Live Episode models retain
   played-state/title/date observation. Query failure permits retry and preserves
   valid prior rows. Deleted models are filtered before sorting/rendering.
   The resolution itself still uses the existing download-key-scoped main-context
   query; moving it to a worker is a separate improvement if profiling warrants.

3. **Reuse the existing RecentlyExpired query.** Downloads previously maintained
   an expired-row query and separately fetched the same table during body.
   The query is now sorted by expiration date and its non-orphan rows are reused.
   The Clear all downloads enabled state reuses the already computed source.

4. **Resolve current chapter once per list evaluation.** Each chapter row
   previously invoked the full active-chapter scan. Hoisting the identical
   calculation preserves its clock/seek behavior and all row speech while
   reducing a potential repeated linear scan across realized rows. The player
   clock can still invalidate this screen; no measured frame reduction claimed.

## Findings retained for follow-up

- Queue folder rendering still calls groupedQueueByFolder(), which resolves
  folder memberships and fetches Queue rows during rendering after first entry.
  A coherent event-driven grouping snapshot should be considered separately,
  with folder edits, remote sync, reorder, and failure tests.
- Downloads folder filtering still derives subtree memberships on render.
  The new episode snapshot does not solve that separate folder-scope cost.
- EpisodeListDataSource bounds each page to 100 but executes its fetch/count
  operations on the main actor. A broad search predicate on a very large show
  can still block; moving identities/counts off-main needs generation and
  cancellation guards, not a superficial async wrapper.
- Library counts already run in a worker and debounce change bursts. Library
  metadata fetches remain scalar-only. Sorting a large podcast list is still
  main-thread work, but no inverse episode traversal was found there.
- Inbox already gates reloads by active tab and uses cancellable background
  snapshots. Search has separate bounded actor loaders. Stats and artwork have
  background loading paths. These reduce known risks but do not prove those
  areas are free of latency under real device contention.
- The full suite emitted audio-session main-thread responsiveness warnings,
  including activation/deactivation calls. Treat these as an additional profiling
  lead, not proof of the reported launch delay; audio-session behavior was not
  changed in this pass.
- Launch still performs download reconciliation, expiration, stats retention,
  Cloud projection, and folder-run connection. Much of the store work already
  runs away from the main actor. Scheduling overlap and database contention
  require a real launch trace before attributing the remaining flick delay.

## First due feature

Michael explicitly approved the new “Hide caught-up podcasts” Library toggle
and “All caught up” empty state. The preference defaults off and persists using
existing settings. It uses background unplayed counts, retains unknown counts
while loading, and preserves the existing sort order and row speech. Filtering
never removes subscriptions or changes episode state. Selection is limited to
visible rows, with recovery when a count change hides the focused podcast.
Library options remains reachable when every podcast is caught up.

The BBC issue was rechecked September 23: the latest published enclosure in each
of the four recorded feeds still downgraded to HTTP for HEAD and range GET.
No insecure request was followed and no ATS exception or warning was changed.
The badge and retained-finished-Queue features have concrete implementation
proposals in the due-task plan; they are not implemented by this branch.

## Verification gates

- Initial focused regression tests: 56 passed. Final suite includes the added
  download failure-membership regression.
- Full eligible unit suite, excluding the two documented StoreKit suites: first
  run encountered two reset fixture failures after opening a pre-existing V2
  default store in a reused simulator. Verification traced this to the fixture
  reopening the default app path after deleting an injected disposable path.
  The first run was also stopped after an unrelated SwiftData test-store save
  stalled. The fresh iOS 27 simulator completed: 2,362 passed, 29 skipped,
  zero failures (2,391 reported). Both reset cases passed. The final result
  bundle confirms Passed and the runner ended TEST SUCCEEDED. Post-test
  simulator diagnostics stalled; stopping only that diagnostics child let the
  already-complete results finalize. No reset code was changed.
- Independent verification agent: complete. One Downloads retry/stale-membership
  finding was corrected and independently re-reviewed. No remaining code-review
  blocker. The independent reviewer approved production revision `3f8c9e0`
  for phone testing after reviewing the clean suite, UI result, and signed build.
- Screen-level test passed: Library filter on/off, first Queue and Downloads
  entry, and return to Library. This does not verify VoiceOver speech/focus or
  Queue/Downloads navigation preservation on re-entry.
- Signed optimized Release 1.2.3 (267), production revision `3f8c9e0`, built and
  passed strict code-signature verification. Installed successfully on Michael’s iPhone
  over Wi-Fi after independent approval.
- Physical cold-launch and flick-navigation acceptance: pending Michael.
- No TestFlight distribution authorized or performed.

## Phone checks after review

1. Cold-launch into the usual tab and immediately flick through the first rows
   and tab controls. Compare pauses with the currently installed build.
2. Open Queue and Downloads for the first time, then switch away and back.
   Confirm content appears, existing filters/navigation survive, and row speech
   and rotor actions match their prior behavior.
3. In Downloads, search and clear search; finish/remove a download; mark an
   episode played; check Recently Expired and folder filtering. Verify the list
   and Clear all downloads availability stay current.
4. In Library options, enable Hide caught-up podcasts, open an unheard podcast,
   and return after marking its final episode played. Confirm its row leaves,
   selection/focus remains usable, and the toggle remains reachable when all
   podcasts are caught up. Disable it and verify all subscriptions reappear.
5. Open Chapters during playback and seek across a chapter boundary. Confirm
   current/skipped states and chapter actions remain correct.

Simulator tests establish logic and host-view behavior. They do not establish
VoiceOver latency, spoken delivery, on-device focus, or physical performance.
