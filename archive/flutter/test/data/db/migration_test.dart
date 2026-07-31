import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/data/db/enums.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('schema migration from version 10 to 12', () {
    late Directory tempDir;
    late File dbFile;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('earshot_migration_test');
      dbFile = File('${tempDir.path}/earshot.db');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('onUpgrade completes and produces expected data', () async {
      // Seed a schema-12 database (via onCreate) with realistic data, then
      // roll the file back to schema 10 by dropping the column added in
      // schema 11 and resetting user_version. This simulates a tester whose
      // on-disk database predates the schema 11/12 migrations.
      final seedDb = AppDatabase.forTesting(NativeDatabase(dbFile));

      final podcastWithRecentEpisode = await seedDb
          .into(seedDb.podcasts)
          .insert(
            PodcastsCompanion.insert(
              rssUrl: 'https://example.com/a.xml',
              title: 'Podcast A',
            ),
          );
      final podcastWithNoPubDates = await seedDb
          .into(seedDb.podcasts)
          .insert(
            PodcastsCompanion.insert(
              rssUrl: 'https://example.com/b.xml',
              title: 'Podcast B',
            ),
          );

      final now = DateTime.now().toUtc();

      // Older episode, already played — should be left alone.
      await seedDb
          .into(seedDb.episodes)
          .insert(
            EpisodesCompanion.insert(
              podcastId: podcastWithRecentEpisode,
              guid: 'a-old',
              title: 'A old',
              audioUrl: 'https://example.com/a-old.mp3',
              pubDate: Value(now.subtract(const Duration(days: 10))),
              status: const Value(EpisodeStatus.played),
            ),
          );

      // Most recent episode for podcast A, still in the inbox — becomes the
      // high-water mark and should be dismissed by the schema 12 migration.
      final newestEpisodeId = await seedDb
          .into(seedDb.episodes)
          .insert(
            EpisodesCompanion.insert(
              podcastId: podcastWithRecentEpisode,
              guid: 'a-newest',
              title: 'A newest',
              audioUrl: 'https://example.com/a-newest.mp3',
              pubDate: Value(now.subtract(const Duration(days: 1))),
              status: const Value(EpisodeStatus.newEpisode),
            ),
          );

      // Episode with no pub date at all — exercises the `pub_date IS NULL`
      // branch of the schema 12 backfill.
      final noPubDateEpisodeId = await seedDb
          .into(seedDb.episodes)
          .insert(
            EpisodesCompanion.insert(
              podcastId: podcastWithNoPubDates,
              guid: 'b-no-date',
              title: 'B no date',
              audioUrl: 'https://example.com/b-no-date.mp3',
              status: const Value(EpisodeStatus.newEpisode),
            ),
          );

      // Roll the file back to schema 10: drop the column added in schema 11
      // and reset user_version so AppDatabase runs onUpgrade(10, 12) on next
      // open.
      await seedDb.customStatement(
        'ALTER TABLE podcasts DROP COLUMN last_seen_pub_date',
      );
      // Columns added in later schema versions must also be dropped so the
      // re-run of their addColumn migrations doesn't collide.
      await seedDb.customStatement(
        'ALTER TABLE podcasts DROP COLUMN inbox_max_episodes',
      );
      await seedDb.customStatement(
        'ALTER TABLE podcasts DROP COLUMN inbox_age_limit_hours',
      );
      await seedDb.customStatement('PRAGMA user_version = 10');
      await seedDb.close();

      // Reopen through AppDatabase — this triggers onUpgrade(10, 12).
      final upgradedDb = AppDatabase.forTesting(NativeDatabase(dbFile));
      final podcasts = await upgradedDb.select(upgradedDb.podcasts).get();
      final episodes = await upgradedDb.select(upgradedDb.episodes).get();

      expect(podcasts, hasLength(2));
      expect(episodes, hasLength(3));

      // from < 11 backfill: lastSeenPubDate = MAX(pubDate) per podcast.
      final podcastA = podcasts.firstWhere(
        (p) => p.id == podcastWithRecentEpisode,
      );
      expect(podcastA.lastSeenPubDate, isNotNull);

      final podcastB = podcasts.firstWhere(
        (p) => p.id == podcastWithNoPubDates,
      );
      // Podcast B's only episode has no pubDate, so MAX(pubDate) is NULL.
      expect(podcastB.lastSeenPubDate, isNull);

      // from < 12: the newest "newEpisode" row is at the high-water mark, so
      // it's dismissed from the inbox without changing playback status.
      final newestEpisode = episodes.firstWhere(
        (e) => e.id == newestEpisodeId,
      );
      expect(newestEpisode.inboxDismissed, isTrue);
      expect(newestEpisode.status, EpisodeStatus.newEpisode);

      // from < 12 only dismisses rows whose podcast has a non-null
      // lastSeenPubDate. Podcast B's lastSeenPubDate is null, so its
      // no-pub-date episode is left in the inbox.
      final noPubDateEpisode = episodes.firstWhere(
        (e) => e.id == noPubDateEpisodeId,
      );
      expect(noPubDateEpisode.inboxDismissed, isFalse);

      await upgradedDb.close();
    });
  });

  group('schema migration to version 13 heals a poisoned high-water mark', () {
    late Directory tempDir;
    late File dbFile;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('earshot_migration_v13');
      dbFile = File('${tempDir.path}/earshot.db');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('future-dated mark resets to newest non-future pub date', () async {
      // Seed a current-schema DB, then roll user_version back to 12 so the next
      // open runs onUpgrade(12, 13). v13 adds no columns, so the on-disk schema
      // is already correct — only the from < 13 data fix needs to run.
      final seedDb = AppDatabase.forTesting(NativeDatabase(dbFile));
      final now = DateTime.now().toUtc();

      // A tester poisoned by #296: the mark sits 30 days in the future.
      final poisoned = await seedDb
          .into(seedDb.podcasts)
          .insert(
            PodcastsCompanion.insert(
              rssUrl: 'https://example.com/poisoned.xml',
              title: 'Poisoned',
              lastSeenPubDate: Value(now.add(const Duration(days: 30))),
            ),
          );
      // A healthy podcast whose mark is already in the past.
      final healthy = await seedDb
          .into(seedDb.podcasts)
          .insert(
            PodcastsCompanion.insert(
              rssUrl: 'https://example.com/healthy.xml',
              title: 'Healthy',
              lastSeenPubDate: Value(now.subtract(const Duration(days: 1))),
            ),
          );

      // The true newest non-future episode for the poisoned podcast.
      await seedDb
          .into(seedDb.episodes)
          .insert(
            EpisodesCompanion.insert(
              podcastId: poisoned,
              guid: 'p-recent',
              title: 'Recent',
              audioUrl: 'https://example.com/p-recent.mp3',
              pubDate: Value(now.subtract(const Duration(days: 2))),
            ),
          );
      // A future-dated episode that must be ignored when recomputing the mark.
      await seedDb
          .into(seedDb.episodes)
          .insert(
            EpisodesCompanion.insert(
              podcastId: poisoned,
              guid: 'p-future',
              title: 'Future',
              audioUrl: 'https://example.com/p-future.mp3',
              pubDate: Value(now.add(const Duration(days: 30))),
            ),
          );

      await seedDb.customStatement(
        'ALTER TABLE podcasts DROP COLUMN inbox_max_episodes',
      );
      await seedDb.customStatement(
        'ALTER TABLE podcasts DROP COLUMN inbox_age_limit_hours',
      );
      await seedDb.customStatement('PRAGMA user_version = 12');
      await seedDb.close();

      final upgradedDb = AppDatabase.forTesting(NativeDatabase(dbFile));
      final rows = await upgradedDb.select(upgradedDb.podcasts).get();

      final poisonedRow = rows.firstWhere((p) => p.id == poisoned);
      expect(poisonedRow.lastSeenPubDate, isNotNull);
      expect(
        poisonedRow.lastSeenPubDate!.isAfter(now),
        isFalse,
        reason: 'the poisoned future mark must be pulled back to <= now',
      );
      // Reset to the newest non-future pub date (now - 2d), not the future one.
      final expectedMark = now.subtract(const Duration(days: 2));
      expect(
        poisonedRow.lastSeenPubDate!.difference(expectedMark).inSeconds.abs() <=
            1,
        isTrue,
        reason: 'mark should equal the newest non-future episode pub date',
      );

      // A mark already in the past is left untouched.
      final healthyRow = rows.firstWhere((p) => p.id == healthy);
      expect(healthyRow.lastSeenPubDate!.isBefore(now), isTrue);

      await upgradedDb.close();
    });
  });

  group('schema migration to version 14 adds the inbox index', () {
    late Directory tempDir;
    late File dbFile;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('earshot_migration_v14');
      dbFile = File('${tempDir.path}/earshot.db');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Future<List<String>> indexNames(AppDatabase db) async {
      final rows = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND name = 'idx_episodes_inbox'",
          )
          .get();
      return rows.map((r) => r.read<String>('name')).toList();
    }

    test(
      'onUpgrade(13, 14) creates idx_episodes_inbox without losing data',
      () async {
        // Seed a current-schema DB with realistic data, roll user_version back to
        // 13 (v14 adds no columns, only the index), then reopen to run
        // onUpgrade(13, 14).
        final seedDb = AppDatabase.forTesting(NativeDatabase(dbFile));
        final now = DateTime.now().toUtc();

        final podcastId = await seedDb
            .into(seedDb.podcasts)
            .insert(
              PodcastsCompanion.insert(
                rssUrl: 'https://example.com/a.xml',
                title: 'Podcast A',
              ),
            );
        // An inbox episode that the index-backed query must still return.
        await seedDb
            .into(seedDb.episodes)
            .insert(
              EpisodesCompanion.insert(
                podcastId: podcastId,
                guid: 'inbox-1',
                title: 'Inbox 1',
                audioUrl: 'https://example.com/inbox-1.mp3',
                pubDate: Value(now.subtract(const Duration(days: 1))),
                status: const Value(EpisodeStatus.newEpisode),
              ),
            );
        // A dismissed episode that must be filtered out.
        await seedDb
            .into(seedDb.episodes)
            .insert(
              EpisodesCompanion.insert(
                podcastId: podcastId,
                guid: 'dismissed-1',
                title: 'Dismissed 1',
                audioUrl: 'https://example.com/dismissed-1.mp3',
                pubDate: Value(now.subtract(const Duration(days: 2))),
                status: const Value(EpisodeStatus.newEpisode),
                inboxDismissed: const Value(true),
              ),
            );

        await seedDb.customStatement(
          'ALTER TABLE podcasts DROP COLUMN inbox_max_episodes',
        );
        await seedDb.customStatement(
          'ALTER TABLE podcasts DROP COLUMN inbox_age_limit_hours',
        );
        await seedDb.customStatement('PRAGMA user_version = 13');
        await seedDb.close();

        final upgradedDb = AppDatabase.forTesting(NativeDatabase(dbFile));

        // The migration completed and the index now exists.
        expect(await indexNames(upgradedDb), contains('idx_episodes_inbox'));

        // Data survived and the inbox query still returns exactly the right rows.
        final inbox =
            await (upgradedDb.select(upgradedDb.episodes)..where(
                  (e) =>
                      e.status.equals(EpisodeStatus.newEpisode.name) &
                      e.inboxDismissed.equals(false),
                ))
                .get();
        expect(inbox, hasLength(1));
        expect(inbox.single.guid, 'inbox-1');

        await upgradedDb.close();
      },
    );

    test('fresh onCreate database has the inbox index', () async {
      final freshDir = Directory.systemTemp.createTempSync('earshot_v14_fresh');
      addTearDown(() {
        if (freshDir.existsSync()) freshDir.deleteSync(recursive: true);
      });
      final db = AppDatabase.forTesting(
        NativeDatabase(File('${freshDir.path}/earshot.db')),
      );
      // Force the DB to open (runs onCreate) with a trivial query.
      await db.select(db.podcasts).get();
      expect(await indexNames(db), contains('idx_episodes_inbox'));
      await db.close();
    });
  });

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
      final podcastId = await seedDb
          .into(seedDb.podcasts)
          .insert(
            PodcastsCompanion.insert(
              rssUrl: 'https://example.com/a.xml',
              title: 'A',
            ),
          );
      // Drop the two columns and roll user_version back to 14.
      await seedDb.customStatement(
        'ALTER TABLE podcasts DROP COLUMN inbox_max_episodes',
      );
      await seedDb.customStatement(
        'ALTER TABLE podcasts DROP COLUMN inbox_age_limit_hours',
      );
      await seedDb.customStatement('PRAGMA user_version = 14');
      await seedDb.close();

      final upgraded = AppDatabase.forTesting(NativeDatabase(dbFile));
      final row = await (upgraded.select(
        upgraded.podcasts,
      )..where((p) => p.id.equals(podcastId))).getSingle();
      expect(row.inboxMaxEpisodes, isNull);
      expect(row.inboxAgeLimitHours, isNull);
      await upgraded.close();
    });
  });

  group('schema migration to version 16 seeds the export action', () {
    late Directory tempDir;
    late File dbFile;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('earshot_migration_test');
      dbFile = File('${tempDir.path}/earshot.db');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Future<void> _seedEpisodeConfig(
      AppDatabase db,
      List<String> keys,
    ) async {
      for (final (i, key) in keys.indexed) {
        await db
            .into(db.quickActionConfigs)
            .insert(
              QuickActionConfigsCompanion.insert(
                contentType: QuickActionContentType.episode,
                actionKey: key,
                sortOrder: i,
              ),
            );
      }
    }

    Future<List<String>> _episodeKeys(AppDatabase db) async {
      final rows =
          await (db.select(db.quickActionConfigs)
                ..where(
                  (q) => q.contentType.equals(
                    QuickActionContentType.episode.name,
                  ),
                )
                ..orderBy([(q) => OrderingTerm.asc(q.sortOrder)]))
              .get();
      return rows.map((r) => r.actionKey).toList();
    }

    test(
      'appends exportAudio to an existing customized episode config',
      () async {
        final seedDb = AppDatabase.forTesting(NativeDatabase(dbFile));
        await _seedEpisodeConfig(seedDb, ['playNow', 'download', 'share']);
        // A podcast config must be left untouched.
        await seedDb
            .into(seedDb.quickActionConfigs)
            .insert(
              QuickActionConfigsCompanion.insert(
                contentType: QuickActionContentType.podcast,
                actionKey: 'open',
                sortOrder: 0,
              ),
            );
        await seedDb.customStatement('PRAGMA user_version = 15');
        await seedDb.close();

        final upgraded = AppDatabase.forTesting(NativeDatabase(dbFile));
        expect(await _episodeKeys(upgraded), [
          'playNow',
          'download',
          'share',
          'exportAudio',
        ]);
        final podcastRows =
            await (upgraded.select(upgraded.quickActionConfigs)..where(
                  (q) =>
                      q.contentType.equals(QuickActionContentType.podcast.name),
                ))
                .get();
        expect(podcastRows.map((r) => r.actionKey), ['open']);
        await upgraded.close();
      },
    );

    test('is a no-op when the user has no saved episode config', () async {
      final seedDb = AppDatabase.forTesting(NativeDatabase(dbFile));
      await seedDb.customStatement('PRAGMA user_version = 15');
      await seedDb.close();

      final upgraded = AppDatabase.forTesting(NativeDatabase(dbFile));
      expect(await _episodeKeys(upgraded), isEmpty);
      await upgraded.close();
    });

    test('is idempotent when exportAudio is already saved', () async {
      final seedDb = AppDatabase.forTesting(NativeDatabase(dbFile));
      await _seedEpisodeConfig(seedDb, ['playNow', 'exportAudio']);
      await seedDb.customStatement('PRAGMA user_version = 15');
      await seedDb.close();

      final upgraded = AppDatabase.forTesting(NativeDatabase(dbFile));
      final keys = await _episodeKeys(upgraded);
      expect(keys.where((k) => k == 'exportAudio').length, 1);
      await upgraded.close();
    });
  });
}
