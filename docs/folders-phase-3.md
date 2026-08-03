# Folders — Phase 3: Context menu, listening lens, queue/inbox embedding, OPML

**Goal:** Folders stop being a Library destination and become woven through listening — a long-press menu everywhere, the Queue groupable by folder, the Inbox filterable by folder, and folder structure that round-trips through OPML. All VoiceOver-first.

**Source of truth:** `docs/folders.md` §7.4, §7.5, §7.7, §7.8, §12 (Phase 3). Builds on Phase 1 + 2 (already on `main`).

**Branch:** `phase/folders-3`, off `main` after the Phase 1 + 2 merge (#760).

**Scope discipline:** Phase 3 only. NO inline expand/collapse tree, NO Downloads-by-folder, NO player "Playing from folder," NO stats-by-folder (all Phase 4). NO sync (§16), NO smart folders (§17).

---

## Issues (mostly independent — parallelize after staging for file overlap)

### P3-A — Long-press context menu (episodes + podcasts)
Add `.contextMenu` to episode rows (`EpisodeRow`) and podcast rows, populated from the **same** `buildEpisodeActions` / `PodcastActionsBuilder` used by the rotor, so the menu mirrors the rotor and respects the user's configured Quick Action order. Convenience layer only — the rotor remains the guaranteed VoiceOver path; every menu action already exists as a rotor action from Phase 2. `earshot-accessibility` gate (verify `.contextMenu` doesn't steal the row's default activation; VoiceOver double-tap still navigates/plays).

### P3-B — "Group by folder" in the Queue
`QueueLogic.group` is already key-generic. Add a folder-keyed (subtree-aware) grouping beside `QueueRepository.groupedQueue()`, generalize `QueueGroup` to carry an optional folder key, and turn the Queue's group toggle from a bool into `none / podcast / folder` (with a migration for the stored `SettingsKey.groupQueueEpisodes` setting). Reuse the existing group-header rotor (Play/Shuffle/Move) unchanged — "Play folder," "Shuffle folder" fall out for free. `earshot-accessibility` gate. Highest-leverage reuse in the phase.

### P3-C — Folder as a listening lens (Inbox filter + folder new-episodes + play/queue-all)
- A **folder filter** on the Inbox: a folder-scoped `InboxQuery` predicate over the folder's podcasts (subtree-aware), backing an "Inbox: All folders ▾" control.
- A **"New episodes"** section in `FolderDetailScreen` (the folder's own inbox).
- Real **"Play all / Add all to queue"** from a folder honoring `queueAgeLimitDays` (improve the current one-newest-per-podcast `addFolderToQueue`).
`earshot-accessibility` gate.

### P3-D — OPML round-trip
- **Export:** `OPMLDocument.export` currently drops folders (takes only `title`/`feedURL`). Add nested-group export walking the folder subtree (`FolderRepository.subtreeSubscriptions` / a new nested variant) so a user's structure round-trips.
- **Subscribe-to-folder:** after subscribing from Search/Add, offer "Add to folder…" when the user already has ≥1 folder (decision F8).
`earshot-accessibility` gate on any UI.

---

## Sequencing (avoid the cross-branch conflicts we hit in Phase 2)

A/B/C/D are independent in intent but overlap on files:
- **A** touches `EpisodeRow` (+ podcast rows in `SubscriptionsView`).
- **B** touches the Queue feature only.
- **C** touches `InboxScreen`/`InboxRepository` and `FolderDetailScreen`.
- **D** touches OPML + `SearchView`/subscribe flow.

Recommended: **B and D in parallel first** (no overlap with each other or with A/C), then **C**, then **A** (A's `.contextMenu` on `EpisodeRow` is cleaner to add after C's episode-row changes land). Each on its own branch off `phase/folders-3`; combine on a `test/folders-phase-3` integration branch; device-verify one build (`--test`) before merging to `main`.

---

## Definition of done (Phase 3)

- [x] Episode and podcast rows offer a long-press context menu for touch users that mirrors the configured Quick Actions. The Actions rotor remains the guaranteed VoiceOver path, with no duplicate actions, and default activation is unchanged.
- [x] The Queue can group by folder, with the group-header rotor operating at folder granularity.
- [x] The Inbox can be filtered to a folder; a folder shows its own new episodes and can play/queue them all (age-limit respected).
- [x] Exporting OPML preserves the nested folder structure; subscribing from Search can file the new show into a folder.
- [x] Accessibility source review, combined `xcodebuild test`, Swift 6 Release build, and physical-device VoiceOver verification are complete before the `main` merge.

---

## Completion record — 2026-08-02

### What shipped in the phase

- Long-press Quick Action menus for episode and podcast rows, backed by the same stable action descriptors as the VoiceOver Actions rotor.
- Queue grouping by podcast, folder subtree, or no grouping, including folder-level Play, Move, Sort, and Shuffle actions.
- A subtree-aware Inbox folder filter, folder-scoped New episodes, and age-limited Play all / Add all to queue.
- Nested OPML folder export and an optional folder choice after subscribing from Search or Add Podcast.
- Deferred Quick Action construction throughout scrolling episode, podcast, Queue, folder, Search, Bookmark, and Download lists. Rows now create runnable closures only when an action is activated.

### Verification

- Simulator: 1,587 tests executed, 15 intentional StoreKit skips, 0 failures.
- Compiler: signed Swift 6 Release build succeeded for the physical iPhone target.
- Device: VoiceOver Inbox actions, configured order, default activation, the largest podcast episode list, Library, Queue grouping/actions, and touch context menus passed.
- Large-Inbox observation: on the 2,000-plus-item Inbox, the first rapid traversal after launch still paused while rows were initially realized. Reloading the Inbox made rapid forward and backward navigation responsive. Michael accepted this as a non-blocking extreme-library caveat.
- Downloads, Search, and folder episode lists did not receive a large-list device stress test because the device did not have extensive data in those views. They use the same deferred row-action path exercised by the Inbox and largest podcast, and are covered by the combined test suite.

### Learnings and decisions

- Building UUID-backed action objects and capturing multiple runnable closures per visible row creates avoidable VoiceOver scrolling work at large scale. Scrolling lists now retain stable enum/string descriptors and resolve only the selected action.
- SwiftUI can expose both a context menu and explicit accessibility actions as duplicate VoiceOver actions. Context menus are therefore a touch convenience when VoiceOver is off; the explicit Actions rotor is the single VoiceOver source of truth.
- Stable action IDs are required for predictable SwiftUI identity. Static and deferred list actions no longer regenerate UUIDs during body evaluation.
- The phase added no dependencies and required no schema change.

### Deferred

- Further cold-traversal optimization for unusually large Inboxes is deferred unless normal-sized libraries or additional device reports show a practical problem.
- Search still owns a separate broad episode query when the Search screen is opened. That pre-existing large-library query should receive its own bounded-fetch performance investigation rather than expanding this folders PR.
- Inline folder-tree expansion, Downloads-by-folder, player "Playing from folder" context, and folder-scoped stats move to Folders Phase 4.
