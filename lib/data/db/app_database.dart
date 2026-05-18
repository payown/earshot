import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'enums.dart';
import 'tables/episodes.dart';
import 'tables/podcasts.dart';
import 'tables/quick_action_configs.dart';

part 'app_database.g.dart';

@DriftDatabase(tables: [Podcasts, Episodes, QuickActionConfigs])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  AppDatabase.forTesting(super.connection);

  @override
  int get schemaVersion => 1;
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'earshot.db'));
    return NativeDatabase.createInBackground(file);
  });
}
