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
}
