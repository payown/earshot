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
  int get schemaVersion => 10;

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
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'earshot.db'));
    return NativeDatabase.createInBackground(file);
  });
}
