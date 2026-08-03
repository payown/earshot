# Folders — Phase 4: Unified folder views and listening context

**Goal:** Make folders a consistent organizing lens across the folder browser, Downloads, Now Playing, and listening statistics without changing the user's underlying podcast, episode, or download data.

**Estimated duration:** 2–3 weeks, part-time.

## Prerequisites

- Folders Phases 1–3 merged to `main`, including nested folders, episode membership, shared folder actions, folder-scoped Inbox, Queue grouping, and OPML round-trip.
- A fresh `phase/folders-4` branch and linked worktree created from the updated `main`.
- Resolve the pre-existing broad Search episode query separately; do not hide unrelated large-library work inside this phase.

## Tasks

### 1. Inline expand and collapse in the folder browser

- [x] Replace the top-level-only folder list with a cycle-safe flattened tree built from `FolderLogic.orderedHierarchy` or a focused pure helper.
- [x] Add explicit Expand and Collapse controls and Actions rotor entries for folders with children. Do not require disclosure-triangle precision or drag gestures.
- [x] Preserve full breadcrumb labels, sibling reorder behavior, create/delete behavior, and deliberate VoiceOver focus after expansion, collapse, move, or deletion.
- [x] Persist expansion only if doing so does not add a schema migration; otherwise keep it as session state and document the decision.
- [x] Add pure hierarchy/visibility tests and UI-facing accessibility-label tests.

### 2. Filter Downloads by folder

- [x] Add All folders plus subtree-aware folder choices to the Downloads screen, following the Inbox folder-filter vocabulary and ordering.
- [x] Apply the folder filter to Downloaded episodes and define explicitly whether Recently Expired follows the same filter.
- [x] Compose folder, Unheard/All, and text-search filters predictably, with a useful empty state for each combination.
- [x] Keep the live SwiftData query bounded by `downloadPath != nil`; folder filtering must not reintroduce a whole-Episode-table load.
- [x] Announce filter changes and visible counts without announcing on every keystroke.

### 3. Carry "Playing from folder" context into the player

- [x] Introduce a small, non-persistent playback-origin value that can identify a folder without changing the episode or Queue data model.
- [x] Set the origin when playback begins from a folder's Play all action or a folder-grouped Queue action, and clear or replace it when playback starts from another source.
- [x] Show "Playing from {folder}" in Now Playing with a concise VoiceOver label and a route back to that folder where navigation state permits.
- [x] Define how the origin behaves across queue advancement, manual episode changes, relaunch, and folder deletion before implementation.
- [x] Add pure state-transition tests so stale folder context cannot follow unrelated playback.

### 4. Add folder-scoped listening statistics

- [x] Add All folders plus subtree-aware folder choices to listening statistics.
- [x] Aggregate sessions using the podcast's current folder membership, and document that moving a podcast changes how historical sessions are grouped unless a schema-backed historical snapshot is explicitly approved.
- [x] Reuse the existing period selector, totals, plain-text presentation, and CSV privacy guarantees.
- [x] Handle podcasts in multiple folders without double-counting totals, and keep an Unfiled view for podcasts without membership.
- [x] Add unit tests for subtree inclusion, multiple membership, Unfiled, period filtering, and no-double-counting behavior.

Task 4 keeps the selected folder lens in session state and resolves membership live. Moving a podcast therefore moves all of its historical listening between folder views; no historical folder identifier is written into `ListeningSession`. Podcast identity sets de-duplicate shows assigned at multiple levels of the same subtree. The existing CSV export remains an all-history export with the same five fields and no folder identifiers, preserving its established privacy and compatibility contract. Completed-episode aggregation now fetches only rows whose `playedAt` is present instead of materializing the whole Episode table.

### 5. Integration, accessibility, and performance gate

- [x] Run the required SwiftUI accessibility review for every changed view.
- [ ] Verify VoiceOver focus, labels, values, Actions rotor order, default activation, Dynamic Type, Reduce Motion, and 44-point targets on device.
- [ ] Test with deep nesting, duplicate podcast membership, an empty folder, a deleted active folder, and a large episode store.
- [x] Run the focused tests, the full simulator suite with intentional StoreKit quarantines, and a signed Swift 6 Release device build.
- [ ] Update `CHANGELOG.md`, capture Phase 4 learnings, and device-verify the integration branch before requesting a merge to `main`.

Integration gate status: the changed SwiftUI surfaces passed the code-level
accessibility review. Focused Phase 4 coverage passed 283 tests with no failures;
the full simulator suite passed 1,620 tests with 15 intentional skips and no
failures. A signed Release build succeeded and was installed on the physical
device. The remaining gate is the short integration checklist below, including
large Dynamic Type and Reduce Motion verification; do not merge to `main` until
that device pass is confirmed.

## Definition of done

- A VoiceOver user can expand and collapse the folder tree, hear hierarchy and state, and recover focus after every mutation without relying on drag or precise touch.
- Downloads can be narrowed to a folder subtree while remaining bounded to downloaded candidates and composing correctly with played and search filters.
- Playback started from a folder communicates that folder in Now Playing and never presents stale origin information after the playback source changes or the folder is deleted.
- Listening statistics can be viewed by folder subtree or Unfiled without double-counting a podcast that belongs to more than one folder.
- No existing folder, Queue, Inbox, OPML, playback, download, or statistics behavior regresses; automated and physical-device accessibility gates pass.

## Commands to use during this phase

```bash
git fetch origin
git worktree add .claude/worktrees/folders-phase-4 \
  -b phase/folders-4 origin/main
cd .claude/worktrees/folders-phase-4

TEST_RUNNER_EARSHOT_SKIP_STOREKIT_TESTS=1 xcodebuild test \
  -project Earshot.xcodeproj \
  -scheme Earshot \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

xcodebuild build \
  -project Earshot.xcodeproj \
  -scheme Earshot \
  -configuration Release \
  -destination 'platform=iOS,id=<DEVICE_UDID>' \
  -allowProvisioningUpdates
```

## Claude Code prompts for this phase

**Prompt 1: Plan the expandable folder tree**

```text
Read docs/folders-phase-4.md and inspect FoldersScreen, FolderDetailScreen, FolderLogic, and existing folder tests. Propose the smallest VoiceOver-first inline expand/collapse design. Preserve current navigation, reorder, delete, labels, and focus behavior. Do not write code until I approve the file-by-file plan.
```

**Prompt 2: Implement Downloads-by-folder**

```text
Implement Task 2 from docs/folders-phase-4.md on its own branch. Reuse the Inbox subtree filter semantics, keep Downloads' SwiftData query bounded by downloadPath, define Recently Expired behavior in tests, and verify filter composition with search and Unheard/All. Run the accessibility gate before handing it back.
```

**Prompt 3: Design playback folder origin**

```text
Inspect PlayerService, QueueRepository, FolderDetailScreen, QueueScreen, RootView navigation, and Now Playing. Design a non-persistent Playing from folder context with explicit state transitions for folder play-all, folder-group Queue playback, normal playback, queue advancement, relaunch, and folder deletion. Write the design and tests first; wait for approval before implementation.
```

**Prompt 4: Implement folder-scoped statistics**

```text
Implement Task 4 from docs/folders-phase-4.md on its own branch. Reuse FolderRepository subtree membership and StatsRepository period logic. Treat current membership as the grouping rule, prevent double counting, include Unfiled, keep the presentation plain-text and VoiceOver-first, and add focused aggregation tests.
```

**Prompt 5: Integrate and verify Folders Phase 4**

```text
Combine the approved Folders Phase 4 task branches on a test/folders-phase-4 integration branch. Run the full simulator suite and signed Swift 6 Release build, perform the SwiftUI accessibility review, install on my phone, and give me a short ordered device checklist. Do not merge to main until I confirm the device results.
```
