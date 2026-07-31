import 'dart:io';

import 'package:drift/native.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/features/settings/data/quick_action_repository_impl.dart';
import 'package:earshot/features/settings/domain/quick_action_definition.dart';
import 'package:flutter_test/flutter_test.dart';

/// DIAGNOSTIC: does a reordered episode-action list survive an app restart?
/// Uses a real on-disk SQLite file and reopens a fresh AppDatabase on the same
/// file to simulate quitting and relaunching the app.
void main() {
  test(
    'reordered episode actions persist across a simulated app restart',
    () async {
      final dir = Directory.systemTemp.createTempSync('earshot_qa_test');
      final file = File('${dir.path}/app.sqlite');

      // First launch: save a non-default order.
      final db1 = AppDatabase.forTesting(NativeDatabase(file));
      final repo1 = QuickActionRepositoryImpl(database: db1);

      final reordered = <EpisodeAction>[
        EpisodeAction.openShowNotes,
        EpisodeAction.share,
        EpisodeAction.playNow,
        EpisodeAction.markPlayed,
      ];
      await repo1.saveEpisodeActions(reordered);

      // Confirm it round-trips while still open.
      final live = await repo1.watchEpisodeActions().first;
      expect(
        live,
        reordered,
        reason: 'order should be readable in same session',
      );

      await db1.close();

      // Second launch: brand-new AppDatabase on the SAME file.
      final db2 = AppDatabase.forTesting(NativeDatabase(file));
      final repo2 = QuickActionRepositoryImpl(database: db2);

      final afterRestart = await repo2.watchEpisodeActions().first;
      await db2.close();
      dir.deleteSync(recursive: true);

      expect(
        afterRestart,
        reordered,
        reason: 'reordered actions must survive an app restart',
      );
    },
  );
}
