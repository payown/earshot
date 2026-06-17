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

  Future<int> newPodcast({int? max, int? ageHours, bool excluded = false}) => db
      .into(db.podcasts)
      .insert(
        PodcastsCompanion.insert(
          rssUrl:
              'https://example.com/${DateTime.now().microsecondsSinceEpoch}.xml',
          title: 'P',
          inboxMaxEpisodes: Value(max),
          inboxAgeLimitHours: Value(ageHours),
          inboxExcluded: Value(excluded),
        ),
      );

  Future<int> addEpisode(
    int podcastId, {
    required String guid,
    required DateTime pubDate,
    EpisodeStatus status = EpisodeStatus.newEpisode,
    bool dismissed = false,
    int position = 0,
  }) => db
      .into(db.episodes)
      .insert(
        EpisodesCompanion.insert(
          podcastId: podcastId,
          guid: guid,
          title: guid,
          audioUrl: 'https://example.com/$guid.mp3',
          pubDate: Value(pubDate),
          status: Value(status),
          inboxDismissed: Value(dismissed),
          positionSeconds: Value(position),
        ),
      );

  Future<bool> dismissed(int id) async => (await (db.select(
    db.episodes,
  )..where((e) => e.id.equals(id))).getSingle()).inboxDismissed;

  test('count cap keeps newest N, dismisses the rest', () async {
    final p = await newPodcast(max: 1);
    final newest = await addEpisode(p, guid: 'a', pubDate: now);
    final older = await addEpisode(
      p,
      guid: 'b',
      pubDate: now.subtract(const Duration(days: 1)),
    );
    await service.applyInboxLimits();
    expect(await dismissed(newest), isFalse);
    expect(await dismissed(older), isTrue);
  });

  test('No limit (no per-podcast, no global) dismisses nothing', () async {
    final p = await newPodcast();
    final a = await addEpisode(p, guid: 'a', pubDate: now);
    final b = await addEpisode(
      p,
      guid: 'b',
      pubDate: now.subtract(const Duration(days: 1)),
    );
    await service.applyInboxLimits();
    expect(await dismissed(a), isFalse);
    expect(await dismissed(b), isFalse);
  });

  test('global default applies when no per-podcast override', () async {
    await AppSettingsRepositoryImpl(database: db).setInboxDefaultMaxEpisodes(1);
    final p = await newPodcast();
    final newest = await addEpisode(p, guid: 'a', pubDate: now);
    final older = await addEpisode(
      p,
      guid: 'b',
      pubDate: now.subtract(const Duration(days: 1)),
    );
    await service.applyInboxLimits();
    expect(await dismissed(newest), isFalse);
    expect(await dismissed(older), isTrue);
  });

  test('per-podcast override beats global default', () async {
    await AppSettingsRepositoryImpl(database: db).setInboxDefaultMaxEpisodes(1);
    final p = await newPodcast(max: 5);
    for (var i = 0; i < 3; i++) {
      await addEpisode(
        p,
        guid: 'e$i',
        pubDate: now.subtract(Duration(days: i)),
      );
    }
    await service.applyInboxLimits();
    final remaining = await (db.select(
      db.episodes,
    )..where((e) => e.inboxDismissed.equals(false))).get();
    expect(remaining, hasLength(3));
  });

  test('count cap ignores played, queued, and started episodes', () async {
    final p = await newPodcast(max: 1);
    await addEpisode(p, guid: 'keep', pubDate: now);
    final played = await addEpisode(
      p,
      guid: 'played',
      pubDate: now.subtract(const Duration(days: 1)),
      status: EpisodeStatus.played,
    );
    final queued = await addEpisode(
      p,
      guid: 'queued',
      pubDate: now.subtract(const Duration(days: 2)),
      status: EpisodeStatus.inQueue,
    );
    final started = await addEpisode(
      p,
      guid: 'started',
      pubDate: now.subtract(const Duration(days: 3)),
      position: 120,
    );
    await service.applyInboxLimits();
    expect(await dismissed(played), isFalse);
    expect(await dismissed(queued), isFalse);
    expect(await dismissed(started), isFalse);
  });

  test('age limit dismisses episodes older than the cutoff', () async {
    final p = await newPodcast(ageHours: 24);
    final fresh = await addEpisode(
      p,
      guid: 'fresh',
      pubDate: now.subtract(const Duration(hours: 1)),
    );
    final stale = await addEpisode(
      p,
      guid: 'stale',
      pubDate: now.subtract(const Duration(hours: 48)),
    );
    await service.applyInboxLimits();
    expect(await dismissed(fresh), isFalse);
    expect(await dismissed(stale), isTrue);
  });

  test(
    'age limit does not dismiss a started episode past the cutoff',
    () async {
      final p = await newPodcast(ageHours: 24);
      final startedStale = await addEpisode(
        p,
        guid: 's',
        pubDate: now.subtract(const Duration(hours: 48)),
        position: 90,
      );
      await service.applyInboxLimits();
      expect(await dismissed(startedStale), isFalse);
    },
  );

  test('inbox-excluded podcast is untouched', () async {
    final p = await newPodcast(max: 1, excluded: true);
    final older = await addEpisode(
      p,
      guid: 'b',
      pubDate: now.subtract(const Duration(days: 1)),
    );
    await addEpisode(p, guid: 'a', pubDate: now);
    await service.applyInboxLimits();
    expect(await dismissed(older), isFalse);
  });

  test('does not un-dismiss already-dismissed episodes', () async {
    final p = await newPodcast(max: 5);
    final wasDismissed = await addEpisode(
      p,
      guid: 'd',
      pubDate: now,
      dismissed: true,
    );
    await service.applyInboxLimits();
    expect(await dismissed(wasDismissed), isTrue);
  });

  test('cap larger than the episode count trims nothing', () async {
    final p = await newPodcast(max: 5);
    final a = await addEpisode(p, guid: 'a', pubDate: now);
    final b = await addEpisode(
      p,
      guid: 'b',
      pubDate: now.subtract(const Duration(days: 1)),
    );
    await service.applyInboxLimits();
    expect(await dismissed(a), isFalse);
    expect(await dismissed(b), isFalse);
  });

  test('null-pubDate episode is treated as oldest and trimmed first', () async {
    // Documents intended behavior: undated episodes sort last (oldest), so a
    // count cap trims them before dated ones.
    final p = await newPodcast(max: 1);
    final dated = await addEpisode(p, guid: 'dated', pubDate: now);
    final undated = await db
        .into(db.episodes)
        .insert(
          EpisodesCompanion.insert(
            podcastId: p,
            guid: 'undated',
            title: 'undated',
            audioUrl: 'https://example.com/u.mp3',
            status: const Value(EpisodeStatus.newEpisode),
          ),
        );
    await service.applyInboxLimits();
    expect(await dismissed(dated), isFalse);
    expect(await dismissed(undated), isTrue);
  });

  test('age pass never trims a null-pubDate episode', () async {
    final p = await newPodcast(ageHours: 24);
    final undated = await db
        .into(db.episodes)
        .insert(
          EpisodesCompanion.insert(
            podcastId: p,
            guid: 'undated',
            title: 'undated',
            audioUrl: 'https://example.com/u.mp3',
            status: const Value(EpisodeStatus.newEpisode),
          ),
        );
    await service.applyInboxLimits();
    expect(await dismissed(undated), isFalse);
  });

  test(
    'age limit keeps an episode exactly at the cutoff and future-dated',
    () async {
      final p = await newPodcast(ageHours: 24);
      final atCutoff = await addEpisode(
        p,
        guid: 'at',
        pubDate: now.subtract(const Duration(hours: 24)),
      );
      final future = await addEpisode(
        p,
        guid: 'future',
        pubDate: now.add(const Duration(hours: 5)),
      );
      // Pass the test's captured `now` so the service shares one clock. Using
      // applyInboxLimits() lets the service compute its own (later) `now`,
      // nudging the cutoff past an episode dated exactly `now - 24h` and
      // making this boundary case race the clock.
      await service.applyForPodcast(p, now: now);
      expect(await dismissed(atCutoff), isFalse);
      expect(await dismissed(future), isFalse);
    },
  );

  test('opt-in mode: a not-included podcast is skipped', () async {
    await AppSettingsRepositoryImpl(
      database: db,
    ).setInboxOptInOnly(value: true);
    // Not included (inboxIncluded defaults false) -> excluded in opt-in mode.
    final p = await newPodcast(max: 1);
    final older = await addEpisode(
      p,
      guid: 'b',
      pubDate: now.subtract(const Duration(days: 1)),
    );
    await addEpisode(p, guid: 'a', pubDate: now);
    await service.applyInboxLimits();
    expect(await dismissed(older), isFalse);
  });

  test('applyForPodcast scopes to one podcast', () async {
    final p1 = await newPodcast(max: 1);
    final p2 = await newPodcast(max: 1);
    final p1Older = await addEpisode(
      p1,
      guid: 'p1b',
      pubDate: now.subtract(const Duration(days: 1)),
    );
    await addEpisode(p1, guid: 'p1a', pubDate: now);
    final p2Older = await addEpisode(
      p2,
      guid: 'p2b',
      pubDate: now.subtract(const Duration(days: 1)),
    );
    await addEpisode(p2, guid: 'p2a', pubDate: now);

    await service.applyForPodcast(p1);
    expect(await dismissed(p1Older), isTrue);
    expect(await dismissed(p2Older), isFalse); // untouched
  });
}
