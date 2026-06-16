# Per-Podcast Inbox Limits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users cap how many episodes of a podcast stay in the inbox (a global default plus per-podcast override) and auto-remove inbox episodes older than a per-podcast age limit, all without surprising existing users on upgrade.

**Architecture:** Two new nullable columns on `podcasts` plus one global app setting. A new `InboxLimitService` performs set-based `inboxDismissed` trimming, run on launch/resume, after refresh, and on settings change, with a hard early-out when no limits are set. Removal is silent and one-directional (only ever sets `inboxDismissed=true`).

**Tech Stack:** Flutter/Dart, Riverpod, drift (SQLite), mocktail + flutter_test.

**Spec:** `docs/superpowers/specs/2026-06-16-inbox-limits-design.md`

**Branch:** `feat/inbox-limits` (already created).

---

## File structure

- `lib/data/db/tables/podcasts.dart` — add two columns.
- `lib/data/db/app_database.dart` — schemaVersion 14→15, migration step.
- `lib/features/settings/data/app_settings_repository.dart` — global default getter/setter.
- `lib/features/subscriptions/data/podcast_repository.dart` (+ `_impl.dart`) — per-podcast setters; effective-cap helper; include/exclude restore re-runs trim.
- `lib/features/subscriptions/domain/podcast.dart` — two new fields + row mapping.
- `lib/features/downloads/data/inbox_limit_service.dart` — NEW, the enforcement service.
- `lib/features/downloads/presentation/providers/...` / `core_providers` — provider for the service.
- `lib/core/presentation/main_shell.dart` — run service on launch/resume.
- `lib/features/settings/presentation/screens/inbox_settings_screen.dart` (+ providers) — global default UI.
- `lib/features/subscriptions/presentation/screens/podcast_settings_screen.dart` (+ providers) — per-podcast UI.
- Tests under `test/data/db/`, `test/features/subscriptions/`, `test/features/downloads/`, `test/features/settings/`.

---

## Task 0: `inboxDismissed` writer/reader audit (REQUIRED FIRST)

No code. Produce a short written audit and lock the restore decision before building the service. This is the spec's required first task.

**Files:** none (append findings to the PR description / a comment).

- [ ] **Step 1: Enumerate every writer of `inboxDismissed`.**

Run:
```bash
grep -rn "inboxDismissed\|inbox_dismissed" lib/ | grep -v ".g.dart"
```
For each hit, note whether it reads or writes, and the direction (true/false). Expected writers to confirm: `_upsertEpisodes` (backlog true), `clearInbox` (true), `_setEpisodesDismissed`/`_setEpisodeDismissed` (true/false), `setInboxIncluded`/`setInboxExcluded` (via the above, opt-in mode), `dismissFromInbox`, #298 resurrection (false). Readers: inbox stream provider (`inbox_screen.dart`), badge count (`main_shell.dart`).

- [ ] **Step 2: Confirm the one risk and lock the decision.**

The only writer that clears the flag for a *podcast's whole set* is the include/exclude restore (`setInboxIncluded`/`setInboxExcluded` → `_setEpisodeDismissed(dismissed: !included)`, opt-in mode only). Decision (from spec): after that restore clears flags, re-run the inbox-limit trim for that podcast so caps aren't silently reversed. This is implemented in Task 8.

- [ ] **Step 3: Decide whether a dismissal-reason column is needed.**

If the audit finds a reader/writer that would misbehave because it can't tell *why* an episode was dismissed (beyond the include/exclude case already handled), STOP and add a `dismissReason` column in Task 1 instead of proceeding. Expected outcome with current code: not needed — the include/exclude re-trim covers it. Write one sentence confirming this in the PR.

---

## Task 1: Schema — two per-podcast columns + migration (v15)

**Files:**
- Modify: `lib/data/db/tables/podcasts.dart`
- Modify: `lib/data/db/app_database.dart`
- Test: `test/data/db/migration_test.dart`

- [ ] **Step 1: Add the columns to the table.**

In `lib/data/db/tables/podcasts.dart`, after `queueAgeLimitDays` (line ~19):
```dart
  IntColumn get inboxMaxEpisodes => integer().nullable()();
  IntColumn get inboxAgeLimitHours => integer().nullable()();
```

- [ ] **Step 2: Regenerate drift code.**

Run: `dart run build_runner build --delete-conflicting-outputs`
Expected: `app_database.g.dart` updated, no errors.

- [ ] **Step 3: Bump schemaVersion and add migration.**

In `lib/data/db/app_database.dart`, change `int get schemaVersion => 14;` to `=> 15;`. Then in `onUpgrade`, after the `if (from < 14)` block:
```dart
      if (from < 15) {
        await m.addColumn(podcasts, podcasts.inboxMaxEpisodes);
        await m.addColumn(podcasts, podcasts.inboxAgeLimitHours);
      }
```

- [ ] **Step 4: Write the migration test.**

In `test/data/db/migration_test.dart`, add a new group mirroring the existing v14 group:
```dart
  group('schema migration to version 15 adds inbox-limit columns', () {
    late Directory tempDir;
    late File dbFile;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('earshot_migration_v15');
      dbFile = File('${tempDir.path}/earshot.db');
    });
    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('onUpgrade(14, 15) adds columns and keeps data', () async {
      final seedDb = AppDatabase.forTesting(NativeDatabase(dbFile));
      final podcastId = await seedDb.into(seedDb.podcasts).insert(
            PodcastsCompanion.insert(
              rssUrl: 'https://example.com/a.xml',
              title: 'A',
            ),
          );
      // Drop the two columns and roll user_version back to 14.
      await seedDb
          .customStatement('ALTER TABLE podcasts DROP COLUMN inbox_max_episodes');
      await seedDb.customStatement(
          'ALTER TABLE podcasts DROP COLUMN inbox_age_limit_hours');
      await seedDb.customStatement('PRAGMA user_version = 14');
      await seedDb.close();

      final upgraded = AppDatabase.forTesting(NativeDatabase(dbFile));
      final row = await (upgraded.select(upgraded.podcasts)
            ..where((p) => p.id.equals(podcastId)))
          .getSingle();
      expect(row.inboxMaxEpisodes, isNull);
      expect(row.inboxAgeLimitHours, isNull);
      await upgraded.close();
    });
  });
```

- [ ] **Step 5: Run the migration test.**

Run: `flutter test test/data/db/migration_test.dart`
Expected: PASS (all groups).

- [ ] **Step 6: Commit.**

```bash
git add lib/data/db/ test/data/db/migration_test.dart
git commit -m "feat: add inboxMaxEpisodes/inboxAgeLimitHours columns (schema v15)"
```

---

## Task 2: Global default setting (`inbox_default_max_episodes`)

**Files:**
- Modify: `lib/features/settings/data/app_settings_repository.dart`
- Test: `test/features/settings/app_settings_repository_test.dart` (create if absent)

Semantics: `null` = No limit. Stored as the string `'null'` for No limit (matching `setDownloadRetentionDays`).

- [ ] **Step 1: Add interface methods.**

In the abstract `AppSettingsRepository` (near `getDownloadRetentionDays`):
```dart
  Future<int?> getInboxDefaultMaxEpisodes();
  Future<void> setInboxDefaultMaxEpisodes(int? max);
```

- [ ] **Step 2: Add the key constant and implementation.**

Add constant near `_keyDownloadRetentionDays`:
```dart
  static const _keyInboxDefaultMaxEpisodes = 'inbox_default_max_episodes';
```
Add impl (mirror `getDownloadRetentionDays`/`setDownloadRetentionDays`; default null = No limit):
```dart
  @override
  Future<int?> getInboxDefaultMaxEpisodes() async {
    final row = await (_db.select(_db.appSettings)
          ..where((s) => s.key.equals(_keyInboxDefaultMaxEpisodes)))
        .getSingleOrNull();
    if (row == null || row.value == 'null') return null;
    return int.tryParse(row.value);
  }

  @override
  Future<void> setInboxDefaultMaxEpisodes(int? max) =>
      _set(_keyInboxDefaultMaxEpisodes, max?.toString() ?? 'null');
```

- [ ] **Step 3: Write the test.**

```dart
import 'package:drift/native.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/features/settings/data/app_settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late AppSettingsRepositoryImpl repo;
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = AppSettingsRepositoryImpl(database: db);
  });
  tearDown(() => db.close());

  test('inbox default max episodes defaults to null (No limit)', () async {
    expect(await repo.getInboxDefaultMaxEpisodes(), isNull);
  });
  test('round-trips a finite value', () async {
    await repo.setInboxDefaultMaxEpisodes(3);
    expect(await repo.getInboxDefaultMaxEpisodes(), 3);
  });
  test('setting back to null means No limit', () async {
    await repo.setInboxDefaultMaxEpisodes(3);
    await repo.setInboxDefaultMaxEpisodes(null);
    expect(await repo.getInboxDefaultMaxEpisodes(), isNull);
  });
}
```

- [ ] **Step 4: Run.**

Run: `flutter test test/features/settings/app_settings_repository_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add lib/features/settings/data/app_settings_repository.dart test/features/settings/app_settings_repository_test.dart
git commit -m "feat: global inbox default max episodes setting (default No limit)"
```

---

## Task 3: Per-podcast setters + domain fields

**Files:**
- Modify: `lib/features/subscriptions/domain/podcast.dart`
- Modify: `lib/features/subscriptions/data/podcast_repository.dart`
- Modify: `lib/features/subscriptions/data/podcast_repository_impl.dart`
- Test: `test/features/subscriptions/data/podcast_repository_test.dart`

- [ ] **Step 1: Add domain fields.**

In `podcast.dart`, add `final int? inboxMaxEpisodes;` and `final int? inboxAgeLimitHours;` to the class, constructor, and (if present) `copyWith`/equality. In `_podcastFromRow` (in `podcast_repository_impl.dart`, near the `queueAgeLimitDays` mapping) add `inboxMaxEpisodes: row.inboxMaxEpisodes, inboxAgeLimitHours: row.inboxAgeLimitHours,`.

- [ ] **Step 2: Add interface methods** in `podcast_repository.dart`:
```dart
  Future<void> setInboxMaxEpisodes(int podcastId, int? max);
  Future<void> setInboxAgeLimitHours(int podcastId, int? hours);
```

- [ ] **Step 3: Implement** in `podcast_repository_impl.dart` (near `setInboxIncluded`):
```dart
  @override
  Future<void> setInboxMaxEpisodes(int podcastId, int? max) =>
      (_db.update(_db.podcasts)..where((p) => p.id.equals(podcastId)))
          .write(PodcastsCompanion(inboxMaxEpisodes: Value(max)));

  @override
  Future<void> setInboxAgeLimitHours(int podcastId, int? hours) =>
      (_db.update(_db.podcasts)..where((p) => p.id.equals(podcastId)))
          .write(PodcastsCompanion(inboxAgeLimitHours: Value(hours)));
```

- [ ] **Step 4: Test the setters + mapping.**

Add to `podcast_repository_test.dart`:
```dart
  group('per-podcast inbox limit setters', () {
    test('round-trip inboxMaxEpisodes and inboxAgeLimitHours', () async {
      stubFeed();
      final p = await repo.subscribe(_rssUrl);
      await repo.setInboxMaxEpisodes(p.id, 1);
      await repo.setInboxAgeLimitHours(p.id, 24);
      final row = await repo.watchSubscriptions().first;
      final updated = row.firstWhere((e) => e.id == p.id);
      expect(updated.inboxMaxEpisodes, 1);
      expect(updated.inboxAgeLimitHours, 24);
    });
  });
```

- [ ] **Step 5: Run.** `flutter test test/features/subscriptions/data/podcast_repository_test.dart` → PASS.

- [ ] **Step 6: Commit.**
```bash
git add lib/features/subscriptions/ test/features/subscriptions/data/podcast_repository_test.dart
git commit -m "feat: per-podcast inboxMaxEpisodes/inboxAgeLimitHours setters + domain fields"
```

---

## Task 4: `InboxLimitService` (the enforcement core)

**Files:**
- Create: `lib/features/downloads/data/inbox_limit_service.dart`
- Test: `test/features/downloads/inbox_limit_service_test.dart`

Effective cap = per-podcast `inboxMaxEpisodes ?? globalDefault`. `null`/absent = No limit. Trim-eligible = `status=newEpisode AND inboxDismissed=false AND positionSeconds=0`. Inbox-included only.

- [ ] **Step 1: Write failing tests for the service.**

```dart
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/data/db/enums.dart';
import 'package:earshot/features/downloads/data/inbox_limit_service.dart';
import 'package:earshot/features/settings/data/app_settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late InboxLimitService service;
  final now = DateTime.now().toUtc();

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    service = InboxLimitService(
      database: db,
      settings: AppSettingsRepositoryImpl(database: db),
    );
  });
  tearDown(() => db.close());

  Future<int> newPodcast({int? max, int? ageHours, bool excluded = false}) =>
      db.into(db.podcasts).insert(PodcastsCompanion.insert(
            rssUrl: 'https://example.com/${DateTime.now().microsecondsSinceEpoch}.xml',
            title: 'P',
            inboxMaxEpisodes: Value(max),
            inboxAgeLimitHours: Value(ageHours),
            inboxExcluded: Value(excluded),
          ));

  Future<int> addEpisode(
    int podcastId, {
    required String guid,
    required DateTime pubDate,
    EpisodeStatus status = EpisodeStatus.newEpisode,
    bool dismissed = false,
    int position = 0,
  }) =>
      db.into(db.episodes).insert(EpisodesCompanion.insert(
            podcastId: podcastId,
            guid: guid,
            title: guid,
            audioUrl: 'https://example.com/$guid.mp3',
            pubDate: Value(pubDate),
            status: Value(status),
            inboxDismissed: Value(dismissed),
            positionSeconds: Value(position),
          ));

  Future<bool> dismissed(int id) async =>
      (await (db.select(db.episodes)..where((e) => e.id.equals(id))).getSingle())
          .inboxDismissed;

  test('count cap keeps newest N, dismisses the rest', () async {
    final p = await newPodcast(max: 1);
    final newest = await addEpisode(p, guid: 'a', pubDate: now);
    final older = await addEpisode(p, guid: 'b', pubDate: now.subtract(const Duration(days: 1)));
    await service.applyInboxLimits();
    expect(await dismissed(newest), isFalse);
    expect(await dismissed(older), isTrue);
  });

  test('No limit (no per-podcast, no global) dismisses nothing', () async {
    final p = await newPodcast();
    final a = await addEpisode(p, guid: 'a', pubDate: now);
    final b = await addEpisode(p, guid: 'b', pubDate: now.subtract(const Duration(days: 1)));
    await service.applyInboxLimits();
    expect(await dismissed(a), isFalse);
    expect(await dismissed(b), isFalse);
  });

  test('global default applies when no per-podcast override', () async {
    await AppSettingsRepositoryImpl(database: db).setInboxDefaultMaxEpisodes(1);
    final p = await newPodcast();
    final newest = await addEpisode(p, guid: 'a', pubDate: now);
    final older = await addEpisode(p, guid: 'b', pubDate: now.subtract(const Duration(days: 1)));
    await service.applyInboxLimits();
    expect(await dismissed(newest), isFalse);
    expect(await dismissed(older), isTrue);
  });

  test('per-podcast override beats global default', () async {
    await AppSettingsRepositoryImpl(database: db).setInboxDefaultMaxEpisodes(1);
    final p = await newPodcast(max: 5); // override: keep 5
    for (var i = 0; i < 3; i++) {
      await addEpisode(p, guid: 'e$i', pubDate: now.subtract(Duration(days: i)));
    }
    await service.applyInboxLimits();
    final remaining = await (db.select(db.episodes)
          ..where((e) => e.inboxDismissed.equals(false)))
        .get();
    expect(remaining, hasLength(3));
  });

  test('count cap ignores played, queued, and started episodes', () async {
    final p = await newPodcast(max: 1);
    await addEpisode(p, guid: 'keep', pubDate: now);
    final played = await addEpisode(p, guid: 'played', pubDate: now.subtract(const Duration(days: 1)), status: EpisodeStatus.played);
    final queued = await addEpisode(p, guid: 'queued', pubDate: now.subtract(const Duration(days: 2)), status: EpisodeStatus.inQueue);
    final started = await addEpisode(p, guid: 'started', pubDate: now.subtract(const Duration(days: 3)), position: 120);
    await service.applyInboxLimits();
    expect(await dismissed(played), isFalse);
    expect(await dismissed(queued), isFalse);
    expect(await dismissed(started), isFalse);
  });

  test('age limit dismisses episodes older than the cutoff', () async {
    final p = await newPodcast(ageHours: 24);
    final fresh = await addEpisode(p, guid: 'fresh', pubDate: now.subtract(const Duration(hours: 1)));
    final stale = await addEpisode(p, guid: 'stale', pubDate: now.subtract(const Duration(hours: 48)));
    await service.applyInboxLimits();
    expect(await dismissed(fresh), isFalse);
    expect(await dismissed(stale), isTrue);
  });

  test('age limit does not dismiss a started episode past the cutoff', () async {
    final p = await newPodcast(ageHours: 24);
    final startedStale = await addEpisode(p, guid: 's', pubDate: now.subtract(const Duration(hours: 48)), position: 90);
    await service.applyInboxLimits();
    expect(await dismissed(startedStale), isFalse);
  });

  test('inbox-excluded podcast is untouched', () async {
    final p = await newPodcast(max: 1, excluded: true);
    final older = await addEpisode(p, guid: 'b', pubDate: now.subtract(const Duration(days: 1)));
    await addEpisode(p, guid: 'a', pubDate: now);
    await service.applyInboxLimits();
    expect(await dismissed(older), isFalse);
  });

  test('does not un-dismiss already-dismissed episodes (one-directional)', () async {
    final p = await newPodcast(max: 5);
    final wasDismissed = await addEpisode(p, guid: 'd', pubDate: now, dismissed: true);
    await service.applyInboxLimits();
    expect(await dismissed(wasDismissed), isTrue);
  });
}
```

- [ ] **Step 2: Run to confirm failure.**

Run: `flutter test test/features/downloads/inbox_limit_service_test.dart`
Expected: FAIL (InboxLimitService not defined).

- [ ] **Step 3: Implement the service.**

Create `lib/features/downloads/data/inbox_limit_service.dart`:
```dart
import 'package:drift/drift.dart';
import 'package:logging/logging.dart';

import '../../../data/db/app_database.dart';
import '../../../data/db/enums.dart';
import '../../settings/data/app_settings_repository.dart';

final _log = Logger('InboxLimitService');

class InboxLimitService {
  InboxLimitService({
    required AppDatabase database,
    required AppSettingsRepository settings,
  })  : _db = database,
        _settings = settings;

  final AppDatabase _db;
  final AppSettingsRepository _settings;

  /// Applies per-podcast inbox count caps and age limits by setting
  /// inboxDismissed=true. One-directional: never clears the flag.
  Future<void> applyInboxLimits() async {
    final globalDefault = await _settings.getInboxDefaultMaxEpisodes();

    // Early-out: if no global default and no podcast has any limit, do nothing.
    // Protects the #278 cold-launch win for the common (no-limits) case.
    final anyPerPodcast = await (_db.selectOnly(_db.podcasts)
          ..addColumns([_db.podcasts.id])
          ..where(_db.podcasts.inboxMaxEpisodes.isNotNull() |
              _db.podcasts.inboxAgeLimitHours.isNotNull())
          ..limit(1))
        .get();
    if (globalDefault == null && anyPerPodcast.isEmpty) return;

    final podcasts = await _db.select(_db.podcasts).get();
    final now = DateTime.now().toUtc();
    for (final podcast in podcasts) {
      if (await _isExcluded(podcast)) continue;
      await applyForPodcast(podcast.id, now: now, globalDefault: globalDefault);
    }
  }

  /// Applies limits for a single podcast (used by the bulk pass and after an
  /// include/exclude restore).
  Future<void> applyForPodcast(
    int podcastId, {
    DateTime? now,
    int? globalDefault,
  }) async {
    final nowUtc = now ?? DateTime.now().toUtc();
    final podcast = await (_db.select(_db.podcasts)
          ..where((p) => p.id.equals(podcastId)))
        .getSingleOrNull();
    if (podcast == null || await _isExcluded(podcast)) return;

    final globalDef =
        globalDefault ?? await _settings.getInboxDefaultMaxEpisodes();

    // Age pass.
    final ageHours = podcast.inboxAgeLimitHours;
    if (ageHours != null) {
      final cutoff = nowUtc.subtract(Duration(hours: ageHours));
      await (_db.update(_db.episodes)
            ..where((e) =>
                e.podcastId.equals(podcastId) &
                e.status.equals(EpisodeStatus.newEpisode.name) &
                e.inboxDismissed.equals(false) &
                e.positionSeconds.equals(0) &
                e.pubDate.isSmallerThanValue(cutoff)))
          .write(const EpisodesCompanion(inboxDismissed: Value(true)));
    }

    // Count pass.
    final cap = podcast.inboxMaxEpisodes ?? globalDef;
    if (cap != null) {
      final keepIds = (await (_db.selectOnly(_db.episodes)
                ..addColumns([_db.episodes.id])
                ..where(_db.episodes.podcastId.equals(podcastId) &
                    _db.episodes.status.equals(EpisodeStatus.newEpisode.name) &
                    _db.episodes.inboxDismissed.equals(false) &
                    _db.episodes.positionSeconds.equals(0))
                ..orderBy([
                  OrderingTerm.desc(_db.episodes.pubDate),
                  OrderingTerm.desc(_db.episodes.id),
                ])
                ..limit(cap))
              .get())
          .map((r) => r.read(_db.episodes.id)!)
          .toList();

      await (_db.update(_db.episodes)
            ..where((e) =>
                e.podcastId.equals(podcastId) &
                e.status.equals(EpisodeStatus.newEpisode.name) &
                e.inboxDismissed.equals(false) &
                e.positionSeconds.equals(0) &
                e.id.isNotIn(keepIds)))
          .write(const EpisodesCompanion(inboxDismissed: Value(true)));
    }
    _log.fine('Applied inbox limits for podcast $podcastId');
  }

  Future<bool> _isExcluded(PodcastRow podcast) async {
    final optInOnly = await _settings.isInboxOptInOnly();
    return optInOnly ? !podcast.inboxIncluded : podcast.inboxExcluded;
  }
}
```

Note: `cap == 0` would dismiss everything; the UI never offers 0 (presets start at 1), and `null` = No limit, so 0 is not a reachable value.

- [ ] **Step 4: Run tests to verify they pass.**

Run: `flutter test test/features/downloads/inbox_limit_service_test.dart`
Expected: PASS (all cases).

- [ ] **Step 5: Commit.**
```bash
git add lib/features/downloads/data/inbox_limit_service.dart test/features/downloads/inbox_limit_service_test.dart
git commit -m "feat: InboxLimitService enforces per-podcast count cap + age limit"
```

---

## Task 5: Provider + wiring (refresh, launch/resume, subscribe seed)

**Files:**
- Modify: `lib/core/providers/core_providers.dart` (or the providers file where `queueExpirationServiceProvider` lives — grep for it)
- Modify: `lib/features/subscriptions/data/podcast_repository_impl.dart`
- Modify: `lib/core/presentation/main_shell.dart`
- Test: `test/features/subscriptions/data/podcast_repository_test.dart`

- [ ] **Step 1: Add a provider for the service.**

Find where `queueExpirationServiceProvider` is declared (`grep -rn "queueExpirationServiceProvider =" lib/`) and add alongside it:
```dart
final inboxLimitServiceProvider = Provider<InboxLimitService>(
  (ref) => InboxLimitService(
    database: ref.watch(appDatabaseProvider),
    settings: AppSettingsRepositoryImpl(database: ref.watch(appDatabaseProvider)),
  ),
);
```
(Match the import + construction style of the queue expiration provider.)

- [ ] **Step 2: Inject InboxLimitService into PodcastRepositoryImpl and run trim last in refreshFeed.**

`PodcastRepositoryImpl` already constructs `AppSettingsRepositoryImpl` as `_settings`. Add a private method and call it at the END of `refreshFeed` (after the mark-advance block, line ~283), so the trim sees final post-resurrection state:
```dart
    // Inbox limits run last so they see the final inbox state for this feed
    // (after #298 resurrection and the mark advance).
    await InboxLimitService(database: _db, settings: _settings)
        .applyForPodcast(podcastId, now: nowUtc);
```
Add the import for `inbox_limit_service.dart`.

- [ ] **Step 3: Write the ordering test (republished-but-over-cap).**

Add to `podcast_repository_test.dart` (in the resurrection group or a new one):
```dart
    test('a republished episode beyond the count cap is re-trimmed in the same '
        'refresh', () async {
      // cap = 1; an old auto-dismissed-backlog episode gets republished forward
      // (#298 would resurface it), but a newer episode exists, so the cap must
      // re-trim the republished one.
      final podcastId = await db.into(db.podcasts).insert(
            PodcastsCompanion.insert(
              rssUrl: _rssUrl,
              title: 'P',
              lastSeenPubDate: Value(now.subtract(const Duration(days: 10))),
              inboxMaxEpisodes: const Value(1),
            ),
          );
      // Newest current inbox episode (keeps the single slot).
      await db.into(db.episodes).insert(EpisodesCompanion.insert(
            podcastId: podcastId, guid: 'newest', title: 'newest',
            audioUrl: 'https://example.com/n.mp3',
            pubDate: Value(now), status: const Value(EpisodeStatus.newEpisode)));
      // Auto-dismissed backlog that the feed now republishes forward.
      final rerunId = await db.into(db.episodes).insert(EpisodesCompanion.insert(
            podcastId: podcastId, guid: 'rerun', title: 'rerun',
            audioUrl: 'https://example.com/r.mp3',
            pubDate: Value(now.subtract(const Duration(days: 20))),
            status: const Value(EpisodeStatus.played),
            inboxDismissed: const Value(true)));
      stubFeed(episodes: [
        ParsedEpisode(guid: 'rerun', title: 'rerun',
            audioUrl: 'https://example.com/r.mp3',
            pubDate: now.subtract(const Duration(days: 2))), // newer than mark
      ]);
      await repo.refreshFeed(podcastId);
      final rerun = await (db.select(db.episodes)
            ..where((e) => e.id.equals(rerunId))).getSingle();
      // #298 resurrected it (newEpisode), but it's older than 'newest' and cap=1,
      // so the trim re-dismisses it.
      expect(rerun.status, EpisodeStatus.newEpisode);
      expect(rerun.inboxDismissed, isTrue);
    });
```

- [ ] **Step 4: Run.** `flutter test test/features/subscriptions/data/podcast_repository_test.dart` → PASS.

- [ ] **Step 5: Run the service on launch/resume in main_shell.**

In `lib/core/presentation/main_shell.dart`, in the post-frame callback next to `ref.read(queueExpirationServiceProvider).runExpiration();`:
```dart
      unawaited(ref.read(inboxLimitServiceProvider).applyInboxLimits());
```
Add the provider import. (The early-out keeps this cheap when no limits are set.)

- [ ] **Step 6: Subscribe seeding honors a finite effective cap.**

In `podcast_repository_impl.dart`, `subscribe(...)` calls `_upsertEpisodes(..., inboxLimit: 3, ...)`. Replace the literal `3` with the effective cap when finite:
```dart
    final globalDefault = await _settings.getInboxDefaultMaxEpisodes();
    final seed = globalDefault ?? 3; // No limit -> keep current anti-flood of 3
    await _upsertEpisodes(podcastId, feed.episodes,
        preserveUserData: false, inboxLimit: seed);
```
(Find the exact existing `_upsertEpisodes` call in `subscribe`; keep its other args.)

- [ ] **Step 7: Add a subscribe-seed test.**
```dart
    test('subscribe seeds only the global default count when set', () async {
      await AppSettingsRepositoryImpl(database: db).setInboxDefaultMaxEpisodes(1);
      stubFeed(episodes: [
        ParsedEpisode(guid: 'a', title: 'a', audioUrl: 'https://example.com/a.mp3', pubDate: DateTime(2024, 3)),
        ParsedEpisode(guid: 'b', title: 'b', audioUrl: 'https://example.com/b.mp3', pubDate: DateTime(2024, 2)),
        ParsedEpisode(guid: 'c', title: 'c', audioUrl: 'https://example.com/c.mp3', pubDate: DateTime(2024, 1)),
      ]);
      final p = await repo.subscribe(_rssUrl);
      final inbox = await (db.select(db.episodes)
            ..where((e) => e.podcastId.equals(p.id) &
                e.status.equals(EpisodeStatus.newEpisode.name))).get();
      expect(inbox, hasLength(1));
    });
```

- [ ] **Step 8: Run full subscriptions + analyze.**

Run: `flutter test test/features/subscriptions/ && flutter analyze lib/ test/`
Expected: PASS, no issues.

- [ ] **Step 9: Commit.**
```bash
git add lib/ test/features/subscriptions/data/podcast_repository_test.dart
git commit -m "feat: run inbox-limit trim after refresh + on launch; seed subscribe by effective cap"
```

---

## Task 6: Include/exclude restore re-runs the trim (audit resolution)

**Files:**
- Modify: `lib/features/subscriptions/data/podcast_repository_impl.dart`
- Test: `test/features/subscriptions/data/podcast_repository_test.dart`

- [ ] **Step 1: Re-apply limits after a restore.**

In `setInboxIncluded` and `setInboxExcluded`, after the existing `_setEpisodeDismissed(...)` restore call (the `dismissed: !included` / include path that clears the flag), re-run the per-podcast trim so caps aren't reversed:
```dart
    await InboxLimitService(database: _db, settings: _settings)
        .applyForPodcast(podcastId);
```
Place it inside the include/restore branch (where flags can be cleared).

- [ ] **Step 2: Test.**
```dart
    test('re-including a capped podcast does not leave more than the cap', () async {
      stubFeed();
      final p = await repo.subscribe(_rssUrl);
      await repo.setInboxMaxEpisodes(p.id, 1);
      // two inbox episodes
      await db.into(db.episodes).insert(EpisodesCompanion.insert(
          podcastId: p.id, guid: 'a', title: 'a', audioUrl: 'x',
          pubDate: Value(DateTime(2024, 2)), status: const Value(EpisodeStatus.newEpisode)));
      await db.into(db.episodes).insert(EpisodesCompanion.insert(
          podcastId: p.id, guid: 'b', title: 'b', audioUrl: 'y',
          pubDate: Value(DateTime(2024, 1)), status: const Value(EpisodeStatus.newEpisode)));
      await repo.setInboxIncluded(p.id, included: true);
      final visible = await (db.select(db.episodes)
            ..where((e) => e.podcastId.equals(p.id) &
                e.inboxDismissed.equals(false) &
                e.status.equals(EpisodeStatus.newEpisode.name))).get();
      expect(visible.length, lessThanOrEqualTo(1));
    });
```
(If `setInboxIncluded`'s restore only fires in opt-in mode, set that mode in the test via `AppSettingsRepositoryImpl(database: db).setInboxOptInOnly(true)` first — confirm the exact setting name by grep.)

- [ ] **Step 3: Run.** → PASS. **Step 4: Commit.**
```bash
git add lib/features/subscriptions/data/podcast_repository_impl.dart test/features/subscriptions/data/podcast_repository_test.dart
git commit -m "fix: re-apply inbox limits after include/exclude restore so caps aren't reversed"
```

---

## Task 7: Global default UI (Inbox settings)

**Files:**
- Modify: `lib/features/settings/presentation/screens/inbox_settings_screen.dart`
- Modify: `lib/features/settings/presentation/providers/settings_providers.dart`
- Test: `test/features/settings/inbox_settings_screen_test.dart` (create)

- [ ] **Step 1: Add an AsyncNotifier provider** for the global default, mirroring an existing nullable-int settings notifier in `settings_providers.dart` (grep for `_RetentionSettingNotifier` and copy the pattern) exposing read + `set(int?)` backed by `getInboxDefaultMaxEpisodes`/`setInboxDefaultMaxEpisodes`. On set, also trigger a trim: `ref.read(inboxLimitServiceProvider).applyInboxLimits()`.

- [ ] **Step 2: Add a settings row** to `inbox_settings_screen.dart` titled "Default episodes per podcast in inbox" presenting options No limit / 1 / 3 / 5 / 10. Follow the existing row/control pattern in that file (match how other inbox settings render and announce). Each option is a list choice; selecting writes via the provider. Use built-in widget semantics (RadioListTile/ListTile) per the project's accessibility rules — do not hand-roll Semantics around interactive widgets.

- [ ] **Step 3: Widget test** asserting the row renders, shows the current value, and selecting an option calls the provider. Model it on an existing settings-screen test (grep `test/features/settings/*settings_screen_test.dart`).

- [ ] **Step 4: Run.** `flutter test test/features/settings/` → PASS.

- [ ] **Step 5: Commit.**
```bash
git add lib/features/settings/presentation/ test/features/settings/
git commit -m "feat: global 'default episodes per podcast in inbox' setting UI"
```

---

## Task 8: Per-podcast UI (podcast settings)

**Files:**
- Modify: `lib/features/subscriptions/presentation/screens/podcast_settings_screen.dart` (+ its providers)
- Test: `test/features/subscriptions/presentation/podcast_settings_screen_test.dart` (create or extend)

- [ ] **Step 1: Add two rows** to the podcast settings screen, following the existing per-podcast rows (the screen already hosts queue age limit / speed override — match those exactly):
  - "Episodes in inbox": Use default / 1 / 3 / 5 / 10 → writes `setInboxMaxEpisodes(podcastId, value)` (null for "Use default"). On change, `applyForPodcast`.
  - "Remove from inbox after": Off / 6 hours / 12 hours / 1 day / 3 days / 1 week / 2 weeks → writes `setInboxAgeLimitHours(podcastId, hours)` (null for Off; map presets to 6/12/24/72/168/336). On change, `applyForPodcast`.

- [ ] **Step 2: Provider(s)** for reading/writing these per-podcast values, mirroring the existing queue-age-limit provider on that screen. After a write, call `ref.read(inboxLimitServiceProvider).applyForPodcast(podcastId)`.

- [ ] **Step 3: Widget test** that both rows render, reflect current values, and selecting writes through. Model on the existing podcast-settings test if present.

- [ ] **Step 4: Run.** `flutter test test/features/subscriptions/presentation/` → PASS.

- [ ] **Step 5: Commit.**
```bash
git add lib/features/subscriptions/presentation/ test/features/subscriptions/presentation/
git commit -m "feat: per-podcast inbox episode cap + age limit settings UI"
```

---

## Task 9: Accessibility review, CHANGELOG, full verification

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Run the accessibility agent** on the two settings screens' diffs (`mobile-accessibility`). Address any findings (settings rows must announce label + current value + role; touch targets ≥ 44pt; follow the project's built-in-widget-semantics rule). Re-run until clean.

- [ ] **Step 2: CHANGELOG entry** under `[Unreleased] → Added`:
```markdown
- Inbox limits: each podcast can now cap how many episodes stay in the inbox and
  auto-remove episodes older than a set time (6 hours up to 2 weeks), set on the
  podcast's settings page. A global "Default episodes per podcast in inbox"
  setting under Inbox settings sets the default (No limit by default). Removed
  episodes aren't deleted — they stay in the show's episode list.
```

- [ ] **Step 3: Full verification.**

Run: `dart format lib/ test/ && flutter analyze lib/ test/ && flutter test`
Expected: format clean, no analyzer issues, all tests pass.

- [ ] **Step 4: Commit.**
```bash
git add CHANGELOG.md
git commit -m "docs: changelog for per-podcast inbox limits (#319, #320)"
```

---

## Self-review notes (author)

- **Spec coverage:** count cap + global default (Tasks 2,3,4,5,7,8); age limit (Tasks 3,4,8); No-limit default + no upgrade trim (Task 2 default null + Task 4 early-out); subscribe anti-flood (Task 5 step 6); silent non-destructive removal (Task 4 only sets true); tighten-now-don't-reverse (Task 4 one-directional + test); started-episode exclusion (Task 4 `positionSeconds=0`); ordering trim-last (Task 5); include/exclude restore (Task 6); perf early-out (Task 4 + main_shell); migration (Task 1); a11y (Task 9). All covered.
- **Type consistency:** `applyInboxLimits()` (bulk) and `applyForPodcast(podcastId, {now, globalDefault})` used consistently across Tasks 4/5/6/7/8. Settings methods `getInboxDefaultMaxEpisodes`/`setInboxDefaultMaxEpisodes`, repo `setInboxMaxEpisodes`/`setInboxAgeLimitHours`, columns `inboxMaxEpisodes`/`inboxAgeLimitHours` consistent throughout.
- **Verify-during-execution:** exact provider file for `queueExpirationServiceProvider`, the `isInboxOptInOnly`/opt-in setting name, and the existing per-podcast queue-age-limit provider/row are grepped at execution time (noted inline) since their precise locations weren't all confirmed while authoring.
