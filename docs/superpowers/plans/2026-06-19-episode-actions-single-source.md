# Episode Quick Actions Single Source of Truth — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the user's saved episode-action order the single source of truth for the More-actions menu, the default double-tap, and the VoiceOver Actions rotor — so reordering in Settings is reflected everywhere (rotor on next launch).

**Architecture:** The rotor order on iOS equals the ascending first-seen `CustomSemanticsAction` id order (Flutter sorts ids before sending; `semantics.dart:3959`), and the id cache can't be reset in release. So we seed the rotor at startup from the persisted order instead of a hardcoded list. The menu/default already read the configured order; only the rotor seed and startup wiring change, plus a save heads-up.

**Tech Stack:** Flutter 3.44, Dart, Riverpod, drift, flutter_test.

---

### Task 1: Rotor seed follows the configured order

**Files:**
- Modify: `lib/core/episode_action_builder.dart` (replace `episodeActionRotorOrder` const + `seedEpisodeActionRotorOrder()` at lines 93–146)
- Test: `test/core/episode_action_builder_test.dart` (replace the test at lines 160–182, add two tests)

- [ ] **Step 1: Write the failing tests**

Replace the existing `test('rotor seed list covers every label an action can emit', ...)` (lines 160–182) with these three tests:

```dart
  test('rotor labels follow the configured order, variants adjacent, moves last',
      () {
    final labels = episodeActionRotorLabels(const [
      EpisodeAction.openShowNotes,
      EpisodeAction.download,
      EpisodeAction.playNow,
    ]);
    expect(labels, [
      'Open show notes',
      'Download', 'Remove download', 'Cancel download', 'Retry download',
      'Play now',
      'Move to top', 'Move up', 'Move down', 'Move to bottom',
    ]);
  });

  test('every EpisodeAction has rotor variant labels including its base label',
      () {
    for (final a in EpisodeAction.values) {
      final variants = episodeActionVariantLabels[a];
      expect(variants, isNotNull, reason: '$a missing from variant map');
      expect(variants, contains(a.label), reason: '$a base label missing');
    }
  });

  test('rotor seed covers every label an action can emit', () {
    final all = episodeActionRotorLabels(EpisodeAction.values.toList());
    final emittable = <String>{
      for (final a in EpisodeAction.values) a.label,
      'Move to play next',
      'Remove from queue',
      'Mark as unplayed',
      'Remove download', 'Cancel download', 'Retry download',
      'Move to top', 'Move up', 'Move down', 'Move to bottom',
    };
    for (final label in emittable) {
      expect(all, contains(label),
          reason: '"$label" can be emitted but is missing from the rotor seed');
    }
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/core/episode_action_builder_test.dart`
Expected: FAIL — `episodeActionRotorLabels` and `episodeActionVariantLabels` are undefined.

- [ ] **Step 3: Implement**

In `lib/core/episode_action_builder.dart`, delete the `episodeActionRotorOrder` const (lines ~93–137) and the existing `seedEpisodeActionRotorOrder()` (lines ~139–146), and replace with:

```dart
/// The state-variant labels each configurable [EpisodeAction] can present in a
/// row's VoiceOver Actions rotor, in a stable sub-order. Only one variant shows
/// per row at a time (see [_buildItem]); seeding all of them adjacently keeps a
/// logical action's rotor slot stable as the episode's state changes. MUST stay
/// in sync with every label [_buildItem] can emit (a test asserts this).
const episodeActionVariantLabels = <EpisodeAction, List<String>>{
  EpisodeAction.playNow: ['Play now'],
  EpisodeAction.playNext: ['Play next', 'Move to play next'],
  EpisodeAction.addToEndOfQueue: ['Add to end of queue', 'Remove from queue'],
  EpisodeAction.markPlayed: ['Mark as played', 'Mark as unplayed'],
  EpisodeAction.openShowNotes: ['Open show notes'],
  EpisodeAction.bookmark: ['Bookmark current spot'],
  EpisodeAction.download: [
    'Download',
    'Remove download',
    'Cancel download',
    'Retry download',
  ],
  EpisodeAction.share: ['Share'],
  EpisodeAction.exportAudio: ['Export audio file'],
};

/// The queue-screen-only move actions, appended after the configured episode
/// actions so they always sort last on queue rows. Not user-configurable.
const queueMoveRotorLabels = <String>[
  'Move to top',
  'Move up',
  'Move down',
  'Move to bottom',
];

/// The ordered rotor labels for [order]: each action's variant labels (adjacent)
/// in the user's configured order, then the queue move block. iOS orders the
/// Actions rotor by first-seen id, so seeding in this order makes the rotor
/// follow the user's configuration. See [seedEpisodeActionRotorOrder].
List<String> episodeActionRotorLabels(List<EpisodeAction> order) {
  return [
    for (final action in order) ...?episodeActionVariantLabels[action],
    ...queueMoveRotorLabels,
  ];
}

/// Seeds the VoiceOver Actions rotor order from the user's configured [order].
/// MUST be called once in main() before runApp and before any episode row
/// builds, or the rotor falls back to arbitrary first-seen order. The id cache
/// cannot be reset in a release build, so a configuration change takes effect on
/// the next app launch. See [episodeActionRotorLabels].
void seedEpisodeActionRotorOrder(List<EpisodeAction> order) {
  for (final label in episodeActionRotorLabels(order)) {
    CustomSemanticsAction.getIdentifier(CustomSemanticsAction(label: label));
  }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `flutter test test/core/episode_action_builder_test.dart`
Expected: PASS (all tests in the file).

- [ ] **Step 5: Commit**

```bash
git add lib/core/episode_action_builder.dart test/core/episode_action_builder_test.dart
git commit -m "feat: seed VoiceOver rotor from the configured episode-action order"
```

---

### Task 2: Seed the rotor from the saved order at startup

**Files:**
- Modify: `lib/main.dart` (remove early seed at lines ~105–108; add guarded seed after the DB-open block, before line ~171; add two imports near lines 34–35)

- [ ] **Step 1: Remove the hardcoded early seed**

Delete these lines (~105–108):

```dart
  // Seed the VoiceOver Actions rotor order before any episode row builds — the
  // rotor is ordered by first-seen action id, not our list order, so this must
  // run first to keep the rotor consistent. See seedEpisodeActionRotorOrder.
  seedEpisodeActionRotorOrder();
```

- [ ] **Step 2: Add imports**

After the existing settings import (`import 'features/settings/presentation/providers/settings_providers.dart';`, line ~35) add:

```dart
import 'features/settings/data/quick_action_repository_impl.dart';
import 'features/settings/domain/quick_action_definition.dart';
```

- [ ] **Step 3: Add the guarded seed after the DB is known-good**

Immediately after the `try { ... } catch { ... return; }` block that reads `crashReportingEnabled`/`analyticsEnabled` (after line ~169, before `if (crashReportingEnabled && _sentryDsn.isNotEmpty)`), insert:

```dart
  // Seed the VoiceOver Actions rotor from the user's saved order, now that the
  // DB is known-good. iOS orders the rotor by first-seen action id, so this must
  // run before runApp / any episode row builds. A failure here is non-fatal —
  // fall back to the default order so startup still proceeds.
  try {
    final savedOrder = await QuickActionRepositoryImpl(
      database: db,
    ).watchEpisodeActions().first;
    seedEpisodeActionRotorOrder(savedOrder);
  } catch (error, stackTrace) {
    _log.warning(
      'Failed to seed rotor order from saved config',
      error,
      stackTrace,
    );
    await Sentry.captureException(error, stackTrace: stackTrace);
    seedEpisodeActionRotorOrder(defaultEpisodeActions);
  }
```

- [ ] **Step 4: Verify it compiles and analyzes clean**

Run: `flutter analyze lib/main.dart lib/core/episode_action_builder.dart`
Expected: No issues found.

- [ ] **Step 5: Commit**

```bash
git add lib/main.dart
git commit -m "feat: seed rotor from saved episode-action order at startup (guarded)"
```

---

### Task 3: Speak a rotor heads-up on episode save

**Files:**
- Modify: `lib/features/settings/presentation/screens/quick_action_configurator_screen.dart` (the success tail of `_save()`, lines ~218–221)

- [ ] **Step 1: Update the success announcement**

Replace:

```dart
    // Pop first, then announce past the dismiss + focus settle so iOS VoiceOver
    // doesn't discard the announcement mid focus-transition.
    if (mounted) Navigator.of(context).pop();
    announceAfterDismiss(view, 'Quick actions saved');
```

with:

```dart
    // Pop first, then announce past the dismiss + focus settle so iOS VoiceOver
    // doesn't discard the announcement mid focus-transition. The menu order and
    // default tap update instantly; only the rotor waits for a relaunch (the
    // action-id cache can't be reset in a release build), so say so on episode
    // saves.
    if (mounted) Navigator.of(context).pop();
    announceAfterDismiss(
      view,
      _isEpisode
          ? 'Quick actions saved. Reopen Earshot to update the rotor order.'
          : 'Quick actions saved',
    );
```

- [ ] **Step 2: Verify analyze + existing settings tests pass**

Run: `flutter analyze lib/features/settings && flutter test test/features/settings/`
Expected: No issues; all settings tests pass.

- [ ] **Step 3: Commit**

```bash
git add lib/features/settings/presentation/screens/quick_action_configurator_screen.dart
git commit -m "feat: tell the user the rotor order applies after relaunch on save"
```

---

### Task 4: Verify per-screen consistency, accessibility, and full green

**Files:** none changed unless the audit finds an outlier.

- [ ] **Step 1: Audit that every list surface builds from the configured order**

Run: `grep -rn "buildEpisodeActions\|orderEpisodeActionItems\|episodeActionsProvider\|defaultEpisodeActions" lib/features/*/presentation/screens`
Expected: inbox, downloads, podcast detail, queue use `buildEpisodeActions` with `order` from `ref.watch(episodeActionsProvider).asData?.value ?? defaultEpisodeActions`; search detail uses `orderEpisodeActionItems` with the same source. The Now Playing player (`player_screen.dart`) is intentionally a curated set; its shared labels ("Mark as played", "Export audio file") align via shared rotor ids and need no change. If any list screen passes a different order, change it to `ref.watch(episodeActionsProvider).asData?.value ?? defaultEpisodeActions`.

- [ ] **Step 2: Full test suite**

Run: `flutter test`
Expected: All tests pass (including the rotor tests from Task 1 and the persistence regression tests).

- [ ] **Step 3: Analyze the whole project**

Run: `flutter analyze lib test`
Expected: No issues found.

- [ ] **Step 4: Accessibility review**

Dispatch the `mobile-accessibility` agent on `quick_action_configurator_screen.dart` (the save announcement) and confirm the rotor-seed change introduces no semantics regressions. Address any Error/Warning findings; Tips optional.

- [ ] **Step 5: Update CHANGELOG and commit**

Add to `CHANGELOG.md` under `[Unreleased]` → `### Changed`:

```markdown
- Quick Actions: your configured episode-action order now drives the VoiceOver
  Actions rotor too, not just the menu and default double-tap. Reorder your
  actions in Settings and the rotor follows the same order (the menu and default
  update instantly; the rotor applies the next time you open Earshot, which the
  app announces when you save).
```

```bash
git add CHANGELOG.md
git commit -m "docs: changelog for configurable VoiceOver rotor order"
```

---

## Notes for the implementer
- TDD: Task 1 is test-first. Tasks 2–4 are wiring/verification where a focused unit test isn't practical (startup + DB + iOS rotor), so they lean on `flutter analyze`, the existing suites, and the accessibility agent.
- Do NOT add a DB migration or change the schema. The dedup save (commit 77f6454) already self-heals legacy data.
- Do NOT call `exit(0)` / attempt a self-relaunch. The rotor-on-next-launch behavior is intentional and announced.
- Keep `episodeActionVariantLabels` in sync with `_buildItem`'s labels; the Task 1 completeness test guards this.
