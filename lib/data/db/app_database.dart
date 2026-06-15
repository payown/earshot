import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'enums.dart';
import 'tables/app_settings.dart';
import 'tables/bookmarks.dart';
import 'tables/episodes.dart';
import 'tables/listening_sessions.dart';
import 'tables/podcast_folder_memberships.dart';
import 'tables/podcast_folders.dart';
import 'tables/podcasts.dart';
import 'tables/queue_items.dart';
import 'tables/quick_action_configs.dart';
import 'tables/recently_expired.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [
    Podcasts,
    Episodes,
    QueueItems,
    QuickActionConfigs,
    AppSettings,
    RecentlyExpired,
    ListeningSessions,
    Bookmarks,
    PodcastFolders,
    PodcastFolderMemberships,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  AppDatabase.forTesting(super.connection);

  @override
  int get schemaVersion => 13;

  Future<void> clearAllData() => transaction(() async {
    await delete(podcasts).go();
    await delete(podcastFolders).go();
    await delete(quickActionConfigs).go();
    await delete(appSettings).go();
  });

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(queueItems);
      }
      if (from < 3) {
        await m.createTable(appSettings);
        await m.createTable(recentlyExpired);
      }
      if (from < 4) {
        await m.createTable(listeningSessions);
      }
      if (from < 5) {
        await m.createTable(bookmarks);
      }
      if (from < 6) {
        await m.createTable(podcastFolders);
        await m.createTable(podcastFolderMemberships);
      }
      if (from < 7) {
        await m.addColumn(episodes, episodes.inboxDismissed);
      }
      if (from < 8) {
        await m.addColumn(podcasts, podcasts.inboxExcluded);
      }
      if (from < 9) {
        await m.addColumn(podcasts, podcasts.inboxIncluded);
      }
      if (from < 10) {
        await m.addColumn(podcasts, podcasts.trimSilenceOverride);
      }
      if (from < 11) {
        await m.addColumn(podcasts, podcasts.lastSeenPubDate);
        // Backfill: set the high-water mark to the newest episode pub date
        // already in the DB for each podcast so existing episodes don't flood
        // the inbox on the first refresh after this upgrade.
        // security-ok: migration SQL, no user input
        await customStatement('''
          UPDATE podcasts
          SET last_seen_pub_date = (
            SELECT MAX(pub_date) FROM episodes
            WHERE episodes.podcast_id = podcasts.id
          )
        ''');
      }
      if (from < 12) {
        // Drain stale inbox rows: any newEpisode row whose pubDate is at or
        // before the high-water mark (or has no parseable date) was part of
        // the pre-upgrade backlog. Set inboxDismissed=true so they leave the
        // inbox immediately without changing playback status.
        // security-ok: migration SQL, no user input
        await customStatement('''
          UPDATE episodes
          SET inbox_dismissed = 1
          WHERE status = 'newEpisode'
            AND (
              pub_date IS NULL
              OR pub_date <= (
                SELECT last_seen_pub_date FROM podcasts
                WHERE podcasts.id = episodes.podcast_id
              )
            )
            AND EXISTS (
              SELECT 1 FROM podcasts
              WHERE podcasts.id = episodes.podcast_id
                AND podcasts.last_seen_pub_date IS NOT NULL
            )
        ''');
      }
      if (from < 13) {
        // Heal podcasts whose high-water mark was poisoned by a future-dated
        // episode before #296 was fixed: a mark ahead of "now" suppresses every
        // later, correctly-dated episode as backlog. Reset any future mark to
        // the newest non-future pub date for that podcast (or now() if it has
        // none), so new episodes reach the inbox again. DateTimes are stored as
        // unix seconds, matching strftime('%s','now').
        // security-ok: migration SQL, no user input
        await customStatement('''
          UPDATE podcasts
          SET last_seen_pub_date = COALESCE(
            (
              SELECT MAX(pub_date) FROM episodes
              WHERE episodes.podcast_id = podcasts.id
                AND pub_date <= CAST(strftime('%s', 'now') AS INTEGER)
            ),
            CAST(strftime('%s', 'now') AS INTEGER)
          )
          WHERE last_seen_pub_date > CAST(strftime('%s', 'now') AS INTEGER)
        ''');
      }
    },
    beforeOpen: (_) async {
      await customStatement(
        'PRAGMA foreign_keys = ON',
      ); // security-ok: fixed pragma, no user input
    },
  );
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'earshot.db'));
    return NativeDatabase.createInBackground(
      file,
      setup: (db) {
        // WAL mode allows the foreground app and the Workmanager background
        // task (separate Dart engine) to access the same file concurrently:
        // multiple readers and one writer can coexist without SQLITE_BUSY.
        db.execute('PRAGMA journal_mode=WAL;');
        // Give contending operations up to 3 seconds to retry before throwing,
        // as a backstop for any remaining lock contention.
        db.execute('PRAGMA busy_timeout=3000;');
      },
    );
  });
}
