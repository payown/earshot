import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'enums.dart';
import 'tables/app_settings.dart';
import 'tables/episodes.dart';
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
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  AppDatabase.forTesting(super.connection);

  @override
  int get schemaVersion => 3;

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
