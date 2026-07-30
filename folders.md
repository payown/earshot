# PRD: Folders as a First-Class Citizen in Earshot

**Status:** Draft for review
**Owner:** Michael Babcock, Payown Media LLC
**Author:** Product / Engineering
**Last updated:** 2026-07-30
**Related docs:** `docs/PRD.md`, `.claude/rules/accessibility.md`, `.claude/rules/flutter-style.md`, `.claude/rules/database-migrations.md`

---

## 1. Summary

Folders in Earshot today are a thin, flat feature: a podcast can belong to one or more named folders, and a folder holds a list of podcasts. They live in a single section of the Library screen and expose a couple of VoiceOver actions. They are useful but shallow.

This PRD turns folders into a core organizing concept that runs through the whole app. It adds:

- **Deeply nested folders** (subfolders, arbitrary depth) with a fully accessible tree.
- **Per-podcast folder association** surfaced directly in a podcast's own settings.
- **Multi-select** for podcasts and for episodes, with a batch "Move to folder" that acts on the whole selection at once.
- **Episode-level folder membership** so a folder can also hold a hand-picked set of episodes, not just whole shows.
- **A long-press (double-tap-and-hold) context menu** on any episode or podcast that surfaces the most common actions in one place, with a VoiceOver-equivalent path.
- **Folder-scoped inbox, queue, and playback** so a folder is a lens you can listen through, not just a bin.
- **Richer folder settings and management**: reorder, move between parents, folder-level inbox and queue rules, and OPML per subtree.

The whole feature is designed screen-reader-first. Every interaction has a VoiceOver path that does not depend on sight, drag, or precise gestures. Accessibility is the acceptance bar, not a review step.

---

## 2. Why now

Michael's core users are blind and low-vision listeners in the BITS and ACB communities who often subscribe to many shows. Flat, alphabetical lists do not scale for them. Sighted apps lean on drag-and-drop and dense grids that are hostile to VoiceOver. Earshot can win by making organization genuinely fast and pleasant with a screen reader: nested folders navigated by the actions rotor, batch moves that announce their result, and a context menu that puts the common actions one gesture away.

Folders are the highest-leverage place to make Earshot feel built *for* screen reader users rather than merely usable by them.

---

## 3. Current state (grounded in the codebase)

Read before proposing changes.

### 3.1 Data model

- `lib/data/db/tables/podcast_folders.dart` — `PodcastFolders`: `id`, `name`, `sortOrder`, `queueAgeLimitDays` (nullable), `createdAt`. **Flat. No `parentId`.**
- `lib/data/db/tables/podcast_folder_memberships.dart` — `PodcastFolderMemberships`: many-to-many `folderId` ↔ `podcastId` with a per-folder `sortOrder`, unique on `{folderId, podcastId}`, cascade delete. A podcast can be in multiple folders. **No episode membership.**
- `lib/data/db/app_database.dart` — `schemaVersion = 15`. Folder tables were added in the `from < 6` migration.

### 3.2 Repository (`lib/features/folders/data/folder_repository.dart`)

Exposes: `watchFolders`, `watchFolder`, `watchPodcastsInFolder`, `watchFolderIdsForPodcast`, `watchUnfiledPodcasts`, `createFolder`, `renameFolder`, `deleteFolder`, `setFolderQueueAgeLimit`, `addPodcastToFolder`, `removePodcastFromFolder`, `setMemberships`, `reorderFolders`, `getLatestUnplayedPerPodcast`, `getFolderSubscriptions`, `getAllWithFolderStructure` (OPML).

`reorderFolders` exists but has no UI wired to it today.

### 3.3 UI

- **Library** (`subscriptions_screen.dart`): an "All Podcasts" entry, then a flat "Folders" section. Create folder from an app bar icon. Folder tile exposes one VoiceOver action: "Delete folder". No reorder, no nesting.
- **Folder detail** (`folder_detail_screen.dart`): lists podcasts in the folder. App bar has "Play all unplayed", and a popup menu (Export OPML, Rename, Set queue expiration, Delete). FAB opens the podcast picker. Each podcast row exposes a "Remove from folder" VoiceOver action.
- **Picker sheet** (`folder_podcast_picker_sheet.dart`): two modes — add podcasts to a folder (checklist), and manage folders for a podcast (checklist + create new). Uses `setMemberships`.
- **All Podcasts** (`all_podcasts_screen.dart`): each podcast row has a "Manage folders" quick action via the picker sheet. Solid VoiceOver custom-action patterns already in place.
- **Podcast settings** (`podcast_settings_screen.dart`): Playback + Inbox only. **No folder association here.**
- **Folder-scoped inbox provider** (`folder_inbox_providers.dart`): `inboxEpisodesByFolderProvider` exists but is **not surfaced in any screen**.

### 3.4 Accessibility patterns already established (reuse, don't reinvent)

From `.claude/rules/accessibility.md` and `flutter-style.md`:

- Interactive tiles: `Semantics(button: true, label: ..., customSemanticsActions: {...}, child: ExcludeSemantics(child: ListTile(...)))`.
- `SemanticsService.sendAnnouncement` for state changes.
- Every `showModalBottomSheet` gets a `barrierLabel`.
- Any `Semantics` node with `toggled:` or `checked:` non-null **must** also set `enabled: true`, or iOS announces "dimmed".
- Trust `CheckboxListTile` / `Switch` / `Slider` semantics; override only when the default label is wrong.
- No `Focus(autofocus: true)` on container widgets.

---

## 4. Goals and non-goals

### 4.1 Goals

1. Folders can be nested to arbitrary depth, and the hierarchy is fully navigable with VoiceOver.
2. A podcast can be assigned to folders from its own settings screen, not only from the Library.
3. Users can select many podcasts, or many episodes, and move the whole group into a folder in one action.
4. Folders can hold hand-picked episodes (a curated collection), in addition to whole shows.
5. Every folder-related action has a VoiceOver path that needs no sight, no drag, and no timing-sensitive gesture.
6. A long-press context menu gives quick access to the most common actions on any episode or podcast.
7. Folders drive real listening: folder-scoped inbox, folder "play all", and folder-level rules.
8. Folders are reachable from **every surface** a podcast or episode appears — Library, Inbox, Queue, Downloads, player, search, settings — through shared action plumbing and reused grouping machinery, not one-off per-screen code (§7.8, §7.9).

### 4.2 Non-goals (for this effort)

- **Android.** This entire effort (folders, multi-select, iCloud sync, smart folders) targets **iOS/iPadOS only** (decided 2026-07-30). No Android work, no TalkBack parity requirement, no cross-platform backend. VoiceOver is the single accessibility target.
- **A Payown-run backend / account system.** iCloud sync (Apple devices) is in scope — see §16. Earshot never runs a server that sees user data.
- Sharing a folder structure socially or publicly.
- ~~Smart/dynamic folders defined by rules.~~ **Now in scope — see §17.**
- Reworking the tab bar / bottom navigation. Folders live inside Library.

---

## 5. Guiding principles

1. **Screen-reader-first.** If it only works by sight or drag, it is not done. Design the VoiceOver path first, then layer visuals on top.
2. **Follow the system.** Respect Dynamic Type, Reduce Motion, contrast, and theme. Never override.
3. **No destructive surprises.** Deleting a folder never deletes podcasts or episodes. Moves are reversible or clearly confirmed.
4. **Announce meaningful change, stay quiet otherwise.** Use `SemanticsService` announcements for results ("Moved 4 podcasts to News"), not for noise.
5. **One concept, many entry points.** Adding to a folder should feel the same from Library, from a podcast, from an episode, and from multi-select.

---

## 6. Key model decision: what can a folder contain?

Today a folder contains **podcasts**. Michael has asked for the ability to group **episodes** too. Two model changes are proposed:

**A. Nesting (subfolders).** Add `parentId` to `PodcastFolders`. A folder's contents become: its child folders, plus its member podcasts, plus its member episodes.

**B. Episode membership.** Add a `PodcastEpisodeFolderMemberships` join table (folderId ↔ episodeId). This lets a folder double as a curated collection / playlist of specific episodes.

A folder can therefore hold a mix of: subfolders, whole podcasts, and individual episodes. The folder detail screen renders these as three clearly-labeled sections.

> **Decided (Michael, 2026-07-30): unified model.** A folder holds a mix of subfolders, whole podcasts, and individual episodes. There is no separate "Collections" concept. This is the simpler mental model for a screen reader user — "a folder holds things" — and the rest of this PRD is written against it. (Smart/dynamic folders in §17 layer on top of this same model.)

---

## 7. Feature requirements

### 7.1 Nested folders (subfolders)

**What:** Folders can contain other folders, to any depth.

- Create a subfolder from inside a folder ("New subfolder here"), or move an existing folder under another folder.
- A folder shows a combined count: e.g. "News, 3 subfolders, 12 podcasts, 5 episodes".
- Deleting a parent folder prompts clearly: choose to delete the parent only (children move up to the grandparent) or delete the whole subtree. Podcasts and episodes are never deleted, only unfiled.
- Cycles are impossible: a folder cannot be moved into itself or one of its descendants. The move UI hides invalid targets and the repository rejects them.

**Accessibility (the hard part):**

- **Two presentation modes, user-configurable (decided).** A Library display setting lets the user choose how the tree is shown:
  - **Drill-down (default):** tapping a folder opens its detail screen showing immediate children. Most reliable VoiceOver model on iOS (Flutter has no dependable "outline level N" semantics for custom inline trees), so it is the default and must be fully sufficient on its own.
  - **Inline expand/collapse tree:** the Library root shows folders as an expandable tree. Available to anyone who prefers it; built to the exact `expanded:`-flag rules in §9.1.
  The setting itself is an accessible control in Settings/Library, defaulting to drill-down. Both modes ship (Phase 4 delivers the inline mode + the toggle; drill-down lands earlier).
- Every folder detail screen shows a **breadcrumb / path** in its heading and semantic label so a VoiceOver user always knows where they are: "News › Daily › heading". A "Go up one level" action is always available.
- Depth is conveyed by wording, not visual indentation alone. Row labels never rely on indentation to communicate nesting.

**Acceptance:** A VoiceOver user can create a subfolder, move a folder under another, navigate three levels deep, know their location at every step, and get back up, using only swipe navigation and the actions rotor.

### 7.2 Per-podcast folder association (in podcast settings)

**What:** Add a "Folders" section to `PodcastSettingsScreen`.

- Shows the folders this podcast currently belongs to (or "Not in any folder").
- "Add to folder…" opens the existing manage-folders picker (`ManageFoldersForPodcast`), extended to show the nested folder tree so the user can pick a subfolder.
- Changes announce the result: "Added to News › Daily".
- This is additive to the existing "Manage folders" quick action in All Podcasts; both routes use the same sheet and repository call (`setMemberships`).

**Acceptance:** From a single podcast's settings, a VoiceOver user can put it into or remove it from any folder or subfolder and hear the result.

### 7.3 Multi-select and batch "Move to folder"

**What:** A selection mode for organizing many items at once.

- **Podcasts:** In All Podcasts and in a folder's podcast list, a "Select" action enters selection mode. Each row becomes selectable. A bottom action bar shows the count and offers "Move to folder", "Add to folder" (keep existing memberships), and "Remove from folder" (when inside a folder).
- **Episodes:** In the Inbox, a podcast's episode list, and any episode list, the same selection mode enables "Move to folder" / "Add to folder" for episodes, plus the common episode batch actions already relevant (mark played, add to queue, download).
- "Move to folder" removes the items from their current folder context and places them in the chosen target as a group. "Add to folder" is non-destructive (adds membership without removing existing ones). The distinction is stated in the button labels and confirmations.
- Selecting a folder as the move target uses the same nested folder picker (§7.1), including a "New folder…" affordance so the user can create the destination on the spot.

**Accessibility:**

- Entering selection mode is announced: "Selection mode on. Double-tap items to select." Exiting is announced too.
- Each row announces its state and toggle following the `checked:` + `enabled: true` rule so it is never "dimmed". Selecting announces a running count: "Selected, 3 of 40".
- The batch action announces the result and does not depend on drag: "Moved 3 podcasts to News › Daily".
- After a move, focus lands on a stable, predictable element (see §9.2) because the moved rows leave the list.

**Acceptance:** A VoiceOver user can select five inbox episodes and move them into a folder as a group, hearing the count as they go and the result at the end, without any long-press or drag.

### 7.4 Long-press context menu (double-tap-and-hold)

**What:** On any episode row or podcast row, a long-press (double-tap-and-hold under VoiceOver) opens a context menu / action sheet of the most common actions for that item.

- **Podcast menu (typical):** Open, Manage folders…, Enable/disable notifications, Enable/disable auto-queue, Include/exclude from inbox, Podcast settings, Unfollow, Share.
- **Episode menu (typical):** Play now, Add to queue, Mark played / unplayed, Download / remove download, Move to folder…, Add to folder…, Show notes, Share.
- The menu is a `showModalBottomSheet` with a `barrierLabel`, a semantic header, and each action as a clearly-labeled `ListTile`.
- The exact action set per content type reuses the existing Quick Action configuration where possible, so the context menu respects the user's configured order and does not diverge from the actions rotor.

**Accessibility:**

- The long-press menu is a **convenience layer, not the only path.** Every action in it is also available as a VoiceOver custom action on the row (actions rotor). Screen reader users are never required to discover or perform a long-press.
- Under VoiceOver, double-tap-and-hold activates the same menu; the sheet then behaves like every other Earshot sheet (focus routed past the scrim by `barrierLabel`, header announced, actions swipeable).

**Acceptance:** A sighted user can long-press an episode and pick "Move to folder". A VoiceOver user reaches the identical set of actions through the actions rotor without needing the long-press, and can also trigger the menu by double-tap-and-hold.

### 7.5 Folders as a listening lens (inbox, queue, play-all)

**What:** Make a folder somewhere you listen, not just store.

- **Folder-scoped inbox:** Surface `inboxEpisodesByFolderProvider` in the folder detail screen as a "New episodes" section, so a user can triage just the shows in that folder. Batch actions (§7.3) apply here.
- **Play all / queue all:** Keep and improve the existing "Play all unplayed" (`getLatestUnplayedPerPodcast`). Add "Add all to queue" and respect the folder's queue expiration rule.
- **Folder filter on the Queue and Inbox tabs (optional, phase 3):** a filter control to view only items from a chosen folder.

**Acceptance:** From a folder, a VoiceOver user can review that folder's new episodes and start playing them, hearing how many were queued.

### 7.6 Folder management: reorder, move, rename, delete

- **Reorder folders** (wire up existing `reorderFolders`): provide a non-drag reorder path — "Move up" / "Move down" custom actions on each folder row, in addition to any drag handle for sighted users. Announce the new position.
- **Move a folder** under a different parent via the nested folder picker.
- **Rename** and **delete** as today, with the nested-aware delete prompt from §7.1.
- **Reorder items within a folder** (podcasts/episodes) with the same non-drag "Move up/down" actions.

**Acceptance:** Every reorder and move has a keyboard/VoiceOver path that is not drag-dependent, and each change is announced.

### 7.7 Folder-level settings

Extend the folder settings surface (folder detail → options):

- **Queue expiration** (exists: `queueAgeLimitDays`).
- **Inbox behavior for the folder** (e.g. include/exclude all shows in the folder from the global inbox) — batch-applies to member podcasts using existing per-podcast flags.
- **Export OPML for the folder and its subtree** (extend `getFolderSubscriptions` / `getAllWithFolderStructure` to walk children).
- Future: folder-level default playback speed and auto-queue that member podcasts inherit unless overridden. Flagged, not committed.

### 7.8 Folders across every surface (the "deeply embedded" map)

The goal is that a folder is never a dead end you visit once. It is a lens and a destination available wherever a podcast or episode appears. This section maps every surface in the app and what folder integration looks like there, grounded in the actual screens.

| Surface | File | What exists today | Folder integration |
|---|---|---|---|
| **Bottom nav** | `core/presentation/main_shell.dart` | 4 tabs (Inbox, Queue, Library, Downloads) via `AccessibleNavBar`; live inbox badge from `_inboxCountProvider`. | No new tab. Add an optional **folder filter** to Inbox/Queue/Downloads (see below). Folder tiles in Library gain a "N new" badge mirroring the nav badge, scoped to the folder subtree. |
| **Library** | `subscriptions/.../subscriptions_screen.dart` | "All Podcasts" entry + flat "Folders" section; create-folder icon; "Delete folder" rotor action. | Nested drill-down (§7.1), reorder actions (§7.6), per-folder "N podcasts, N new" counts, and multi-select of podcasts (§7.3). This is the folder home base. |
| **Folder detail** | `folders/.../folder_detail_screen.dart` | Podcasts list; "Play all unplayed"; options menu; add-podcasts FAB. | Three sections — subfolders, podcasts, episodes (§6); folder-scoped **new-episodes** section from `inboxEpisodesByFolderProvider`; breadcrumb heading; "Add all to queue"; batch actions. |
| **Inbox** | `downloads/.../inbox_screen.dart` | Flat list of all `newEpisode` episodes, newest first (`_inboxEpisodesProvider`); title bar toggles auto-download. | **Folder filter** at the top ("Inbox: All folders ▾") backed by `inboxEpisodesByFolderProvider`; optional **group-by-folder** sectioning reusing the queue's collapse model; multi-select episodes → "Move/Add to folder" (§7.3); per-row "Move to folder…" rotor action via shared plumbing (§7.9). |
| **Queue** | `player/.../queue_screen.dart` | Flat mode **and** a mature **group-by-podcast** mode with collapsible group headers and a rich rotor (Play group, Shuffle, Sort, Move up/down/top/bottom), driven by `groupQueueEpisodesProvider`, `groupedQueueProvider`, `collapsedQueueGroupsProvider`, `QueueGroup`. | Add **"Group by folder"** as a third grouping mode that reuses the exact same `QueueGroup` header/collapse/rotor machinery. "Play folder", "Shuffle folder", "Move folder group" fall out for free. Per-episode "Move to folder…" via shared plumbing. This is the single highest-leverage reuse in the whole effort. |
| **Downloads** | `downloads/.../downloads_screen.dart` | Sectioned by **Inbox / Queue / Library**, each a `Semantics(header: true)`; per-episode actions sheet. | Add an optional **"By folder"** grouping (or a folder filter) that sections downloads by folder subtree, matching the existing section pattern. Per-episode "Move to folder…" via shared plumbing. |
| **Episode actions (everywhere)** | `core/presentation/widgets/episode_actions_sheet.dart`, `core/episode_action_builder.dart` | One shared `showEpisodeActionsSheet` + `EpisodeQuickActionItem`; every screen builds actions through `buildEpisodeActions`. | Add `EpisodeAction.moveToFolder` / `addToFolder` to the enum and builder **once**; it appears in Inbox, Queue, Downloads, Podcast detail, and the actions rotor everywhere, and is user-orderable. See §7.9. |
| **Podcast actions (everywhere)** | `settings/domain/quick_action_definition.dart` | `PodcastAction` enum already includes `manageFolders`; user-configurable order. | Extend to a real folder-move flow and surface `manageFolders` in the long-press context menu (§7.4) and podcast settings (§7.2). Already partly wired — finish it. |
| **Podcast detail** | `subscriptions/.../podcast_detail_screen.dart` | Show header + episode list. | Show the podcast's folder chips ("In: News › Daily") with a tap to manage; episode rows get "Move/Add to folder" via shared plumbing. |
| **Podcast settings** | `subscriptions/.../podcast_settings_screen.dart` | Playback + Inbox only. | New **Folders** section (§7.2). |
| **Player / Now Playing** | `player/.../player_screen.dart`, `.../now_playing_bar.dart` | Full-screen player + mini bar. | Show **"Playing from {folder path}"** when the current queue context is a folder; expose "Add this episode to folder…" in the player's more-actions. |
| **Search / Add podcast** | `search/.../search_screen.dart`, `.../add_podcast_screen.dart` | Search, add by URL, subscribe. | On subscribe, offer **"Add to folder…"** (pick existing or create), so new shows land organized instead of unfiled. |
| **OPML import/export** | `search/.../opml_import_screen.dart`, `folders/.../folder_repository.dart` | `getAllWithFolderStructure` (export), OPML import. | Import maps OPML `outline` groups → folders (nested where the OPML nests). Export walks the **subtree** (`getFolderSubtreeSubscriptions`). Round-trips a user's structure. |
| **Settings** | `settings/.../*` | Inbox, Playback, Downloads, etc. | A **Manage Folders** settings entry (rename/reorder/move/delete in one place); "Default launch screen" could optionally target a specific folder; Inbox settings note folder scoping. |
| **Stats** | `stats/.../stats_screen.dart` | Listening stats. | Optional **filter stats by folder** ("time listened in News"). Phase 4, nice-to-have. |
| **Onboarding** | `onboarding/.../onboarding_screen.dart` | First-run subscribe flow. | Optional: suggest a starter folder or two after the first few subscriptions. Low priority. |

### 7.9 Implementation strategy: fold folders into shared plumbing (do this first)

The app already has two choke points that every surface flows through. Adding folders **there** propagates the feature everywhere at once, instead of screen by screen. This is the backbone of "deeply embedded" and should land early in Phase 2/3.

1. **Episode "Move/Add to folder" via the shared action builder.** Add `moveToFolder` and `addToFolder` to `EpisodeAction` (`quick_action_definition.dart`) and to `buildEpisodeActions` (`core/episode_action_builder.dart`). Because Inbox, Queue, Downloads, and Podcast detail all render episode actions through `buildEpisodeActions` → `EpisodeQuickActionItem` → `showEpisodeActionsSheet`, the new actions appear in every episode list, in the more-actions sheet **and** on the VoiceOver actions rotor, and respect the user's configured Quick Action order — with no per-screen edits. Gate them behind `allowedActions` per screen where appropriate (as Inbox/Downloads already do).

2. **Podcast "Move/Add to folder" via `PodcastAction`.** `manageFolders` already exists in the enum and in All Podcasts. Wire the same action into the long-press context menu (§7.4) and podcast settings (§7.2) so all three routes share one sheet and one repository call.

3. **Reuse the queue's grouping/collapse machinery for folders.** The queue's `QueueGroup`, `groupedQueueProvider`, `collapsedQueueGroupsProvider`, and the group-header rotor (Play/Shuffle/Sort/Move) are a proven, accessibility-audited collapse tree. Generalize "group by podcast" to also support "group by folder" rather than inventing a second collapse implementation. Any folder sectioning in Inbox/Downloads should follow the same header + rotor conventions.

4. **One folder picker, used everywhere.** The nested folder picker (§7.1) is the single destination selector for: per-podcast assignment, per-episode move, multi-select batch move, subscribe-to-folder, and OPML import target. Build it once, with "New folder…" inline, and reuse it.

**Why this ordering matters:** shipping the shared-plumbing changes first means every subsequent surface ("also add it to Downloads") is a small, low-risk wiring task rather than a bespoke build. It also guarantees consistency — the same labels, the same rotor actions, the same announcements everywhere — which is exactly what a screen reader user needs to build muscle memory.

---

## 8. Data model and migration plan

Follow `.claude/rules/database-migrations.md` exactly. Every schema bump ships with its `onUpgrade` step in the same PR, is tested against realistic aged fixture data, and is manually verified on-device by installing over the previous TestFlight build.

### 8.1 Schema changes

Bump `schemaVersion` 15 → 16 (nesting) and 16 → 17 (episode membership), or combine if shipped together. Each change is additive and nullable where possible.

**Nesting — add to `PodcastFolders`:**

```dart
// Nullable self-reference. Null = top-level folder.
IntColumn get parentId => integer()
    .nullable()
    .references(PodcastFolders, #id, onDelete: KeyAction.setNull)();
```

- `onDelete: setNull` means deleting a parent orphans children to top level by default; the app-level delete flow (§7.1) decides between "promote children" and "delete subtree" and performs it explicitly in a transaction. Do not rely on cascade for the subtree case.
- Add a depth/cycle guard in the repository, not the schema.

**Episode membership — new table:**

```dart
@DataClassName('PodcastEpisodeFolderMembershipRow')
class PodcastEpisodeFolderMemberships extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get folderId => integer()
      .references(PodcastFolders, #id, onDelete: KeyAction.cascade)();
  IntColumn get episodeId => integer()
      .references(Episodes, #id, onDelete: KeyAction.cascade)();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {folderId, episodeId},
  ];
}
```

### 8.2 Migration rules for this work

- New `parentId` column: pure `addColumn`, nullable, no backfill needed (existing folders become top-level). Safe against aged data.
- New episode membership table: `createTable`, additive. Safe.
- **No migration step may throw on a tester's real data.** Test `onUpgrade` from v15 against a fixture DB with multiple folders, memberships, NULL fields, and orphan-prone rows (`test/data/db/`).
- Keep the pre-`runApp` DB call safe: the existing rule that first-query code paths are wrapped and fall back to defaults still applies.

### 8.3 Repository additions

Extend `FolderRepository`:

- `watchChildFolders(int? parentId)`, `watchFolderPath(int folderId)` (breadcrumb), `moveFolder(int folderId, int? newParentId)` (with cycle rejection).
- `addPodcastsToFolder(int folderId, List<int> podcastIds)`, `movePodcastsToFolder(...)`, `removePodcastsFromFolder(...)` — batch variants.
- `addEpisodesToFolder(int folderId, List<int> episodeIds)`, `moveEpisodesToFolder(...)`, `removeEpisodesFromFolder(...)`, `watchEpisodesInFolder(int folderId)`.
- Recursive `getFolderSubtreeSubscriptions(int folderId)` for OPML.
- `deleteFolder(int folderId, {required FolderDeleteMode mode})` where mode is `promoteChildren` or `deleteSubtree`.

All batch and move operations run in a single transaction and are idempotent (`insertOrIgnore` semantics preserved).

---

## 9. Accessibility specification

This is the acceptance bar. Every requirement above must satisfy this section.

**Three load-bearing correctness facts** (from the `mobile-accessibility` specialist review — write these into implementation as hard requirements):

1. **Expansion state uses the `expanded:` flag**, which maps to `SemanticsFlag.hasExpandedState` / `isExpanded`. It is *not* backed by the iOS `UISwitch` object, so the "toggled/checked needs `enabled: true` or it says dimmed" rule does **not** apply here. Do **not** represent expansion with `toggled:`/`checked:`. Only set `expanded:` on folder rows that actually have children; leaf rows get no `expanded` flag at all.
2. **Selection state uses the `selected:` flag** (`SemanticsFlag.isSelected`), explicitly **not** `checked:`/`toggled:`. Multi-select rows are not switches. `selected:` makes VoiceOver append "Selected", avoids the switch backing object, and sidesteps the dimmed pitfall completely.
3. **Programmatic VoiceOver focus after a mutation** uses `RenderObject.sendSemanticsEvent(const FocusSemanticEvent())` via a `GlobalKey`, inside a post-frame callback. This is the supported way to move accessibility focus to a stable anchor after moved/removed rows leave the list.

### 9.1 Nested folder navigation

- **Model:** two user-selectable modes (decision F4). **Drill-down is the default** — tapping a folder navigates to its detail screen listing immediate child folders, then podcasts, then episodes, each under a `Semantics(header: true, label: ...)` section heading. The **inline expand/collapse tree** is the opt-in alternative, built to the `expanded:`-flag rules below. Drill-down must remain fully sufficient on its own; the inline mode is additive.
- **Location awareness:** the folder detail heading and its semantic label include the full path ("News › Daily"). A persistent "Go up one level" control (custom action + visible button) is present on every non-root folder.
- **Drill-down leans on iOS's automatic focus:** `Navigator.push` fires a screen-change notification, so VoiceOver auto-focuses the new screen's first element. No manual focus code needed for the common navigate-into-folder path. Depth becomes the navigation stack, and back-swipe is the natural "collapse".
- **Folder row label:** "{name}, {n} subfolders, {m} podcasts, {k} episodes, folder, button". Counts are spoken, not implied by indentation. Keep parentage on the detail screen's breadcrumb header rather than repeating "level 3" on every row.
- **Inline expand/collapse tree mode (shipped, opt-in via the Library display setting):**
  - Set `expanded: folder.isExpanded` **only on rows with children**; leaf rows carry no `expanded` flag. The flag itself makes VoiceOver announce "expanded"/"collapsed" — do not use `toggled:`/`checked:` and do not add `enabled: true` for expansion.
  - **Primary tap toggles expand/collapse; "Open folder" is a custom action** on the actions rotor. Do not overload double-tap to mean both open and expand, and do not rely on a tiny separate disclosure triangle as the only affordance (extra focus stop, usually sub-44pt).
  - Give each row a stable `ValueKey(folder.id)` so focus stays on the row across the rebuild. The `expanded` flag re-announces state automatically, so no extra announcement is needed; if you want the count, a single concise `SemanticsService.sendAnnouncement('Expanded, 4 items')` is fine — never both flip the flag and speak the word "expanded" (it double-talks). Never move focus to the first revealed child.
- **Reduce Motion:** expand/collapse and drill-down transitions are instant when `MediaQuery.of(context).disableAnimations` is true.

### 9.2 Multi-select and batch move

- **Model:** iOS Mail edit mode. An explicit "Select" entry point, per-row `selected:` state, a persistent bottom toolbar whose button label carries the live count, and a fully tap-based move flow. Drag/long-press is optional sugar; the tap path is the contract.
- **Enter/exit:** entering announces "Selection mode on. Double-tap items to select." and moves focus to the list's first item via `FocusSemanticEvent` (GlobalKey + post-frame callback). Exit via "Done"/"Cancel" announces "Selection mode off." Do not use `Focus(autofocus: true)` on the toolbar container — it makes VoiceOver read a merged group summary.
- **Row state:** each selectable row uses the **`selected:` flag**, not `checked:`/`toggled:`. Because `selected: false` produces no spoken "not selected", pick one parity approach and stick to it — either let the flag carry the true case with a visible (excluded) checkmark, or append state to the label yourself (`isSelected ? '$title, selected' : $title`). Do not both set the flag and duplicate the word in the label.
- **Running count is the toolbar button label, not just a transient announcement:** the button reads "Move 3 podcasts to folder" and updates as selection changes, so the count is discoverable on swipe at any time. A light debounced `sendAnnouncement('3 selected')` per toggle is optional; the button label is the source of truth. Do not fire an interruptive announcement on every tap — it stutters over the row's own "Selected" feedback.
- **Result + focus:** after a batch move — (1) dismiss the sheet and auto-exit selection mode, (2) announce "Moved 3 podcasts to News › Daily", (3) move focus to a stable anchor that survives the mutation (the list header or the "Select" button) via `RenderObject.sendSemanticsEvent(const FocusSemanticEvent())`. Never leave focus on a now-removed row.
- **Single-item shortcut:** also expose "Move to folder…" as a `customSemanticsActions` entry on each row, so users don't have to enter selection mode to move one item.
- **No drag dependency:** every batch action is available without long-press or drag; the folder-picker sheet uses `barrierLabel: 'Dismiss folder picker'`.

### 9.3 Long-press context menu

- Convenience only. Every action is also a VoiceOver custom action on the row.
- The menu sheet follows the established sheet rules: `barrierLabel`, `Semantics(header:)` title, each action a labeled `ListTile`, no `Focus(autofocus:true)` on the container.
- Under VoiceOver, double-tap-and-hold opens the same sheet.

### 9.4 Cross-cutting

- All new text uses `Theme.of(context).textTheme.*`; all colors from `colorScheme`. Verify at the largest Dynamic Type size — folder rows with long names and multi-part counts must not clip.
- Color is never the only signal for selected/expanded/played state; pair with icon + spoken label.
- Touch targets ≥ 44pt (iOS HIG) for every new control, including reorder and disclosure buttons.
- Focus order matches visual order on every new screen and sheet.
- Every new screen ships a widget test asserting semantic labels, plus a manual VoiceOver test note in the PR.

### 9.5 Mandatory agent review

Per CLAUDE.md, run the `mobile-accessibility` agent on every PR that touches Flutter UI in this effort before merge. No exceptions, including "small" changes. For a full-scope pass use `accessibility-lead`.

Relevant WCAG success criteria for these patterns: **2.4.3 Focus Order** (post-mutation focus anchoring), **4.1.2 Name, Role, Value** (`expanded`/`selected` states, folder role), and **1.3.1 Info and Relationships** (hierarchy conveyed non-visually). For a criteria-level mapping, hand off to `wcag-guide`; for folder-picker contrast/token checks, `design-system-auditor`.

---

## 10. UX flows (representative)

**Move several inbox episodes into a folder (VoiceOver):**
1. On the Inbox, invoke "Select" (custom action or button). Hear "Selection mode on."
2. Swipe through episodes; double-tap to select each. Hear "Selected, 1 of 12", "Selected, 2 of 12"…
3. Focus the action bar, activate "Move to folder…".
4. In the nested folder picker, drill to "News › Daily" (or "New folder…"), activate it.
5. Hear "Moved 3 episodes to News › Daily." Focus returns to the Inbox heading, selection mode off.

**Assign a podcast to a subfolder from its settings:**
1. Open the podcast → Settings → Folders section.
2. Activate "Add to folder…", drill to the target subfolder, toggle it on, Done.
3. Hear "Added to News › Daily."

**Long-press an episode (sighted) / actions rotor (VoiceOver):**
1. Long-press the episode row → action sheet with Play now, Add to queue, Move to folder…, etc.
2. VoiceOver user instead opens the actions rotor on the row and picks the same "Move to folder…".

**Nest and navigate:**
1. In a folder, "New subfolder here" → name it.
2. Move existing podcasts/subfolders in.
3. Drill down; heading reads the breadcrumb; "Go up one level" returns.

---

## 11. Edge cases

- Moving a folder into its own descendant is rejected (repo guard + hidden in picker). Announce nothing changed if attempted.
- Deleting a folder with children: explicit choice between promote-children and delete-subtree; podcasts/episodes never deleted.
- An episode whose podcast is unsubscribed: **decided (F3) — cascade.** Unsubscribing removes that show's episodes from any folders they were hand-added to (episode memberships cascade-delete with the episodes). No orphaned memberships left behind.
- A podcast in multiple folders shown in "Play all": de-duplicate episodes across folders in a subtree play-all.
- Very deep nesting: no hard depth cap, but breadcrumbs truncate visually while keeping the full path in the semantic label.
- Empty folder / empty section states have clear, spoken empty messages.
- Selection mode interrupted by navigation or backgrounding: exit cleanly and announce, don't strand the user in a hidden mode.

---

## 12. Phased rollout

**Phase order approved (Michael, 2026-07-30).** iCloud sync is a **committed part of this effort**, not a separate PRD. Each phase is independently shippable and independently testable on device.

**One migration epoch for all schema work (decided).** The folder schema changes (`parentId`, episode membership) and the sync-ready columns (`syncId` + backfill, `updatedAt`, tombstones, change cursor — §16.4) land in a **single coordinated migration epoch** in Phase 1/2, so TestFlight testers run **one** combined migration against their real data, not several. No sync *behavior* ships in that epoch; the columns just bake first (this is Sync Phase A, §16.10). See the interleave note after Phase 4.

**Phase 1 — Foundations, sync-ready schema & per-podcast association.**
- `parentId` schema + repo nesting methods (cycle guard, path, move).
- **Sync-ready columns in the same migration** (§16.4): `syncId` + UUID backfill, `updatedAt`, tombstone columns, change cursor. No sync code yet — schema only (= Sync Phase A).
- Folder detail becomes a drill-down of immediate children; breadcrumbs; "Go up one level".
- Folders section added to `PodcastSettingsScreen`.
- Reorder folders and items via non-drag "Move up/down".

**Phase 2 — Shared plumbing + multi-select & batch move.**
- **Do the shared-plumbing changes first (§7.9):** add `moveToFolder`/`addToFolder` to `EpisodeAction` + `buildEpisodeActions`, and one reusable nested folder picker. This instantly lights up "Move/Add to folder" in Inbox, Queue, Downloads, and Podcast detail — sheet and rotor — before any per-screen work.
- Selection mode + batch action bar in All Podcasts and folder podcast lists.
- Episode membership schema + repo (in the Phase 1 migration epoch); episode selection in Inbox and episode lists; batch "Move/Add to folder".
- Folder detail gains podcasts + episodes sections.

**Phase 3 — Context menu, listening lens, and queue/inbox embedding.**
- Long-press context menu for episodes and podcasts, wired to Quick Action config, with actions-rotor parity.
- **"Group by folder" in the Queue**, reusing the existing `QueueGroup` / collapse / group-rotor machinery (§7.8, §7.9) — Play/Shuffle/Move at folder granularity fall out for free.
- **Folder filter on the Inbox** (`inboxEpisodesByFolderProvider`), plus folder-scoped new-episodes in folder detail; "Add all to queue"; folder queue expiration honored.
- Recursive OPML export for a subtree; subscribe-to-folder on the Search/Add flow.

**Phase 4 — Broader embedding & polish.**
- Downloads "by folder" grouping/filter; player "Playing from {folder path}" + add-to-folder; podcast-detail folder chips.
- Inline expand/collapse tree mode on Library root **+ the drill-down/inline display toggle** (decision F4); folder filter on Downloads.
- Folder-level inbox include/exclude batch; OPML import maps groups → nested folders; stats-by-folder; consider inherited playback speed / auto-queue.

### How the folder phases and sync phases interleave

Two tracks, one schema epoch. Recommended sequencing:

1. **Folder Phase 1 = Sync Phase A.** The combined migration (folder + sync-ready columns) ships and bakes on TestFlight. Users get nesting and per-podcast folders; the sync columns sit dormant.
2. **Folder Phases 2–4** deliver the full folder/smart-folder experience locally while the sync schema proves out against real data.
3. **Sync Phases B–D** (engine, CloudKit bridge, opt-in UX, hardening — §16.10) run after the schema epoch is proven, and can overlap Folder Phases 3–4 since they touch mostly the data/native layer, not the folder UI.
4. **Smart folders (§17.8)** slot in after episode membership exists (Folder Phase 2), independent of the sync engine — smart-folder *definitions* ride the sync-ready schema for free.

Net: one migration for testers, folders usable early, sync switched on once its schema has baked.

---

## 13. Testing and definition of done

For every phase:

- `flutter test` and `flutter analyze` clean; `dart format` clean.
- Widget tests assert semantic labels for every new screen/sheet, and cover selection-count announcements and expand/collapse focus behavior.
- Drift migration tests under `test/data/db/` run `onUpgrade` from the prior version against realistic aged fixtures and assert no throw.
- `mobile-accessibility` agent run on every UI PR; findings resolved before merge.
- Manual VoiceOver pass on device: create/nest/move/delete folders, per-podcast assignment, multi-select move of podcasts and episodes, long-press menu, folder play-all — all reachable and announced. Note the iOS version tested in the PR.
- Manual upgrade test: install previous TestFlight build, create real data (feeds, folders, memberships, queue), install the new build over it, confirm everything loads.
- No color-only state. Nothing clips at largest Dynamic Type.

A phase is done when a blind tester can complete that phase's flows end-to-end with VoiceOver and no sighted help.

---

## 14. Decisions (resolved 2026-07-30)

All folder open questions are resolved. Kept here as the decision record.

1. **Model — unified.** A folder holds subfolders, podcasts, and episodes. No separate Collections concept. See §6.
2. **Multi-select default — Add.** "Add to folder" (non-destructive) is the prominent primary action; "Move" (relocate) is secondary. See §7.3.
3. **Unsubscribe — cascade.** Unsubscribing a podcast removes its episodes from any folders they were hand-added to. See §11.
4. **Library tree — both, user-configurable.** Ship **both** a drill-down and an inline expand/collapse tree, with a Library display setting to choose. Drill-down is the default (most reliable for VoiceOver); the user can switch to the inline tree. See §7.1 / §9.1.
5. **Depth — no cap.** Unlimited nesting; breadcrumbs truncate visually while the full path stays in the semantic label.
6. **Context menu — mirror Quick Actions.** The long-press menu follows the user's configured Quick Actions order, matching the VoiceOver rotor. See §7.4.
7. **List embedding — filter + Queue grouping.** Single-folder filter on Inbox & Downloads; inline group-by-folder in the Queue (reuses the existing collapse machinery). Smart folders are selectable as the filter too (§17). See §7.8.
8. **Auto-file on subscribe — when folders exist.** After subscribing from Search, offer "Add to folder…" only if the user already has at least one folder. See §7.8.

---

## 15. Success metrics

- A blind tester organizes a 40-show library into a two-level folder structure in one sitting with VoiceOver and no sighted help.
- Batch-moving 5 episodes into a folder takes noticeably fewer gestures than moving them one at a time, and the count and result are always spoken.
- No accessibility regression on any existing screen (verified by `mobile-accessibility` and on-device VoiceOver).
- Zero migration-related "Something went wrong" reports after the schema bumps (per the migration rules in `.claude/rules/database-migrations.md`).

---

## 16. iCloud sync (folders, subscriptions, and listening state)

Earshot should keep a user's world in step across their Apple devices: the same folders and nesting, the same subscriptions, the same queue, bookmarks, played state, and playback positions on iPhone and iPad. This section specifies how, and — just as important — how to do it without Earshot ever running a server that sees user data.

### 16.1 Goal and principles

- **One library, many devices.** Folders (with nesting and memberships), subscriptions, queue, bookmarks, inbox state, per-podcast settings, and playback progress converge across the user's Apple devices.
- **Zero-knowledge to Payown.** Sync uses the user's own **iCloud private database (CloudKit)**. Payown runs no server, sees no data, and stores nothing. This is the strongest possible fit for the CLAUDE.md privacy rules ("minimum data collection", "no third-party trackers"): sync *reduces* Earshot's data footprint compared with any hosted backend.
- **Opt-in and reversible.** Sync is off until the user turns it on. Turning it off leaves local data intact. There is always a clear picture of what is synced and when.
- **Accessibility is not an afterthought.** Every sync surface — onboarding prompt, status, "Sync now", errors — is fully VoiceOver-operable and announces meaningful change (§16.8).
- **Correctness over speed.** A late but correct merge beats a fast one that loses a folder or resurrects a deleted show.

### 16.2 What syncs vs. what stays local

| Syncs (user state) | Stays device-local |
|---|---|
| Subscriptions (the feed list, by `rssUrl`) | Downloaded audio files (bytes) |
| Folders: names, nesting (`parentId`), sort order, folder settings | Cached feed XML / artwork images |
| Folder memberships (podcast **and** episode) | Transient UI state, scroll positions |
| Queue contents and order | Logs, crash breadcrumbs |
| Bookmarks | The raw `earshot.db` file itself (never synced) |
| Played / unplayed status, playback position | Transient UI state, scroll positions |
| Inbox dismissed flags, per-podcast inbox/limit settings | Logs, crash breadcrumbs |
| **Listening history / stats** (decision SY2) | |
| **Download preferences** — Wi-Fi-only, auto-download (decision SY2) | |
| App settings that are genuinely user-global (launch screen, etc.) | |
| Smart folder definitions (§17) | Smart folder *results* (recomputed per device) |

> **Decision SY2 — sync everything.** Per Michael, sync is maximal: listening history/stats and download preferences sync too (not just the core folders/subscriptions/queue/progress). Only genuinely device-bound things stay local: the downloaded audio bytes, caches, transient UI, logs, and the raw DB file. Note the one behavioral wrinkle to handle: a synced "Wi-Fi-only downloads" preference now applies on every device; surface it clearly in settings so a change on one device isn't a surprise on another.

**Downloaded audio is deliberately not synced.** Each device downloads what it wants; syncing multi-gigabyte audio through iCloud would be slow, storage-hostile, and pointless. What *can* sync is the intent (an episode is queued/played), so a device can offer to download it locally.

### 16.3 Sync model: state, not content

The load-bearing design decision: **Earshot syncs the user's *state about* episodes, not episode rows or audio.**

- Episodes are derived from feeds. Every device already fetches feeds and holds the full episode rows (title, description, artwork, audio URL). Re-syncing those is wasteful and can conflict with each device's own refresh.
- So an episode's synced identity is **(podcast `rssUrl`, episode `guid`)**, not the local autoincrement `id`. The synced payload for an episode is just: played status, position, folder memberships, queue membership, bookmark offsets, inbox-dismissed. Tiny.
- A device applies incoming state by matching on `(rssUrl, guid)` against episodes it already has; if it hasn't fetched that episode yet, it stores the pending state and applies it on the next feed refresh.
- This keeps sync payloads small, avoids syncing large text/artwork blobs, and sidesteps "two devices disagree about an episode's description" entirely.

> **Decision SY1 — minimal stub.** Sync a lightweight episode stub (title + audio URL) for *referenced* episodes only (queued or bookmarked), so a device that hasn't refreshed that feed yet can still act on them. Full episode content is never synced.

### 16.4 Sync-ready schema (a real migration, do it before any sync code)

The current schema is sync-hostile and must be prepared first. This is a significant, data-touching migration — follow `.claude/rules/database-migrations.md` to the letter (test `onUpgrade` against realistic aged fixtures; verify on-device by installing over the prior TestFlight build; never let a migration dead-end the app).

Every syncable table needs:

1. **A stable global id (UUID/`syncId`).** Autoincrement `int` PKs collide across devices (both make "folder 7"). Add a `syncId TEXT` (UUID v4) to `Podcasts`, `PodcastFolders`, `PodcastFolderMemberships`, `PodcastEpisodeFolderMemberships`, `QueueItems`, `Bookmarks`, and the relevant `Episodes`/settings rows. **Backfill a UUID for every existing row** in the migration. Local int PKs stay for in-app joins; `syncId` is the cross-device identity. Foreign references in synced payloads use `syncId`, never the int.
2. **`updatedAt` (unix seconds).** Set on every local write. Drives last-writer-wins and the change cursor.
3. **Soft deletes / tombstones.** Replace hard `delete()` + cascade for synced entities with a `deletedAt` tombstone so deletes propagate instead of silently reappearing from another device. A local compaction job purges old tombstones after they have certainly synced. (Cascade stays for genuinely local-only cleanup.)
4. **A change cursor.** A per-device `lastSyncedAt` / CloudKit change token so each sync pulls only what changed.

**Decided (2026-07-30): one migration epoch.** Because §6 already adds `parentId` and episode membership, the sync-ready columns land in the **same coordinated migration** in Folder Phase 1/2 (= Sync Phase A). Testers run one combined migration against their real data, not several. See §12.

### 16.5 Transport: CloudKit via a Swift platform channel

- **Use CloudKit's private database**, not iCloud Drive file sync. Syncing the SQLite file is unsafe: the app runs WAL mode with a separate background-task Dart engine (`app_database.dart`), and file-level sync across devices corrupts live SQLite. CloudKit gives record-level sync, per-record conflict metadata, push change notifications, and the user's-own-account storage model we want.
- **There is no first-class Flutter plugin for CloudKit record sync**, so this needs a **Swift platform-channel bridge** in `ios/Runner/`. That means new `.swift` files, which per CLAUDE.md's "iOS platform channel development" section must be **manually registered in `project.pbxproj`** (four edits, two new UUIDs) or they silently fail to compile. Unwrap `registrar(forPlugin:)` with `guard let`.
- **Call CloudKit directly — no `SyncBackend` abstraction (decision SY3).** Since sync is iOS-only (§16.7) with exactly one backend, the Dart sync engine talks to the CloudKit platform channel directly rather than through an interface. Keep it testable by faking the platform channel at the method-channel boundary in tests. If an Android backend is ever revived, extract the interface then.
- **Sync engine (Dart):** a change-log driven loop — collect local rows with `updatedAt > lastSyncedAt` (and tombstones), push to CloudKit, pull remote changes, merge (§16.6), advance the cursor. Triggered on app foreground, after significant local mutations (debounced), and on CloudKit push notification. All DB work off the UI isolate.

### 16.6 Conflict resolution (per entity, not one-size-fits-all)

Default is **last-writer-wins per field** using `updatedAt`, with these entity-specific rules:

- **Folder tree (`parentId`):** LWW on the parent pointer, but after merge run the **cycle guard** (§7.1) — if two devices' edits would form a cycle, the later edit wins and the losing branch reattaches to root, announced on the device that loses.
- **Memberships (podcast/episode ↔ folder):** merge as **sets**, not scalars. Adds and removes are independent tombstoned records, so "added on iPad, unchanged on iPhone" simply unions; an explicit remove (tombstone) beats a stale add.
- **Queue order:** order is fragile under naive LWW. Use per-item `sortOrder` with LWW per item, then a deterministic re-normalization pass so both devices land on the same sequence. Document that simultaneous reordering on two devices resolves to the later device's order for the contested items.
- **Playback position:** **furthest-progress-wins by default** (max position), *except* an explicit "mark unplayed" (a newer `updatedAt` resetting status) wins over a stale higher position. This avoids the classic "my other device rewound me."
- **Played status:** newest `updatedAt` wins; pairs with the position rule above.
- **Deletes:** tombstones always win over a concurrent edit of the same record (no resurrection). Deleting a folder syncs the delete + the membership tombstones; podcasts/episodes are never deleted by a folder delete (unchanged from §7.1).

### 16.7 Scope: Apple platforms only

Sync is **iOS/iPadOS only** (decided 2026-07-30). There is no Android sync and no cross-platform backend in this effort. CloudKit is the one and only backend, called directly with no abstraction layer (decision SY3). If Android sync is ever revived, a backend interface gets extracted then.

### 16.8 UX and accessibility

- **Onboarding / opt-in:** a clear, accessible prompt ("Turn on iCloud sync? Your folders and progress stay in step across your Apple devices. Everything stays in your private iCloud — Payown never sees it."). Off by default. Reachable later from Settings.
- **Status surface in Settings:** "iCloud sync: On", "Last synced 2 minutes ago", a **"Sync now"** button, and a plain-language state when unavailable (see edge cases). Status is text + icon, never color alone.
- **Announcements:** sync completion and failures use `SemanticsService.sendAnnouncement` sparingly and meaningfully ("Synced", "Sync failed, will retry", "iCloud is not signed in"). No chatter on every routine sync.
- **Conflict transparency:** the rare user-visible resolution (e.g. a folder reattached to root after a cycle) is announced and shown, never silent.
- **No blocking:** sync never blocks the UI or playback. The app is fully usable offline; changes queue and flush later.
- Follows every existing rule: `barrierLabel` on any sync sheet/dialog, `Theme.of(context).textTheme`, ≥44pt targets, works at largest Dynamic Type.

### 16.9 Edge cases

- **iCloud signed out / unavailable:** detect and show "Sign in to iCloud in Settings to sync." Keep working locally; resume when available.
- **iCloud storage full / quota:** surface a clear, accessible message; keep the local app fully functional.
- **Account switch on a device:** namespace local sync state by iCloud account; on switch, do **not** merge one person's library into another's — offer a clean choice.
- **First sync on a large library:** batch and background it; show progress accessibly; never freeze the app.
- **Offline edits on two devices:** both queue; on reconnect the merge rules (§16.6) apply deterministically.
- **Migration + sync interaction:** a device mid-migration must finish its local upgrade before it syncs, so it never pushes half-migrated state.
- **Tombstone GC:** never purge a tombstone that some device may not have seen yet; gate purge on a conservative age + confirmed cursor advance.

### 16.10 Phasing (a track that gates on sync-ready schema)

- **Sync Phase A — Sync-ready schema.** UUID `syncId` + backfill, `updatedAt`, tombstones, change cursor. No sync behavior yet. Ships and bakes on TestFlight so the schema is proven against real data before any network code.
- **Sync Phase B — Engine + CloudKit backend.** CloudKit Swift platform-channel bridge (with pbxproj registration), the Dart change-log push/pull engine calling it directly (no abstraction, per SY3), merge rules, all off-isolate. Behind a hidden flag; dogfood on two devices.
- **Sync Phase C — Enable + UX.** Opt-in onboarding, Settings status, "Sync now", announcements, edge-case handling. Public.
- **Sync Phase D — Hardening.** Conflict stress tests, large-library performance, tombstone GC, account-switch flows.

This track is a **committed part of this effort** (approved 2026-07-30), sequenced against the folder phases in §12: **Sync Phase A is the same migration as Folder Phase 1/2**, and Sync Phases B–D follow once that schema has baked. See the interleave note in §12.

### 16.11 Testing and definition of done

- **Two-device manual matrix:** create/move/delete folders, reorder queue, mark played, change position on device A → verify convergence on device B, and vice versa.
- **Conflict simulations (automated where possible):** concurrent parent moves (cycle), add-vs-remove membership, rewind-vs-advance position, delete-vs-edit. Assert the documented rule wins.
- **Migration tests:** `onUpgrade` from the pre-sync schema against realistic aged fixtures; assert UUID backfill covers every row and nothing throws.
- **Offline/online:** queue edits offline, flush on reconnect, no loss.
- **Account states:** signed out, quota full, account switch — all reach a usable, accessible state.
- **Accessibility:** `mobile-accessibility` on every sync UI PR; VoiceOver pass on onboarding, status, errors.
- **Privacy check:** confirm no user data leaves the user's private iCloud; nothing is sent to any Payown or third-party endpoint.

Done when a blind user can turn on iCloud sync, and folders + progress converge across two Apple devices, with every step operable and announced under VoiceOver, and no data ever reaching Payown.

### 16.12 Decisions (resolved 2026-07-30)

1. **Episode stubs — yes (SY1).** Sync a minimal title + audio-URL stub for referenced (queued/bookmarked) episodes. See §16.3.
2. **Scope — sync everything (SY2).** Listening history/stats and download preferences sync too; only audio bytes, caches, transient UI, logs, and the raw DB stay local. See §16.2.
3. **Transport — hard-wire CloudKit (SY3).** No `SyncBackend` abstraction; the engine calls CloudKit directly, faking the method channel in tests. See §16.5 / §16.7.
4. **Conflict visibility — silent, notify on visible change (SY4).** Resolve silently; surface a note only when a merge visibly changed the user's structure (e.g. a folder reattached to root after a cycle). See §16.8.
5. **Platform — iOS/iPadOS only.** No Android sync. See §16.7.

---

## 17. Smart (dynamic) folders

A **smart folder** has no hand-filed contents. You define a rule, and the folder shows whatever matches, live, updating itself as episodes arrive, get played, or age out. Manual folders (everything in §1–§9) are where you *put* things; smart folders are where things *land on their own*. Both live in the same tree, and — this is where it gets rich — they compose: a smart folder rule can reference a manual folder, and a smart folder can be placed inside a manual folder.

### 17.1 What a smart folder is

- A **named, rule-defined lens** over your episodes (or, secondarily, your podcasts).
- Its contents are **computed, not stored** — there are no membership rows. It is a saved query.
- It behaves like any other folder where it counts: it appears in the tree, has a detail screen, supports "Play all" / "Add all to queue", and its episodes expose the same actions (including "Add to a *manual* folder…"). You just can't manually add or remove items — the rule decides.
- It is clearly marked as smart, in visuals **and** semantics ("smart folder, updates automatically"), so a screen reader user always knows the difference (§17.6).

### 17.2 Starter smart folders (ship these)

Predefined, editable examples that teach the feature and are useful on day one:

- **Continue Listening** — started but not finished (position > 0 and < ~95%), newest activity first.
- **New This Week** — `newEpisode` status, published in the last 7 days.
- **Quick Listens** — unplayed, duration under 20 minutes.
- **Downloaded & Unplayed** — downloaded, not played.
- **Long Reads** — unplayed, duration over 1 hour.

Users can edit, duplicate, delete, or build their own.

### 17.3 The rule model

A smart folder is a small rule document: a **match mode** (`all` = AND / `any` = OR) plus a list of **conditions**, each a `field` + `operator` + `value`, then a **sort** and an optional **limit**.

Available condition fields (grounded in the current schema):

- **Play state:** status (new / unplayed / played / in queue), position (unstarted / started / finished).
- **Download:** download status (downloaded / not downloaded / downloading / failed).
- **Time:** age / published-within (last N days), duration (< / > N minutes), season/episode number.
- **Source:** podcast is (one of…), podcast is in **manual folder** (…) ← composition hook.
- **Organization:** is in manual folder (…), has a bookmark, inbox-dismissed or not.
- **Text:** title / show-notes contains (…).

Sort options: newest, oldest, shortest, longest, recently active. Optional cap (e.g. top 50) to keep broad rules cheap and useful.

**Target type:** episodes by default. A smart folder may instead target **podcasts** (e.g. "shows I haven't played in 30 days") — same rule engine, podcast-level fields. Episode-target is primary; podcast-target is a secondary mode.

### 17.4 Composition with the unified model (the rich part)

Because manual folders and smart folders share one tree (§6 unified model):

- **Smart references manual:** a rule can say "podcast is in **News**" or "is in **News › Daily**". So "Unplayed, under 20 min, from my News folder" is one smart folder built on top of a manual one. Subtree-aware (matches the folder and its descendants).
- **Manual contains smart:** a smart folder can be **placed** under a manual parent for organization (it is a leaf — it never holds manual children). So a manual "Commute" folder can contain the "Quick Listens" smart folder next to a couple of hand-filed shows.
- This composition is what makes deeply-nested manual folders and dynamic rules reinforce each other instead of being two separate features.

### 17.5 Data model and query engine

New tables (sync-ready per §16.4: include `syncId`, `updatedAt`; definitions sync, results do not):

```dart
@DataClassName('SmartFolderRow')
class SmartFolders extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text()();                 // UUID, for iCloud sync
  TextColumn get name => text()();
  TextColumn get targetType => text()();             // 'episode' | 'podcast'
  TextColumn get matchMode => text()();              // 'all' | 'any'
  TextColumn get rules => text()();                  // JSON rule document
  TextColumn get sortBy => text().nullable()();
  IntColumn  get itemLimit => integer().nullable()();
  IntColumn  get parentId => integer().nullable()    // placement in the tree
      .references(PodcastFolders, #id, onDelete: KeyAction.setNull)();
  IntColumn  get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}
```

- **Rules as a JSON document** in one column (rather than a child-rows table): simpler, and syncs as a single last-writer-wins field (§16.6). Trade-off vs. queryable child rows is noted; JSON + a runtime translator is the recommendation.
- **Engine:** translate the rule document into a drift `SELECT … WHERE … ORDER BY … LIMIT …`, exposed as a `StreamProvider.family<List<Episode>, int>(smartFolderId)` so the detail screen updates live as the underlying episodes change. Must be index-backed (the existing `idx_episodes_inbox` helps; add indexes for duration/pubDate/downloadStatus as needed). Never scan-and-filter in Dart for large libraries.
- **Composition** ("in manual folder X") compiles to a subquery over `PodcastFolderMemberships` / the subtree — reusing the same subtree walk as OPML export (§8.3).

### 17.6 UX and accessibility

- **Builder screen** — an accessible form: a "Match all / Match any" control, a list of conditions (each: field picker, operator picker, value input), add/remove condition buttons, sort picker, optional limit, and a **live preview count** ("Matches 23 episodes right now"). Pickers and steppers, never drag; every control labeled; errors surfaced in text (per `.claude/rules/accessibility.md` and the forms patterns).
- **Distinct identity:** smart folders use a distinct icon **and** carry it in the semantic label — "Quick Listens, smart folder, 12 episodes, updates automatically" — so color/icon is never the only signal.
- **Read-only membership, actionable contents:** the detail screen states it's rule-driven; you can't add/remove items, but each episode still exposes Play / Queue / "Add to a manual folder…" via the shared plumbing (§7.9).
- **Announce sparingly:** the folder detail is a normal live list; do not announce every automatic change. Announce only deliberate user actions (saved rule, "Added all to queue"). Preview count updates are on-demand, not chattered.
- **Reduce Motion / Dynamic Type / 44pt** all respected. `mobile-accessibility` review on every builder PR.

### 17.7 Edge cases

- **Rule references a deleted manual folder:** the condition goes inert and is flagged in the builder ("This folder no longer exists"); the smart folder still runs its other conditions.
- **Empty result:** clear spoken empty state ("No episodes match right now").
- **Over-broad rule:** the preview count and the optional cap warn before a rule matches the entire library.
- **Cycle-free by construction:** smart folders are leaves and cannot contain other folders, so they add no new nesting-cycle risk; the manual-tree cycle guard (§7.1) is unaffected.
- **Performance:** cap + indexes; the live query is the same cost model as the inbox query.
- **Sync:** only the definition syncs; each device recomputes results against its own episode rows (§16.2), so two devices always agree on the *rule* and may momentarily differ on results until both have refreshed feeds.

### 17.8 Phasing

- **Smart Phase 1 — Engine + starter set.** `SmartFolders` schema, JSON rule → drift query translator, live providers, and the five starter smart folders (§17.2) shown in the tree with detail + play-all. No custom builder yet.
- **Smart Phase 2 — Builder UI.** The accessible rule builder (§17.6): create/edit/duplicate/delete, preview count.
- **Smart Phase 3 — Composition + podcast targets.** "in manual folder X" conditions (subtree-aware) and podcast-target smart folders; placement under manual parents.

Depends on manual folders + episode membership (§6–§9) existing first, and on the sync-ready schema (§16.4) so definitions sync cleanly.

### 17.9 Decisions (resolved 2026-07-30)

1. **Rule storage — JSON document (SM1).** Rules stored as JSON in one column; syncs as a single last-writer-wins field. See §17.5.
2. **Smart folder as filter — yes (SM2).** A smart folder is selectable as the Inbox/Queue folder filter, its live rule scoping those lists. See §7.8 / §17.6.
3. **Podcast-target smart folders — ship in Smart Phase 3 (SM3).** Included alongside composition. See §17.8.
4. **Starters — fully editable (SM4).** The five starter smart folders behave like user folders: edit, duplicate, delete freely.

---

## Appendix A — Concrete plumbing sketch (illustrative, not final code)

This appendix shows the shape of the shared-plumbing changes from §7.9 against the app's actual signatures, so the requirements are unambiguous. It is a design sketch for review, not code to paste. Nothing here is built yet.

### A.1 New episode actions in the enum

`lib/features/settings/domain/quick_action_definition.dart` — add two values so folder moves are user-orderable Quick Actions and flow to the rotor everywhere:

```dart
enum EpisodeAction {
  playNow,
  playNext,
  addToEndOfQueue,
  markPlayed,
  openShowNotes,
  bookmark,
  download,
  addToFolder,     // NEW — non-destructive: add membership, keep existing
  moveToFolder,    // NEW — relocate: remove from current folder context
  share;

  String get label => switch (this) {
    // …existing…
    EpisodeAction.addToFolder => 'Add to folder',
    EpisodeAction.moveToFolder => 'Move to folder',
    // …
  };
}

// Append to defaultEpisodeActions so existing users get them without
// reconfiguring; they can reorder/hide in the Quick Actions configurator.
const defaultEpisodeActions = [
  /* …existing… */,
  EpisodeAction.addToFolder,
  EpisodeAction.moveToFolder,
];
```

### A.2 One case in `_buildItem`, then it appears everywhere

`lib/core/episode_action_builder.dart` — add cases to the existing `switch (action)` in `_buildItem`. Because Inbox, Queue, Downloads, and Podcast detail all render through `buildEpisodeActions`, this is the *only* place the behavior lives:

```dart
case EpisodeAction.addToFolder:
  return EpisodeQuickActionItem(
    label: action.label,
    onInvoke: () => showFolderPicker(
      context: context,
      ref: ref,
      // batch of one; multi-select passes many (A.4)
      episodeIds: [episode.id],
      mode: FolderPickMode.add,
    ),
  );

case EpisodeAction.moveToFolder:
  return EpisodeQuickActionItem(
    label: action.label,
    onInvoke: () => showFolderPicker(
      context: context,
      ref: ref,
      episodeIds: [episode.id],
      mode: FolderPickMode.move,
    ),
  );
```

Screens that gate actions via `allowedActions` (Inbox `_inboxAllowedActions`, Downloads `_downloadsAllowedActions`) add `EpisodeAction.addToFolder` / `moveToFolder` to their allow-sets to opt in. No other per-screen change is required — the sheet and the rotor pick them up automatically.

### A.3 One reusable folder picker (used by every entry point)

A single helper backs per-podcast assignment, per-episode move, multi-select batch move, subscribe-to-folder, and OPML import target. It shows the nested tree (§7.1) with "New folder…" inline, performs the repository call, announces the result, and anchors focus (§9.2):

```dart
enum FolderPickMode { add, move }

Future<void> showFolderPicker({
  required BuildContext context,
  required WidgetRef ref,
  List<int> episodeIds = const [],
  List<int> podcastIds = const [],
  required FolderPickMode mode,
}) async {
  // showModalBottomSheet(barrierLabel: 'Dismiss folder picker', …)
  // → nested tree + "New folder…"; returns the chosen folderId or null.
  // On pick: call the batch repo method (A.5), then
  //   SemanticsService.sendAnnouncement('Moved 3 episodes to News › Daily')
  //   and move VoiceOver focus to a stable anchor via FocusSemanticEvent.
}
```

### A.4 Podcast side reuses the existing enum

`PodcastAction.manageFolders` already exists and is wired in All Podcasts. The same action feeds the long-press context menu (§7.4) and the podcast-settings Folders section (§7.2). For batch, `showFolderPicker(podcastIds: [...])` is the podcast-list analogue.

### A.5 Repository batch methods (from §8.3)

`showFolderPicker` calls the batch/transaction methods added to `FolderRepository`:

```dart
Future<void> addEpisodesToFolder(int folderId, List<int> episodeIds);
Future<void> moveEpisodesToFolder(int folderId, List<int> episodeIds);
Future<void> addPodcastsToFolder(int folderId, List<int> podcastIds);
Future<void> movePodcastsToFolder(int folderId, List<int> podcastIds);
```

### A.6 Queue "group by folder" reuses existing grouping

`lib/features/player/presentation/screens/queue_screen.dart` already has group-by-podcast. Generalize the mode rather than add a parallel implementation:

- Replace the boolean `groupQueueEpisodesProvider` with a small enum notion `QueueGrouping { none, podcast, folder }` (keep a migration for the stored bool).
- Add a `groupedByFolderQueueProvider` sibling to `groupedQueueProvider` that buckets the same episodes by folder (subtree-aware), reusing `QueueGroup` with an optional `folderId` / `folderName`.
- The existing `_buildGroupHeader` rotor (Play / Shuffle / Sort / Move up/down/top/bottom) and `collapsedQueueGroupsProvider` work unchanged — "Play group" becomes "Play folder", etc. This is the largest single reuse in the effort and inherits the queue's already-audited VoiceOver behavior.

*End of Appendix A. Signatures shown match the current codebase as of this draft; confirm against `HEAD` before implementing.*

---

*For Michael. Nothing here is built yet. **All decisions are confirmed (2026-07-30):** the §14, §16.12, and §17.9 records, the §12 phase order (folder Phases 1–4 with Sync Phases A–D interleaved), and the single combined folder+sync migration epoch (§16.4). **Next step:** keep this as the reference PRD; per-phase docs and GitHub issues are written just-in-time when each phase begins (per `.claude/rules/phase-progression.md`). Per project rules, no work starts on `main`, and every UI PR gets a `mobile-accessibility` review first. Scope is iOS/iPadOS only.*
