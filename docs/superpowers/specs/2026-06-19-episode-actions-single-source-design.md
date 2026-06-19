# Episode Quick Actions: one source of truth (incl. the VoiceOver rotor)

**Date:** 2026-06-19
**Branch:** feat/episode-actions-single-source
**Status:** Design approved (verbal), pending spec review

## Problem

Reordering episode Quick Actions is a flagship feature, but today it does not
behave consistently:

1. **The VoiceOver Actions rotor ignores the user's configured order.** It is
   seeded from a hardcoded list (`episodeActionRotorOrder` in
   `lib/core/episode_action_builder.dart`), so reordering in Settings never
   changes the rotor. This is the core complaint.
2. **Actions/order can differ per screen.** Not every episode surface is
   guaranteed to build from the single configured list, so the same episode can
   present different actions or order on inbox vs queue vs search vs player.
3. **(Already fixed, shipped in commit 77f6454)** A duplicate-key save could
   silently roll back, reverting the saved order. Kept here for completeness.

## Verified platform constraint (Flutter 3.44 source)

- Each rotor action label is assigned an integer id the first time it is passed
  to `CustomSemanticsAction.getIdentifier` (`semantics.dart:786`, `_nextId++`),
  cached process-wide in a static map.
- Flutter sorts each node's action ids ascending before sending to iOS
  (`semantics.dart:3959`). So **rotor order = ascending id = first-seen order at
  startup.**
- The id cache cannot be reset in a release build (the only reset,
  `resetForTests`, is gated behind `assert`).

**Implication:** the rotor order is fixed for the life of the process. We can
make it follow the user's configured order by seeding the labels at startup in
that order. A reorder made in Settings applies to the rotor on the **next app
launch**. (A self-relaunch is not possible on iOS — `exit(0)` does not reopen
the app and reads as a crash, so it is rejected.)

## Design: the configured list drives everything

The user's persisted episode-action order (`quick_action_configs`, content type
`episode`, read via `episodeActionsProvider`) becomes the single source of truth
for all three surfaces:

### 1. Per-screen action list — one builder, capability-filtered
- Every episode surface builds its actions through `buildEpisodeActions(...)`
  with `order` = the configured order, filtered only by `allowedEpisodeActions`
  (episode capability/state) and the screen context (`list` vs `queue`).
- **Audit task:** confirm every surface uses this path and none passes a
  divergent order or a hand-rolled action list. Known surfaces: inbox,
  downloads, podcast detail, queue (`buildEpisodeActions`); search detail
  (`orderEpisodeActionItems`, non-persisted preview episodes); the Now Playing
  player (verify it builds from the same order). Bring any outlier onto the
  shared builder.

### 2. Default double-tap action
- The first action in the configured order is the default activation. Confirm
  each surface uses `items.first` for `onTap`, not a hardcoded action.

### 3. VoiceOver rotor — seeded from config at startup
- Replace the hardcoded `episodeActionRotorOrder` const with a function that
  builds the seed order from the configured `List<EpisodeAction>`:
  - For each action in configured order, register all of its **state-variant
    labels adjacently** (e.g. Download / Remove download / Cancel download /
    Retry download; Mark as played / Mark as unplayed; Add to end of queue /
    Remove from queue; Play next / Move to play next). This keeps a logical
    action's rotor slot stable as the episode's state changes.
  - After the configured episode actions, append the queue-screen-only move
    block (Move to top / up / down / bottom) so it always sorts last on queue
    rows. These are not user-configurable episode actions.
- A single source for the per-action variant labels must stay in sync with the
  labels emitted in `_buildItem`. A test asserts completeness (every label
  `_buildItem` can emit is present in the seed expansion) so drift is caught.

### 4. Startup wiring (`main.dart`)
- Before `runApp` and before any episode row builds, read the persisted episode
  order and seed the rotor from it.
- This adds a DB read before `runApp`. Per `.claude/rules/database-migrations.md`
  it MUST be wrapped in try/catch: on any failure, log + `Sentry.captureException`
  and fall back to `defaultEpisodeActions` so startup never hangs.

### 5. Save feedback (`quick_action_configurator_screen.dart`)
- On a successful episode save, append a rotor heads-up to the existing
  announcement, e.g. "Quick actions saved. Reopen Earshot to update the rotor
  order." (Only for episode content type; the menu and default update instantly,
  only the rotor waits for relaunch.)
- Keep the dedup save and failure SnackBar/announcement already shipped.

## What we are NOT doing
- No self-relaunch / `exit(0)` on save (impossible + bad UX on iOS).
- No replacing the rotor with per-action focusable elements (large interaction
  change; only revisit if instant rotor updates become a hard requirement).
- No DB schema change. The dedup save self-heals legacy data.
- No unrelated refactoring of the surfaces beyond routing them to the shared
  builder.

## Testing
- Unit: rotor seed expansion follows a given configured order; variant labels
  adjacent; queue move block appended last; completeness vs `_buildItem` labels.
- Unit: `allowedEpisodeActions` capability filtering unchanged per context.
- Repo: existing dedup + reorder-persistence regression tests stay green.
- Startup: seeding falls back to defaults when the DB read throws (guarded).
- Accessibility: run `mobile-accessibility` on the configurator + any surface
  touched; manual VoiceOver note that rotor reflects configured order after a
  relaunch.

## Definition of done
- Reordering in Settings changes: the More-actions menu order and default
  double-tap **immediately**, and the VoiceOver rotor order **after relaunch**,
  with a spoken heads-up on save.
- The same episode presents the same actions in the same order on every screen,
  differing only by the episode's real capability/state and the queue's own move
  block.
- All tests + `flutter analyze` green; accessibility review passed.
