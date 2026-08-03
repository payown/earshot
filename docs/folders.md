# PRD: Folders as a First-Class Citizen in Earshot (SwiftUI)

**Status:** Approved. Manual-folder Phases 1–4 shipped; Sync and Smart Folders pending.
**Owner:** Michael Babcock, Payown Media LLC
**Author:** Product / Engineering
**Last updated:** 2026-08-03
**Platform:** iOS/iPadOS only (SwiftUI + SwiftData)
**Related docs:** `SWIFTUI_PLAN.md`, `.claude/rules/accessibility.md`, `.claude/rules/database-migrations.md`, `.claude/rules/git-workflow.md`

> **This PRD is grounded in the SwiftUI + SwiftData app at the repo root.** It supersedes the earlier Flutter-based `folders.md` (PR #748), which was written against the retired Flutter/drift codebase now in `archive/flutter/`. Manual-folder Phases 1–4 shipped through PRs #760, #765, and #766; their approved per-phase documents record the exact delivered scope. Confirm remaining technical references against `HEAD` before implementing Sync or Smart Folders.

---

## 1. Summary

Folders in Earshot today are a thin, flat feature: a podcast belongs to zero or more named folders, and a folder holds a list of podcasts. They live in one section of the Library and expose a couple of VoiceOver rotor actions. Useful, but shallow.

This PRD turns folders into a core organizing concept that runs through the whole app. It adds:

- **Deeply nested folders** (subfolders, arbitrary depth) with a fully accessible tree.
- **Per-podcast folder association** surfaced directly in a podcast's own settings.
- **Multi-select** for podcasts and for episodes, with a batch "Add/Move to folder" that acts on the whole selection at once.
- **Episode-level folder membership** so a folder can also hold a hand-picked set of episodes, not just whole shows.
- **A long-press context menu** on any episode or podcast that surfaces the most common actions in one place, with a VoiceOver-equivalent path via the actions rotor.
- **Folder-scoped inbox, queue, and playback** so a folder is a lens you can listen through, not just a bin.
- **iCloud sync** (§16) via SwiftData's built-in CloudKit mirror, so folders and listening state converge across a user's Apple devices.
- **Smart/dynamic folders** (§17): rule-defined live folders that compose with the manual tree.

The whole feature is designed screen-reader-first. Every interaction has a VoiceOver path that does not depend on sight, drag, or precise gestures. Accessibility is the acceptance bar, not a review step.

---

## 2. Why now

Michael is blind, and Earshot's core users are blind and low-vision listeners in the BITS and ACB communities who often subscribe to many shows. Flat, alphabetical lists do not scale for them. Sighted apps lean on drag-and-drop and dense grids that are hostile to VoiceOver. Earshot can win by making organization genuinely fast and pleasant with a screen reader: nested folders navigated by swipe and the actions rotor, batch moves that announce their result, and a context menu that puts the common actions one gesture away.

Folders are the highest-leverage place to make Earshot feel built *for* screen reader users rather than merely usable by them.

---

## 3. Current state (grounded in the codebase)

Read before proposing changes. All paths are repo-relative; the SwiftUI app is at the repo root under `Earshot/`.

### 3.1 Data model (SwiftData `@Model`)

- `Earshot/Data/Models/PodcastFolder.swift` — `@Model final class PodcastFolder`: `name`, `sortOrder`, `queueAgeLimitDays: Int?`, `createdAt`, and `@Relationship(deleteRule: .cascade, inverse: \FolderMembership.folder) var memberships: [FolderMembership]`. **Flat. No `parentId`.** `queueAgeLimitDays` is the only folder setting.
- `Earshot/Data/Models/FolderMembership.swift` — `@Model final class FolderMembership`: `folder: PodcastFolder?`, `podcast: Podcast?`, `sortOrder: Int`. A podcast can be in multiple folders. Uniqueness of `(folder, podcast)` is enforced **in code** (`FolderRepository.add`), not by a constraint. **No episode membership.**
- **Coupling to know:** `FolderMembership.podcast` has no cascade/nullify from the podcast side, so unsubscribing a podcast must call `FolderRepository.removeFromAllFolders` first (wired in `SubscriptionRepository.unsubscribe`). `SettingsReset` deletes `PodcastFolder` + `FolderMembership` explicitly.
- Schema is at **`EarshotSchemaV5`** (`Earshot/Data/Persistence/EarshotSchema.swift`). Any folder model change is a schema bump (§8).

### 3.2 Repository (`Earshot/Features/Folders/Data/FolderRepository.swift`)

`@MainActor final class FolderRepository`, `init(context: ModelContext)`. Exposes: `folders()`, `podcasts(in:)`, `unfiledPodcasts()`, `folders(containing:)`, `createFolder(name:)`, `rename(_:to:)`, `delete(_:)`, `setQueueAgeLimit(_:days:)`, `reorderFolders(_:)`, `add(_:to:)`, `remove(_:from:)`, `setMemberships(for:folders:)`, `reorderPodcasts(in:ordered:)`, `latestUnplayedToQueue(in:now:)`, `addFolderToQueue(_:now:)`, `removeFromAllFolders(_:)`.

`Earshot/Features/Folders/Domain/FolderLogic.swift` — pure, SwiftData-free helpers: `passesAgeLimit(pubDate:ageLimitDays:now:)`, `byPubDateDescending(_:_:)`.

**Missing for this PRD:** no batch (multi-podcast/multi-episode) ops, no nesting ops (move-into-folder, child enumeration, cycle guard), no episode-membership methods, no smart-folder evaluation, no folder-scoped inbox. `addFolderToQueue` pulls exactly one newest unplayed episode per podcast — not a configurable "queue all".

### 3.3 UI (`Earshot/Features/Folders/Presentation/`)

- **`FoldersScreen`** — lists folders via `@Query(sort:)`. Create (alert `TextField`), drag-reorder (`.onMove`), delete (confirmation dialog). `ContentUnavailableView` when empty. `NavigationLink(value: folder)` → detail. Uses `@AccessibilityFocusState private var focusedFolderID: PersistentIdentifier?`, gates sighted-only `.swipeActions` behind `@Environment(\.accessibilityVoiceOverEnabled)`, and builds move/delete via `.rotorActions([QuickActionItem])` + `Announcer.announce(...)`. Embedded from `SubscriptionsView` under a "Folders" toolbar item.
- **`FolderDetailScreen`** — `@Bindable var folder`. Lists the folder's podcasts. Options `Menu` ("Folder options"): rename, set queue age limit, add-folder-to-queue, delete. Add-podcasts sheet. Per-row "Remove from folder" rotor action + `Announcer`. No `@AccessibilityFocusState` yet.
- **`FolderPodcastPickerView`** — a live-toggle sheet over all podcasts (`@Query(sort: \Podcast.title)`); toggling calls `repo.add`/`repo.remove` immediately. `.accessibilityAddTraits(.isToggle / .isSelected)`. **Not** a batched multi-select-then-commit flow.

### 3.4 Accessibility infrastructure already established (reuse, don't reinvent)

- **`Earshot/Core/Accessibility/Announcer.swift`** — `Announcer.announce(_ message:assertive:)`. Polite by default (queued), assertive interrupts; no-ops when VoiceOver is off; pins the speech language to the user's BCP-47 locale (#688). This is THE announcement API.
- **`Earshot/Core/UI/QuickActionsRotor.swift`** — the one supported way to attach custom actions to the VoiceOver **actions rotor**: `.rotorActions([QuickActionItem])` / `.quickActionsRotor([QuickActionItem])`. It compensates iOS's reversed `.accessibilityActions` emission (#572/#577). Folder rows already use it.
- **Post-mutation focus** — `@AccessibilityFocusState` keyed on `PersistentIdentifier`, reassigned after a move/remove (see `FoldersScreen`, `QueueScreen`).
- **Sighted/VoiceOver split** — `@Environment(\.accessibilityVoiceOverEnabled)` gates sighted-only swipe/context affordances so they don't duplicate rotor actions.

---

## 4. Goals and non-goals

### 4.1 Goals

1. Folders can be nested to arbitrary depth, fully navigable with VoiceOver.
2. A podcast can be assigned to folders from its own settings screen, not only from the Library.
3. Users can select many podcasts, or many episodes, and add/move the whole group into a folder in one action.
4. Folders can hold hand-picked episodes (a curated collection), in addition to whole shows.
5. Every folder-related action has a VoiceOver path that needs no sight, no drag, and no timing-sensitive gesture.
6. A long-press context menu gives quick access to the most common actions on any episode or podcast.
7. Folders drive real listening: folder-scoped inbox, folder "play all"/"queue all", and folder-level rules.
8. Folders are reachable from **every surface** a podcast or episode appears — Library, Inbox, Queue, Downloads, player, search, settings — through the shared Quick Actions system and the reusable queue-grouping machinery, not one-off per-screen code (§7.8, §7.9).

### 4.2 Non-goals (for this effort)

- **Android / any non-Apple platform.** iOS/iPadOS only (decided 2026-07-30). VoiceOver is the single accessibility target.
- **A Payown-run backend / account system.** iCloud sync (Apple devices, via SwiftData + CloudKit) is in scope — see §16. Earshot never runs a server that sees user data.
- Sharing a folder structure socially or publicly.
- Reworking the tab bar. Folders live inside the Library.

---

## 5. Guiding principles

1. **Screen-reader-first.** If it only works by sight or drag, it is not done. Design the VoiceOver path first.
2. **Follow the system.** Respect Dynamic Type, Reduce Motion, contrast, and theme. Never override.
3. **No destructive surprises.** Deleting a folder never deletes podcasts or episodes. Moves are reversible or clearly confirmed.
4. **Announce meaningful change, stay quiet otherwise.** Use `Announcer.announce` for results ("Moved 4 podcasts to News"), not for noise.
5. **One concept, many entry points.** Adding to a folder should feel the same from Library, from a podcast, from an episode, and from multi-select — one picker, one repository call, one announcement.

---

## 6. Key model decision: what can a folder contain?

Today a folder contains **podcasts**. Michael has asked to group **episodes** too, and to nest folders. Two model changes:

**A. Nesting (subfolders).** Add an optional self-reference to `PodcastFolder`:

```swift
// Nullable parent. nil = top-level folder.
@Relationship(deleteRule: .nullify, inverse: \PodcastFolder.children)
var parent: PodcastFolder?
@Relationship(deleteRule: .nullify) var children: [PodcastFolder]
```

A folder's contents become: its child folders, plus its member podcasts, plus its member episodes.

**B. Episode membership.** Add a new join `@Model`:

```swift
@Model final class EpisodeFolderMembership {
    var folder: PodcastFolder?
    var episode: Episode?
    var sortOrder: Int
    init(folder: PodcastFolder? = nil, episode: Episode? = nil, sortOrder: Int = 0) { ... }
}
```

This lets a folder double as a curated collection / playlist of specific episodes.

A folder can therefore hold a mix of: subfolders, whole podcasts, and individual episodes. The folder detail screen renders these as three clearly-labeled sections.

> **Decided (Michael, 2026-07-30): unified model.** A folder holds a mix of subfolders, whole podcasts, and individual episodes. There is no separate "Collections" concept — "a folder holds things" is the simpler mental model for a screen reader user. Smart/dynamic folders (§17) layer on top of this same model.

**Delete-rule discipline (important):** SwiftData relationships from the podcast/episode side are not cascaded onto memberships automatically here (`FolderMembership.podcast` already relies on manual cleanup). The new `EpisodeFolderMembership` must either declare a proper delete rule so unsubscribing/deleting an episode removes its memberships, or follow the same `removeFromAllFolders`-style manual cleanup. Cascade from the **folder** side (folder → its memberships) stays, matching `PodcastFolder.memberships` today.

---

## 7. Feature requirements

### 7.1 Nested folders (subfolders)

**What:** Folders can contain other folders, to any depth.

- Create a subfolder from inside a folder ("New subfolder here"), or move an existing folder under another folder.
- A folder shows a combined count: e.g. "News, 3 subfolders, 12 podcasts, 5 episodes".
- Deleting a parent prompts clearly: delete the parent only (children reparent to the grandparent — the `.nullify`/reparent path) or delete the whole subtree. Podcasts and episodes are never deleted, only unfiled.
- Cycles are impossible: a folder cannot be moved into itself or a descendant. `FolderRepository` rejects it and the move UI hides invalid targets. (New `FolderLogic` helpers: `isDescendant(_:of:)`, `wouldCreateCycle(moving:under:)`.)

**Accessibility (the hard part):**

- **Two presentation modes, user-configurable (decided).** A Library display setting chooses:
  - **Drill-down (default):** tapping a folder pushes its detail screen (immediate children). Most reliable VoiceOver model — a `NavigationLink`/`NavigationStack` push fires a screen-change notification and iOS auto-focuses the new screen's first element. Fully sufficient on its own; ships first.
  - **Inline expand/collapse tree:** the Library root shows folders as an expandable tree (`DisclosureGroup` or an equivalent with an explicit expanded state). Built to the exact accessibility rules in §9.1. Ships in Phase 4 with the toggle.
  The setting is an accessible control in Settings/Library, defaulting to drill-down.
- Every folder detail screen shows a **breadcrumb / path** in its heading and accessibility label so a VoiceOver user always knows where they are: "News › Daily". A "Go up one level" action is always available on non-root folders.
- Depth is conveyed by wording, not visual indentation alone.

**Acceptance:** A VoiceOver user can create a subfolder, move a folder under another, navigate three levels deep, know their location at every step, and get back up, using only swipe navigation and the actions rotor.

### 7.2 Per-podcast folder association (in podcast settings)

**What:** Add a "Folders" section to the podcast settings screen (`Earshot/Features/Subscriptions/.../PodcastSettingsView`).

- Shows the folders this podcast belongs to (or "Not in any folder").
- "Add to folder…" opens the shared nested folder picker (§7.9) so the user can pick a subfolder; uses the same `FolderRepository.setMemberships`/`add` path as the Library.
- Changes announce the result: "Added to News › Daily".

**Acceptance:** From a single podcast's settings, a VoiceOver user can put it into or remove it from any folder or subfolder and hear the result.

### 7.3 Multi-select and batch "Add/Move to folder"

**What:** A selection mode for organizing many items at once. `FolderPodcastPickerView`'s live-toggle model is replaced/augmented by a real select-then-commit flow.

- **Podcasts:** In the podcast list (`SubscriptionsView`) and inside a folder, a "Select" action enters selection mode. Each row becomes selectable. A bottom bar shows the count and offers **"Add to folder"** (primary, non-destructive) and **"Move to folder"** (relocate), plus "Remove from folder" when inside one.
- **Episodes:** In the Inbox, a podcast's episode list, and any episode list, the same selection mode enables "Add/Move to folder" for episodes, plus the common episode batch actions.
- "Add to folder" adds membership without removing existing ones. "Move to folder" removes from the current folder context and places the group in the chosen target. The distinction is stated in the button labels and confirmations.
- Selecting the target uses the shared nested folder picker (§7.9), including "New folder…" inline.
- New repository methods: `addPodcasts(_:to:)`, `movePodcasts(_:to:)`, `removePodcasts(_:from:)`, and the `EpisodeFolderMembership` equivalents, each a single transaction.

**Accessibility:** see §9.2 (selection uses the `.isSelected` trait, the running count lives in the bottom-bar button label, focus is re-anchored after the mutation via `@AccessibilityFocusState`).

**Acceptance:** A VoiceOver user can select five inbox episodes and add them to a folder as a group, hearing the count as they go and the result at the end, without any long-press or drag.

### 7.4 Long-press context menu

**What:** On any episode or podcast row, a long-press (`.contextMenu`) opens the most common actions for that item.

- **Podcast menu (typical):** Open, Add/Move to folder…, notifications on/off, auto-queue on/off, inbox include/exclude, Podcast settings, Unfollow, Share.
- **Episode menu (typical):** Play now, Add to queue, Mark played/unplayed, Download / remove, Add/Move to folder…, Show notes, Share.
- The action set reuses the Quick Actions configuration (`EpisodeAction`/`PodcastAction` order) so the menu matches the actions rotor and respects the user's configured order.

**Accessibility:** the long-press menu is a **convenience layer, not the only path.** Every action in it is also a VoiceOver custom action on the row via `.rotorActions(...)`. Screen reader users are never required to discover or perform a long-press. (`.contextMenu` is itself surfaced to VoiceOver, but the rotor is the guaranteed path.)

**Acceptance:** A sighted user can long-press an episode and pick "Add to folder". A VoiceOver user reaches the identical set through the actions rotor without needing the long-press.

### 7.5 Folders as a listening lens (inbox, queue, play-all)

**What:** Make a folder somewhere you listen, not just store.

- **Folder-scoped inbox:** a folder detail "New episodes" section backed by a new folder-scoped inbox query (extend `InboxRepository`/`InboxQuery` to filter by the folder's podcasts, subtree-aware). Batch actions (§7.3) apply here.
- **Play all / queue all:** keep and improve `addFolderToQueue` (today: one newest-unplayed per podcast) into a configurable "Add all to queue" that respects the folder's `queueAgeLimitDays`, plus "Play all".
- **Folder filter on the Queue and Inbox (optional, Phase 3):** a control to view only items from a chosen folder.

**Acceptance:** From a folder, a VoiceOver user can review that folder's new episodes and start playing them, hearing how many were queued.

### 7.6 Folder management: reorder, move, rename, delete

- **Reorder folders** (extends `reorderFolders`): non-drag "Move up"/"Move down" rotor actions on each row (already the pattern in `FoldersScreen` via `QuickActionMoveLogic`), in addition to drag for sighted users. Announce the new position.
- **Move a folder** under a different parent via the nested folder picker (with cycle rejection).
- **Rename** and **delete** as today, with the nested-aware delete prompt from §7.1.
- **Reorder items within a folder** (podcasts/episodes) with the same non-drag actions (extends `reorderPodcasts`).

### 7.7 Folder-level settings

- **Queue expiration** (exists: `queueAgeLimitDays`).
- **Inbox behavior for the folder** (include/exclude all shows in the folder from the global inbox) — batch-applies the existing per-podcast `inboxExcluded`/`inboxIncluded` flags to member podcasts.
- **Export OPML for the folder and its subtree** — this needs new code: OPML **import** already parses folder groups, but **export currently drops folders** (`OPMLDocument.export` takes only `[(title:, feedURL:)]`). Add nested-group export walking the subtree.
- Future: folder-level default playback speed / auto-queue that member podcasts inherit unless overridden. Flagged, not committed.

### 7.8 Folders across every surface (the "deeply embedded" map)

A folder is never a dead end you visit once. It is a lens and a destination wherever a podcast or episode appears. Grounded in the actual SwiftUI screens.

| Surface | File(s) | What exists today | Folder integration |
|---|---|---|---|
| **Library / Subscriptions** | `Features/Subscriptions/.../SubscriptionsView.swift` | Podcast grid/list + a "Folders" toolbar entry embedding `FoldersScreen`. | Nested drill-down (§7.1); per-folder counts; multi-select of podcasts (§7.3); podcast-row "Add/Move to folder" via the Quick Actions rotor (§7.9). Folder home base. |
| **Folders / Folder detail** | `Features/Folders/Presentation/*` | `FoldersScreen`, `FolderDetailScreen`, `FolderPodcastPickerView`. | Three sections — subfolders, podcasts, episodes (§6); folder-scoped **new-episodes** section; breadcrumb heading; "Add all to queue"/"Play all"; batch actions; the shared nested picker replaces the live-toggle sheet. |
| **Inbox** | `Features/Inbox/{Data,Domain,Presentation}` | `InboxRepository`, `InboxQuery` predicates, `InboxScreen`. Podcast-level filtering only. | **Folder filter** ("Inbox: All folders ▾") via a folder-scoped `InboxQuery`; optional group-by-folder; multi-select episodes → "Add/Move to folder"; per-row folder action via the rotor (§7.9). |
| **Queue** | `Features/Queue/{Data,Domain,Presentation}` | `QueueGroup` (keyed on `Podcast`), `QueueRepository.groupedQueue()`, `QueueLogic.group` (key-generic), `QueueScreen` group-by-podcast toggle, group-header rotor (play/shuffle/move). | Add **"Group by folder"** as a third mode. `QueueLogic.group` is already key-agnostic; generalize `QueueGroup` to carry a folder key (or add a sibling) and reuse the existing group-header rotor + collapse. Highest-leverage reuse in the effort. |
| **Downloads** | `Features/Downloads/...` | Sectioned list; per-episode actions. | Optional "By folder" grouping/filter; per-episode "Add/Move to folder" via the rotor. |
| **Episode actions (shared)** | `Features/QuickActions/Domain/EpisodeAction.swift`, `EpisodeActionsBuilder.swift`; rows in `EpisodeRow.swift`, `EpisodeListView.swift`, `InboxScreen.swift` | `EpisodeAction` enum + `buildEpisodeActions(...)` → `[QuickActionItem]`, attached per screen via `.quickActionsRotor(...)`. User-ordered via `QuickActionStore`. | Add `addToFolder`/`moveToFolder` cases to `EpisodeAction` and a branch in `buildEpisodeActions` **once**; wire the callback at each call site. See §7.9. |
| **Podcast actions (shared)** | `Features/QuickActions/Domain/PodcastAction.swift`, `PodcastActionsBuilder.swift` | `PodcastAction` enum (no folder case). | Add `addToFolder`/`moveToFolder` cases + builder branch; surface in the context menu (§7.4) and podcast settings (§7.2). |
| **Podcast detail** | `Features/Subscriptions/.../PodcastDetailView` | Header + episode list. | Folder chips ("In: News › Daily") with tap-to-manage; episode rows get folder actions via the rotor. |
| **Podcast settings** | `Features/Subscriptions/.../PodcastSettingsView` | Playback + Inbox sections. | New **Folders** section (§7.2). |
| **Player / Now Playing** | `Features/Player/...`, mini player | Full player + mini bar. | "Playing from {folder path}" when the queue context is a folder; "Add this episode to folder…" in the player's more-actions. |
| **Search / Add podcast** | `Features/Search/...` | Search, add by URL, subscribe. | On subscribe, offer "Add to folder…" (only when the user already has ≥1 folder — decision F8). |
| **OPML** | `Features/.../OPMLImportService`, `OPMLDocument` | Import recreates folder groups; **export drops folders**. | Add nested-group export (§7.7); import maps nested groups → nested folders. Round-trips structure. |
| **Settings** | `Features/Settings/...` | Inbox, Playback, Downloads, etc. | A **Manage Folders** entry; the Library display-mode toggle (§7.1); iCloud sync status (§16). |
| **Stats** | `Features/Stats/...` | Listening stats. | Optional filter-by-folder. Phase 4, nice-to-have. |

### 7.9 Implementation strategy: fold folders into the shared Quick Actions system (do this early)

The app already has a shared action pipeline; adding folders **there** propagates the feature widely. Unlike the old Flutter app there is no single `EpisodeRow` every list funnels through — each surface calls the shared builder and attaches the rotor itself — so "shared" here means one enum + one builder branch + one picker, wired at each call site.

1. **Episode "Add/Move to folder" via the shared builder.** Add `addToFolder` and `moveToFolder` to `EpisodeAction` (and `defaultEpisodeActions`) and a branch in `buildEpisodeActions` that appends a `QuickActionItem` opening the folder picker. Then wire the new `onAddToFolder`/`onMoveToFolder` callback at each call site (`EpisodeListView`, `InboxScreen`, `EpisodeRow`, podcast-detail episode rows). Each site opts in; the rotor and any `.contextMenu` pick it up, and it respects the user's Quick Action order (`QuickActionStore`, configured in `QuickActionsSettingsView`).
2. **Podcast "Add/Move to folder" via `PodcastAction`.** Add the cases + `PodcastActionsBuilder` branch; wire into the context menu (§7.4) and podcast settings (§7.2) so all routes share one picker and one repository call.
3. **Reuse the queue's grouping for folders.** `QueueLogic.group` is key-generic already; generalize `QueueGroup`/`QueueScreen` to also key on a folder (subtree-aware) rather than inventing a second collapse implementation. The group-header rotor (play/shuffle/move) and the `groupQueueEpisodes` setting pattern carry over.
4. **One folder picker, used everywhere.** A single `FolderPickerView` (nested tree + "New folder…" inline) is the destination selector for per-podcast assignment, per-episode move, multi-select batch move, subscribe-to-folder, and OPML import target. Build it once; it performs the repository call, announces the result via `Announcer`, and re-anchors focus.

**Why early:** landing the enum/builder/picker first makes every subsequent surface a small wiring task with identical labels, rotor actions, and announcements — exactly the consistency a screen reader user needs for muscle memory.

---

## 8. Data model and migration plan (SwiftData)

Follow `.claude/rules/database-migrations.md` exactly. Every schema change freezes the prior version, adds a stage, ships its migration test (a required CI gate), and is manually verified on-device by installing over the previous TestFlight build.

### 8.1 Current state

- Live schema: **`EarshotSchemaV5`** (the only versioned schema pointing at the live `@Model` types). `EarshotMigrationPlan` stages: V1→V2 `.custom` (real work is the manual export/reimport in `StoreMigration.openOrMigrate`), V2→V3/V3→V4/V4→V5 all `.lightweight`.
- `SchemaDriftTests` fails if a live model drifts from the latest frozen snapshot — that means "freeze a new version", not "edit the old one".

### 8.2 Adding folder nesting + episode membership (schema V6)

1. **Freeze `EarshotSchemaV5`** as a nested snapshot inside `EarshotSchema.swift` (verbatim copies of every current live `@Model`, self-referencing `EarshotSchemaV5.Foo`, like V4 does) — required *before* the live types change, because V5 currently points at the live types.
2. Change the live models: add `PodcastFolder.parent`/`children` (both optional relationships) and the new `EpisodeFolderMembership` `@Model`.
3. Add `enum EarshotSchemaV6: VersionedSchema { static let versionIdentifier = Schema.Version(6, 0, 0); ...live types + EpisodeFolderMembership... }`.
4. Append `EarshotSchemaV6.self` to `EarshotMigrationPlan.schemas` and a `migrateV5toV6` stage. **This change is additive** (a new optional relationship + a new entity), so it is **lightweight-inferrable** — no `.custom` needed. (Reminder: adding a *non-optional* attribute is NOT inferrable; SwiftData ignores Swift property defaults as store defaults. Keep new fields optional or defaulted.)
5. Point `Schema(versionedSchema:)` in `StoreMigration`/`ModelContainerFactory` at V6. Every schema must hash distinctly. Update `SchemaDriftTests`.

### 8.3 Repository additions

Extend `FolderRepository`:

- Nesting: `childFolders(of:)`, `folderPath(_:)` (breadcrumb), `move(_:under:)` (with cycle rejection), subtree enumeration.
- Batch podcasts: `addPodcasts(_:to:)`, `movePodcasts(_:to:)`, `removePodcasts(_:from:)`.
- Episodes: `episodes(in:)`, `addEpisodes(_:to:)`, `moveEpisodes(_:to:)`, `removeEpisodes(_:from:)`.
- OPML: `subtreeSubscriptions(of:)` for nested export.
- `delete(_:mode:)` where mode is `.promoteChildren` or `.deleteSubtree`.

All batch/move operations run in a single `ModelContext` transaction and stay idempotent. New `FolderLogic` (pure) helpers: `isDescendant`, `wouldCreateCycle`, subtree flattening — kept SwiftData-free and unit-tested.

---

## 9. Accessibility specification

This is the acceptance bar. Every requirement above must satisfy this section. Grounded in the app's real accessibility infrastructure (§3.4).

**Three load-bearing correctness facts** (the SwiftUI equivalents of what the Flutter PRD called out — write these as hard requirements):

1. **Expansion state (inline tree mode) uses the expanded accessibility trait**, not a toggle/switch. Prefer `DisclosureGroup` (which announces "expanded/collapsed" itself) or set the state via `.accessibilityValue`/expanded trait on the row. Do **not** model expansion as a `Toggle`/`.isToggle` — that reads as a switch. Only rows **with children** carry the expanded state; leaf rows carry none.
2. **Selection state (multi-select) uses `.accessibilityAddTraits(.isSelected)`**, not `.isToggle`. `FolderPodcastPickerView` today uses `.isToggle` for its live-toggle behavior; the new multi-select flow is a selection, so it uses `.isSelected` and appends the state to the label when needed (pick one parity approach; don't both set the trait and duplicate the word).
3. **Programmatic VoiceOver focus after a mutation uses `@AccessibilityFocusState`** (keyed on `PersistentIdentifier`), reassigned in the same update that removes/moves rows — exactly the `FoldersScreen`/`QueueScreen` pattern. Never leave focus on a removed row.

### 9.1 Nested folder navigation

- **Drill-down (default):** tapping a folder pushes its detail via `NavigationLink`/`NavigationStack`; iOS auto-focuses the pushed screen's first element (no manual focus code needed). Depth is the navigation stack; back-swipe is the natural "collapse". Each detail screen groups children/podcasts/episodes under `Section`s with header labels; the heading carries the full path ("News › Daily"). A persistent "Go up one level" control (rotor action + visible button) on every non-root folder.
- **Folder row label:** "{name}, {n} subfolders, {m} podcasts, {k} episodes, folder". Counts are spoken, not implied by indentation. Keep parentage on the detail breadcrumb, not repeated per row.
- **Inline expand/collapse tree (opt-in, Phase 4):** use `DisclosureGroup`/expanded trait per fact 1; primary tap toggles expand/collapse, "Open folder" is a rotor action; give each row a stable `id` so focus stays put across the rebuild; never move focus to the first revealed child.
- **Reduce Motion:** honor `@Environment(\.accessibilityReduceMotion)` — instant expand/collapse and navigation transitions.

### 9.2 Multi-select and batch move

- **Model:** iOS Mail edit mode. An explicit "Select" entry point, per-row `.isSelected`, a persistent bottom bar whose button label carries the live count, and a fully tap-based flow. Drag/long-press is optional sugar; the tap path is the contract.
- **Enter/exit:** entering announces "Selection mode on" (`Announcer.announce`) and moves focus to the list's first item via `@AccessibilityFocusState`. Exit announces "Selection mode off".
- **Row state:** `.accessibilityAddTraits(.isSelected)`; since an unselected row speaks nothing extra, pick one parity approach (trait + visible checkmark, or append ", selected" to the label) and stick to it.
- **Running count is the bottom-bar button label** ("Add 3 podcasts to folder"), updated as selection changes, so it's discoverable on swipe at any time. A light `Announcer.announce("3 selected")` per toggle is optional; the button label is the source of truth. Don't fire an interruptive announcement on every tap.
- **Result + focus:** after a batch add/move — (1) dismiss the picker and auto-exit selection mode, (2) `Announcer.announce("Moved 3 podcasts to News › Daily")`, (3) re-anchor focus to a stable element (the list header or the "Select" button) via `@AccessibilityFocusState`. Never leave focus on a removed row.
- **Single-item shortcut:** also expose "Add/Move to folder…" as a per-row rotor action (via `buildEpisodeActions`/`.rotorActions`), so users don't have to enter selection mode to move one item.

### 9.3 Long-press context menu

- Convenience only. Every action is also a rotor action on the row.
- `.contextMenu` items are labeled `Button`s; keep them in the user's configured Quick Action order.

### 9.4 Cross-cutting

- All text uses semantic `Font`/text styles; verify nothing clips at the largest Dynamic Type size (long folder names + multi-part counts).
- Color is never the only signal for selected/expanded/played state; pair with SF Symbol + spoken label.
- Touch targets ≥ 44pt for every new control, including reorder and disclosure controls.
- Focus order matches visual order on every new screen and sheet.
- Announcements go through `Announcer` (polite by default, assertive only when it must interrupt).
- Every new screen ships a test asserting accessibility labels, plus a manual VoiceOver note in the PR.

### 9.5 Mandatory agent review

Per `CLAUDE.md`, run the **`earshot-accessibility`** agent on every PR that touches SwiftUI views in this effort before merge. No exceptions, including "small" changes. Relevant patterns: post-mutation focus anchoring (`@AccessibilityFocusState`), expanded/selected traits, folder role/label, and hierarchy conveyed non-visually.

---

## 10. UX flows (representative)

**Add several inbox episodes to a folder (VoiceOver):**
1. On the Inbox, invoke "Select". Hear "Selection mode on."
2. Swipe through episodes; double-tap to select each. Hear "Selected, 1 of 12", "2 of 12"…
3. Focus the bottom bar, activate "Add 3 to folder…".
4. In the nested picker, drill to "News › Daily" (or "New folder…"), activate it.
5. Hear "Added 3 episodes to News › Daily." Focus returns to the Inbox heading; selection mode off.

**Assign a podcast to a subfolder from its settings:**
1. Podcast → Settings → Folders section → "Add to folder…".
2. Drill to the target subfolder, toggle it on, Done.
3. Hear "Added to News › Daily."

**Nest and navigate:**
1. In a folder, "New subfolder here" → name it.
2. Move existing podcasts/subfolders in.
3. Drill down; heading reads the breadcrumb; "Go up one level" returns.

---

## 11. Edge cases

- Moving a folder into its own descendant is rejected (repo guard + hidden in picker). Announce nothing changed if attempted.
- Deleting a folder with children: explicit choice between promote-children and delete-subtree; podcasts/episodes never deleted.
- An episode whose podcast is unsubscribed: **decided (F3) — cascade.** Unsubscribing removes that show's episodes from any folders they were hand-added to (the `EpisodeFolderMembership` delete rule / manual cleanup handles it — §6). No orphaned memberships.
- A podcast in multiple folders shown in "Play all": de-duplicate episodes across a subtree play-all.
- Very deep nesting: no hard depth cap; breadcrumbs truncate visually while the full path stays in the accessibility label.
- Empty folder / empty section: clear spoken empty state (`ContentUnavailableView` with a real label).
- Selection mode interrupted by navigation/backgrounding: exit cleanly and announce; don't strand the user in a hidden mode.

---

## 12. Phased rollout

**Phase order approved (Michael, 2026-07-30).** iCloud sync is a **committed part of this effort**. Each phase is independently shippable and testable on device.

**Phase 1 — Foundations & per-podcast association. Complete.**
- `PodcastFolder.parent`/`children` + `EpisodeFolderMembership` schema (freeze V5, add V6, `migrateV5toV6` lightweight, migration test).
- `FolderRepository` nesting methods (cycle guard, path, move) + `FolderLogic` helpers.
- Folder detail becomes a drill-down of immediate children; breadcrumb; "Go up one level".
- Folders section in `PodcastSettingsView`.
- Non-drag reorder for folders and items (rotor "Move up/down", already the `FoldersScreen` pattern).

**Phase 2 — Shared Quick Actions plumbing + multi-select & batch. Complete.**
- Add `addToFolder`/`moveToFolder` to `EpisodeAction` + `PodcastAction`, extend the builders, build the one reusable `FolderPickerView`, wire the call sites. Lights up "Add/Move to folder" in Inbox, Queue, Downloads, Podcast detail — rotor + context menu.
- Selection mode + batch bar in the podcast list and folder podcast lists; batch repository methods.
- Episode membership surfaced: episode selection in Inbox and episode lists; folder detail gains podcasts + episodes sections.

**Phase 3 — Context menu, listening lens, queue/inbox embedding. Complete.**
- `.contextMenu` on episode/podcast rows wired to Quick Actions config, rotor parity.
- **"Group by folder" in the Queue**, reusing `QueueLogic.group` + the group-header rotor.
- **Folder-scoped inbox** (`InboxQuery` extension) + folder detail new-episodes section; "Add all to queue"/"Play all"; folder queue expiration honored.
- Nested OPML export for a subtree; subscribe-to-folder on Search/Add.

**Phase 4 — Broader embedding & polish. Complete per `docs/folders-phase-4.md`.**
- Downloads "by folder"; player "Playing from {folder path}" + add-to-folder; podcast-detail folder chips.
- Inline expand/collapse tree on the Library root + the display-mode toggle (§7.1).
- Folder-level inbox include/exclude batch; stats-by-folder; consider inherited playback speed / auto-queue.

The approved Phase 4 task plan shipped the inline tree, Downloads filter,
transient playback origin, and folder-scoped Stats. Three ideas from the earlier
rollout sketch remain deliberately deferred rather than silently treated as
complete: a drill-down/inline Library display toggle, podcast-detail folder
chips, and folder-level inbox include/exclude batching. Inherited playback speed
and auto-queue remain uncommitted considerations.

**Next: Sync Phase A.** The CloudKit-compatible schema prep (§16.4) is a distinct migration that must land **before** sync turns on, and it changes model constraints (drops `@Attribute(.unique)`, adds defaults). Ship it as its own migration epoch after the now-proven folder schema, verify an upgrade from TestFlight build 161 on real data, and let it bake before enabling the CloudKit mirror. Sync engine + UX (§16.5–16.8) follow once the schema has baked. Smart folders (§17) can begin after Sync Phase A so their definitions are CloudKit-compatible from their first schema version.

---

## 13. Testing and definition of done

For every phase:

- `xcodebuild test` clean on the CI simulator (see `.claude/rules/git-workflow.md` for the exact invocation; StoreKit suites skipped per #679).
- New/changed screens have tests asserting accessibility labels, selection-count announcements, and expand/collapse focus behavior.
- **Schema migration test is a required gate** (`.claude/rules/database-migrations.md`): open a store seeded at the prior version with realistic aged fixtures, run the migration, assert no throw and correct shape. `SchemaDriftTests` updated.
- `earshot-accessibility` run on every UI PR; findings resolved before merge.
- Manual VoiceOver pass on device: create/nest/move/delete folders, per-podcast assignment, multi-select add/move of podcasts and episodes, context menu, folder play-all — all reachable and announced. Note the iOS version in the PR.
- Manual upgrade test: install the previous TestFlight build, create real data (feeds, folders, memberships, queue), install the new build over it, confirm everything loads.
- No color-only state. Nothing clips at largest Dynamic Type.

A phase is done when a blind tester can complete that phase's flows end-to-end with VoiceOver and no sighted help.

---

## 14. Decisions (resolved 2026-07-30)

Kept as the decision record.

1. **Model — unified.** A folder holds subfolders, podcasts, and episodes. No separate Collections. See §6.
2. **Multi-select default — Add.** "Add to folder" (non-destructive) is the prominent primary action; "Move" is secondary. See §7.3.
3. **Unsubscribe — cascade.** Unsubscribing a podcast removes its episodes from any folders they were hand-added to. See §11.
4. **Library tree — both, user-configurable.** Ship a drill-down (default) and an inline expand/collapse tree, with a Library display setting. See §7.1 / §9.1.
5. **Depth — no cap.** Unlimited nesting; breadcrumbs truncate visually while the full path stays in the accessibility label.
6. **Context menu — mirror Quick Actions.** The `.contextMenu` follows the user's configured Quick Actions order, matching the rotor. See §7.4.
7. **List embedding — filter + Queue grouping.** Single-folder filter on Inbox & Downloads; group-by-folder in the Queue (reuses `QueueLogic.group`). Smart folders are selectable as the filter too (§17). See §7.8.
8. **Auto-file on subscribe — when folders exist.** After subscribing from Search, offer "Add to folder…" only if the user already has ≥1 folder. See §7.8.

---

## 15. Success metrics

- A blind tester organizes a 40-show library into a two-level folder structure in one sitting with VoiceOver and no sighted help.
- Batch-adding 5 episodes to a folder takes noticeably fewer gestures than one at a time, and the count and result are always spoken.
- No accessibility regression on any existing screen (verified by `earshot-accessibility` and on-device VoiceOver).
- Zero migration-related failures after the schema bumps (per `.claude/rules/database-migrations.md`).

---

## 16. iCloud sync (folders, subscriptions, and listening state)

Earshot should keep a user's world in step across their Apple devices: the same folders and nesting, the same subscriptions, queue, bookmarks, played state, and playback positions on iPhone and iPad — **without Earshot ever running a server that sees user data.**

**Chosen approach (Michael, 2026-07-30): SwiftData's built-in CloudKit sync**, not a hand-rolled sync engine. SwiftData can mirror a store to the user's **private CloudKit database** automatically (`ModelConfiguration(..., cloudKitDatabase: .private("iCloud.media.payown.earshot"))`, backed by `NSPersistentCloudKitContainer`). Apple owns the sync engine, the conflict handling, and the change tracking. This is far less code than `CKSyncEngine` and the strongest possible fit for the zero-data-collection rule: sync *reduces* Earshot's data footprint versus any hosted backend.

### 16.1 Principles

- **One library, many devices.** Folders (nesting + memberships), subscriptions, queue, bookmarks, inbox state, per-podcast settings, and playback progress converge across the user's Apple devices.
- **Zero-knowledge to Payown.** Data lives only in the user's private iCloud. Payown runs no server, sees nothing, stores nothing.
- **Accessibility is not an afterthought.** Every sync surface — onboarding prompt, status, errors — is fully VoiceOver-operable and announces meaningful change via `Announcer`.
- **Correctness over speed.** A late but correct merge beats a fast one that loses a folder or resurrects a deleted show.

### 16.2 What syncs vs. stays local

| Syncs (user state, mirrored via CloudKit) | Stays device-local |
|---|---|
| Subscriptions (`Podcast`, by `feedURL`) | Downloaded audio files + `downloadPath`/`downloadStatus` |
| Folders: names, nesting (`parent`), sort order, `queueAgeLimitDays` | Cached artwork/images |
| `FolderMembership` + `EpisodeFolderMembership` | Transient UI state, scroll positions |
| `QueueItem` contents and order | Logs |
| `Bookmark`s | The on-disk store file itself (CloudKit mirrors records, not the file) |
| Episode **state** (played/position/`inboxDismissed`) | |
| Per-podcast inbox/playback settings; genuinely-global app settings | |
| Listening history / stats; user download *preferences* (decision SY2) | |
| Smart folder definitions (§17) — results recomputed per device | |

> **Decision SY2 — sync everything.** Listening history/stats and download *preferences* (Wi-Fi-only, auto-download) sync too; only device-bound things stay local: audio bytes, caches, transient UI, logs. Surface synced download preferences clearly in settings so a change on one device isn't a surprise on another.

Downloaded audio is deliberately not synced (multi-gigabyte, pointless through iCloud). The *intent* (queued/played) syncs, so another device can offer to download locally.

### 16.3 Sync identity: SwiftData does it for us

With the CloudKit mirror, SwiftData assigns each record a stable CloudKit identity and reconciles by it — so the Flutter PRD's hand-rolled `syncId`/UUID scheme is **not needed**. Relationships sync as CloudKit references. Two nuances:

- **`feedURL` and `guid` are still the natural keys for dedup.** Because CloudKit forbids unique constraints (§16.4), two devices could each create a "Podcast(feedURL: X)" before they converge. Keep an app-level dedup pass (merge duplicate podcasts/episodes by `feedURL`/`guid` after sync) — small, testable, and the only reconciliation logic we own.
- **Episodes are derived from feeds.** Each device already fetches feeds and holds full episode rows. We rely on the CloudKit mirror for episode *state*; a device that hasn't yet fetched a referenced episode applies incoming state on its next feed refresh (match on `guid` + podcast `feedURL`).

### 16.4 CloudKit-compatible schema (a real migration, before any sync)

The current schema is **not** CloudKit-ready. Enabling the mirror requires a schema that satisfies CloudKit's rules, which is itself a migration — follow `.claude/rules/database-migrations.md` to the letter (freeze the prior version, migration test, on-device upgrade test).

CloudKit + SwiftData constraints and the required changes:

1. **No `@Attribute(.unique)`.** CloudKit rejects unique constraints. Today `Podcast.feedURL` and `AppSetting.key` are `.unique` (`Podcast.swift`, `AppSetting.swift`). Drop `.unique` and enforce uniqueness in the repository layer (a fetch-or-create by `feedURL`/`key`, plus the §16.3 dedup pass).
2. **Every non-optional attribute needs a default (or becomes optional).** CloudKit-mirrored attributes must be optional or have a default. Audit each `@Model` (e.g. `Episode.guid/title/audioURL`, `PodcastFolder.name/sortOrder`) and add defaults or make optional.
3. **All relationships optional.** CloudKit requires optional relationships with inverses. Folder relationships (`memberships`, `folder`, `podcast`, the new `parent`/`children`, episode membership) must all be optional — most already are.
4. **No `deleteRule: .cascade` guarantees across the mirror.** CloudKit deletes propagate as record deletions; keep app-level cleanup (the `removeFromAllFolders`-style discipline) so a delete on one device doesn't strand memberships on another.

This lands as its own **schema version(s)** (freeze current, add the CloudKit-ready version + stage). Because dropping `.unique` and adding defaults changes model definitions, sequence it deliberately in the migration plan (§12). No sync *behavior* ships until this schema has baked on TestFlight.

### 16.5 Turning sync on

- Build the `ModelContainer` with a `ModelConfiguration` whose `cloudKitDatabase` targets the app's private container. `NSPersistentCloudKitContainer` handles push/pull, change tokens, and background sync — no manual engine, no platform channel (this is native Swift; the Flutter-era "Swift platform-channel bridge + pbxproj UUIDs" section of the old PRD is gone).
- **Entitlements/capabilities:** add the iCloud + CloudKit capability and the background-modes (remote notifications) the mirror needs. Per `AGENTS.md`, capabilities/entitlements/signing changes need explicit sign-off and are made carefully (`project.yml` + regenerate).
- All DB work stays off the main actor where it already is; the mirror syncs in the background and never blocks the UI or playback.

### 16.6 Conflict resolution (native, with app-level touch-ups)

SwiftData + CloudKit reconciles at the **record level, last-writer-wins**. That is coarser than the Flutter PRD's per-field rules, and we accept it as the baseline, with targeted app-level handling where LWW is user-hostile:

- **Playback position:** record-level LWW can "rewind you from your other device." Add an app-level rule on merge: prefer the **furthest** position unless a newer explicit "mark unplayed" reset it. This is a small reconciliation we own, applied when a position update arrives.
- **Memberships (podcast/episode ↔ folder):** modeled as independent join records, so adds/removes from two devices union naturally; an explicit remove (record deletion) wins over a stale add.
- **Folder tree (`parent`):** LWW on the parent pointer, then run the cycle guard (§7.1) after merge; if two edits would form a cycle, reattach the losing branch to root and announce it on the device that loses.
- **Queue order:** LWW per `QueueItem.position`, then a deterministic re-compaction pass (the queue already recompacts positions) so both devices land on the same dense sequence.
- **Deletes vs edits:** CloudKit record deletion wins over a concurrent edit (no resurrection); folder deletes never delete podcasts/episodes (§7.1).

Where native LWW is acceptable (played status, settings, bookmarks) we do nothing extra.

### 16.7 Scope: Apple platforms only

iOS/iPadOS. CloudKit's private database is the one and only backend. No Android, no cross-platform server.

### 16.8 UX and accessibility

- **Opt-in reality:** SwiftData's CloudKit mirror is configured at container creation and follows the device's iCloud sign-in. Because you can't cleanly toggle a live store between synced/non-synced per launch, the opt-in is designed as: the app respects the system iCloud state, and a clear in-app **"iCloud sync"** setting explains what syncs and lets the user turn the feature off (which stops mirroring going forward and leaves local data intact). Design this toggle honestly around the container's real lifecycle — spell out the exact mechanism during Phase design, don't over-promise a per-flip switch.
- **Onboarding / status:** an accessible prompt ("Your folders and progress stay in step across your Apple devices. Everything stays in your private iCloud — Payown never sees it."). A Settings status surface: "iCloud sync: On", "Last synced …", a plain-language state when unavailable. Text + SF Symbol, never color alone.
- **Announcements:** sync completion/failure via `Announcer`, sparingly ("Synced", "iCloud is not signed in"). No chatter on routine syncs.
- **Conflict transparency:** the rare visible resolution (a folder reattached to root after a cycle) is announced and shown, never silent (decision SY4).
- **No blocking:** the app is fully usable offline; changes mirror when iCloud is available.
- Follows every existing rule: `Announcer` for change, semantic fonts, ≥44pt, largest Dynamic Type.

### 16.9 Edge cases

- **iCloud signed out / unavailable:** detect and show "Sign in to iCloud in Settings to sync." Keep working locally.
- **iCloud storage full / quota:** surface a clear, accessible message; app stays functional.
- **Account switch:** CloudKit scopes data to the signed-in account; on switch, do not merge one person's library into another's.
- **First sync on a large library:** the mirror batches/backgrounds it; never freeze the app; show progress accessibly.
- **Migration + sync interaction:** a device must finish its local schema migration before it mirrors, so it never pushes half-migrated state.
- **Duplicate creation before convergence:** handled by the §16.3 dedup pass (by `feedURL`/`guid`).

### 16.10 Phasing

- **Sync Phase A — CloudKit-ready schema.** Drop `.unique`, add defaults/optionality (§16.4), app-level fetch-or-create dedup. Ships and bakes on TestFlight. No sync behavior yet.
- **Sync Phase B — enable the mirror.** CloudKit capability/entitlements, `cloudKitDatabase` configuration, the position/cycle/queue app-level touch-ups (§16.6), dedup pass. Behind a flag; dogfood on two devices.
- **Sync Phase C — enable + UX.** Onboarding, Settings status/toggle, announcements, edge cases. Public.
- **Sync Phase D — hardening.** Two-device conflict stress tests, large-library performance, account-switch flows.

### 16.11 Testing and definition of done

- **Two-device manual matrix:** create/move/delete folders, reorder queue, mark played, change position on device A → verify convergence on B, and vice versa.
- **Conflict simulations:** concurrent parent moves (cycle), add-vs-remove membership, rewind-vs-advance position, delete-vs-edit — assert the documented behavior.
- **Migration tests:** upgrade from the pre-sync schema against realistic aged fixtures; assert no throw and that dedup collapses duplicates.
- **Offline/online:** edit offline, converge on reconnect, no loss.
- **Account states:** signed out, quota full, account switch — all reach a usable, accessible state.
- **Accessibility:** `earshot-accessibility` on every sync UI PR; VoiceOver pass on onboarding, status, errors.
- **Privacy check:** confirm nothing leaves the user's private iCloud; nothing is sent to any Payown or third-party endpoint.

Done when a blind user can turn on iCloud sync and folders + progress converge across two Apple devices, every step operable and announced under VoiceOver, and no data ever reaches Payown.

### 16.12 Decisions (resolved 2026-07-30)

1. **Transport — SwiftData native CloudKit (SY3, revised for SwiftUI).** Use SwiftData's built-in CloudKit mirror (`NSPersistentCloudKitContainer`), not a hand-rolled `CKSyncEngine` and not the Flutter-era platform-channel bridge. App-level dedup + targeted conflict touch-ups (§16.6) layer on top. Revisit `CKSyncEngine` only if native LWW proves user-hostile beyond the touch-ups.
2. **Scope — sync everything (SY2).** History/stats and download preferences sync; only audio bytes, caches, transient UI, logs stay local. See §16.2.
3. **Sync identity — SwiftData/CloudKit-managed (SY1, revised).** No hand-rolled `syncId`; rely on CloudKit record identity + app-level dedup by `feedURL`/`guid`. See §16.3.
4. **Conflict visibility — silent, notify on visible change (SY4).** Resolve silently; surface a note only when a merge visibly changed the user's structure. See §16.8.
5. **Platform — iOS/iPadOS only.** See §16.7.

---

## 17. Smart (dynamic) folders

A **smart folder** has no hand-filed contents. You define a rule, and the folder shows whatever matches, live. Manual folders are where you *put* things; smart folders are where things *land on their own*. Both live in the same tree and compose: a smart folder's rule can reference a manual folder, and a smart folder can be placed inside a manual one.

### 17.1 What it is

- A **named, rule-defined lens** over your episodes (or, secondarily, your podcasts).
- Contents are **computed, not stored** — no membership rows; a saved query.
- It behaves like any folder where it counts: appears in the tree, has a detail screen, supports "Play all"/"Add all to queue", and its episodes expose the same rotor actions (including "Add to a *manual* folder…"). You just can't hand-add/remove items.
- Clearly marked as smart in visuals **and** accessibility label ("smart folder, updates automatically") so a screen reader user always knows the difference (§17.6).

### 17.2 Starter smart folders (ship these)

- **Continue Listening** — `positionSeconds > 0` and not finished, newest activity first.
- **New This Week** — `status == .newEpisode`, published in the last 7 days.
- **Quick Listens** — unplayed, duration under ~20 minutes.
- **Downloaded & Unplayed** — `downloadStatus == .downloaded`, not played.
- **Long Reads** — unplayed, duration over ~1 hour.

Editable, duplicable, deletable (decision SM4).

### 17.3 The rule model

A small rule document: a **match mode** (`all` = AND / `any` = OR) plus **conditions** (`field` + `operator` + `value`), a **sort**, and an optional **limit**. Fields, grounded in the real `Episode`/`Podcast` models: play state (`status`, `positionSeconds`, `isPlayed`, in-queue via `QueueItem`), download (`downloadStatus`), time (pubDate window, duration, `createdAt`), source (podcast is one of…, **podcast is in manual folder …** ← composition hook), organization (in manual folder …, has a bookmark, `inboxDismissed`), text (title/notes contains …). Sort: newest/oldest/shortest/longest/recently-active, optional cap. Target: episodes by default; podcasts as a secondary mode.

### 17.4 Composition with the unified model

- **Smart references manual:** "podcast is in **News**" (subtree-aware) — so "Unplayed, under 20 min, from my News folder" is one smart folder over a manual one.
- **Manual contains smart:** a smart folder can be placed under a manual parent (it is a leaf — never holds manual children). So "Commute" can contain the "Quick Listens" smart folder next to hand-filed shows.

### 17.5 Data model and query engine (SwiftData)

New `@Model` (schema bump, freeze + add a version + lightweight stage — §8):

```swift
@Model final class SmartFolder {
    var name: String = ""
    var targetType: String = "episode"   // "episode" | "podcast"
    var matchMode: String = "all"         // "all" | "any"
    var rulesJSON: String = ""            // encoded rule document
    var sortBy: String?
    var itemLimit: Int?
    @Relationship(deleteRule: .nullify) var parent: PodcastFolder?   // placement in the tree
    var sortOrder: Int = 0
    var createdAt: Date = .now
}
```

- **Rules as an encoded document** (`Codable` → JSON string) in one attribute: simplest, syncs as one CloudKit field, and CloudKit-friendly (all defaulted/optional — §16.4).
- **Engine:** decode the rule and translate it into a SwiftData `#Predicate<Episode>` + `FetchDescriptor` (sort + `fetchLimit`), exposed as a live query (`@Query` with a dynamic predicate, or a repository returning `[Episode]` that the detail view observes) so it updates as episodes change. Prefer store-level predicates over fetch-everything-then-filter (see `.claude/rules/performance.md`; the Inbox `InboxQuery` predicates are the model to follow). `#Predicate` has limits — conditions it can't express fall back to a bounded fetch + in-memory filter, never an unbounded scan.
- **Composition** ("in manual folder X") compiles to a membership/subtree check reusing the same subtree walk as OPML export (§8.3).

### 17.6 UX and accessibility

- **Builder screen** — an accessible SwiftUI form: a "Match all / Match any" `Picker`, a list of conditions (each a field `Picker` + operator `Picker` + value input), add/remove buttons, sort `Picker`, optional limit, and a **live preview count** ("Matches 23 episodes right now"). Pickers and steppers, never drag; every control labeled; errors in text (per `.claude/rules/accessibility.md`).
- **Distinct identity:** a distinct SF Symbol **and** the accessibility label — "Quick Listens, smart folder, 12 episodes, updates automatically" — so icon/color is never the only signal.
- **Read-only membership, actionable contents:** the detail screen states it's rule-driven; each episode still exposes Play / Queue / "Add to a manual folder…" via the shared rotor plumbing (§7.9).
- **Announce sparingly:** normal live list; don't announce automatic changes. Announce deliberate actions (saved rule, "Added all to queue").

### 17.7 Edge cases

- **Rule references a deleted manual folder:** the condition goes inert and is flagged in the builder ("This folder no longer exists"); other conditions still run.
- **Empty result:** clear spoken empty state.
- **Over-broad rule:** the preview count and optional cap warn before it matches the whole library.
- **Cycle-free by construction:** smart folders are leaves, adding no nesting-cycle risk.
- **Performance:** cap + store-level predicates; same cost model as the inbox query.
- **Sync:** only the definition syncs; each device recomputes results against its own episode rows.

### 17.8 Phasing

- **Smart Phase 1 — engine + starters.** `SmartFolder` schema, rule → `#Predicate`/`FetchDescriptor` translator, live query, the five starters shown in the tree with detail + play-all. No builder yet.
- **Smart Phase 2 — builder UI.** The accessible rule builder (§17.6): create/edit/duplicate/delete, preview count.
- **Smart Phase 3 — composition + podcast targets.** "in manual folder X" (subtree-aware) and podcast-target smart folders; placement under manual parents.

Depends on manual folders + episode membership (§6–§9) first.

### 17.9 Decisions (resolved 2026-07-30)

1. **Rule storage — encoded document (SM1).** Rules as a `Codable` JSON string in one attribute; syncs as one field. See §17.5.
2. **Smart folder as filter — yes (SM2).** Selectable as the Inbox/Queue folder filter. See §7.8 / §17.6.
3. **Podcast-target smart folders — Smart Phase 3 (SM3).** With composition. See §17.8.
4. **Starters — fully editable (SM4).** Edit, duplicate, delete freely.

---

## Appendix A — Concrete plumbing sketch (illustrative, not final code)

Shows the shape of the §7.9 changes against real signatures. A design sketch for review, not code to paste. Confirm against `HEAD`.

### A.1 New episode/podcast actions in the enums

`Earshot/Features/QuickActions/Domain/EpisodeAction.swift` — add two cases so folder moves are user-orderable Quick Actions and flow to the rotor everywhere:

```swift
enum EpisodeAction: String, CaseIterable, Identifiable, Codable {
    case playNow, addToQueueTop, addToQueueBottom, download, markPlayed
    case viewBookmarks, openShowNotes, share, exportAudio
    case addToFolder     // NEW — non-destructive: add membership, keep existing
    case moveToFolder    // NEW — relocate: remove from current folder context
    case unfollow
    // label: addToFolder -> "Add to folder", moveToFolder -> "Move to folder"
}
// Append to defaultEpisodeActions so existing users get them; reorderable/hideable
// in QuickActionsSettingsView.
```

`PodcastAction.swift` gains `addToFolder`/`moveToFolder` the same way.

### A.2 One branch in each builder, then wire the call sites

`Earshot/Features/QuickActions/Domain/EpisodeActionsBuilder.swift` — `buildEpisodeActions(...)` gains an `onAddToFolder`/`onMoveToFolder` callback and a branch appending a `QuickActionItem`:

```swift
case .addToFolder:
    items.append(QuickActionItem(label: action.label) { onAddToFolder(episode) })
case .moveToFolder:
    items.append(QuickActionItem(label: action.label) { onMoveToFolder(episode) })
```

Unlike the old Flutter app, there is **no single row every list funnels through** — each surface (`EpisodeListView.swift`, `InboxScreen.swift`, `EpisodeRow.swift`, podcast-detail episode rows) calls `buildEpisodeActions(...)` and attaches `.quickActionsRotor(actions)` itself. So the wiring is: add the enum case + builder branch **once**, then pass the new callback (usually "present the shared `FolderPickerView`") at each call site. The rotor and any `.contextMenu` then pick it up automatically and respect the user's Quick Action order.

### A.3 One reusable folder picker (used by every entry point)

A single `FolderPickerView` backs per-podcast assignment, per-episode move, multi-select batch move, subscribe-to-folder, and OPML import target. It shows the nested tree (§7.1) with "New folder…" inline, performs the repository call, announces the result via `Announcer`, and re-anchors focus:

```swift
enum FolderPickMode { case add, move }

struct FolderPickerView: View {
    let episodes: [Episode]      // batch of one, or many for multi-select
    let podcasts: [Podcast]
    let mode: FolderPickMode
    // Presented as a sheet. Nested tree + "New folder…"; on pick, calls the
    // batch FolderRepository method (A.5), then:
    //   Announcer.announce("Moved 3 episodes to News › Daily")
    //   and re-anchors VoiceOver focus via @AccessibilityFocusState.
}
```

### A.4 Podcast side reuses `PodcastAction`

The new `PodcastAction.addToFolder`/`.moveToFolder` feed the `.contextMenu` (§7.4) and the podcast-settings Folders section (§7.2). For batch, `FolderPickerView(podcasts: […])` is the podcast-list analogue.

### A.5 Repository batch methods (from §8.3)

`FolderPickerView` calls the batch/transaction methods added to `FolderRepository`:

```swift
func addEpisodes(_ episodes: [Episode], to folder: PodcastFolder)
func moveEpisodes(_ episodes: [Episode], to folder: PodcastFolder)
func addPodcasts(_ podcasts: [Podcast], to folder: PodcastFolder)
func movePodcasts(_ podcasts: [Podcast], to folder: PodcastFolder)
```

### A.6 Queue "group by folder" reuses existing grouping

`Earshot/Features/Queue/` already groups by podcast. `QueueLogic.group` is key-generic, so:

- Replace the `groupQueueEpisodes` boolean with a small `QueueGrouping { none, podcast, folder }` (keep a migration for the stored setting).
- Add a folder-keyed grouping alongside `QueueRepository.groupedQueue()` that buckets the same episodes by folder (subtree-aware), reusing `QueueGroup` with an optional folder key (or a sibling type).
- The existing group-header rotor (play/shuffle/move) and collapse work unchanged — "Play group" becomes "Play folder", etc. Largest single reuse in the effort; inherits the queue's already-audited VoiceOver behavior.

*End of Appendix A. Signatures match the codebase as of this draft; confirm against `HEAD` before implementing.*

---

*For Michael. Manual-folder Phases 1–4 are complete. **All decisions are confirmed (2026-07-30):** §14, §16.12, and §17.9, plus the SwiftUI/SwiftData grounding and the switch to SwiftData-native CloudKit sync. **Next step:** Sync Phase A gets its just-in-time phase document and GitHub issues before implementation. Per project rules, no work starts on `main`, every UI PR gets an accessibility review first, and every schema change ships its migration test. Scope is iOS/iPadOS only.*
