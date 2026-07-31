import 'package:drift/native.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/data/db/enums.dart';
import 'package:earshot/features/settings/data/quick_action_repository_impl.dart';
import 'package:earshot/features/settings/domain/quick_action_definition.dart';
import 'package:flutter_test/flutter_test.dart';

/// CONFIRMS the suspected root cause: a user whose DB still holds the legacy
/// 'addToQueue' key (renamed to 'addToEndOfQueue') AND an 'addToEndOfQueue' row
/// reads back a list containing EpisodeAction.addToEndOfQueue twice. Saving that
/// list re-inserts two rows with the same {episode, addToEndOfQueue} key, which
/// violates the UNIQUE constraint and aborts the whole save transaction — so the
/// reorder silently never persists and reverts on every restart.
void main() {
  test(
    'saving a list with a duplicate key (legacy addToQueue) persists',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = QuickActionRepositoryImpl(database: db);

      // Seed a realistic legacy-data state: an old 'addToQueue' row plus the
      // current 'addToEndOfQueue' row, in some user-chosen order.
      Future<void> seed(String key, int order) => db
          .into(db.quickActionConfigs)
          .insert(
            QuickActionConfigsCompanion.insert(
              contentType: QuickActionContentType.episode,
              actionKey: key,
              sortOrder: order,
            ),
          );
      await seed('playNow', 0);
      await seed('addToQueue', 1); // legacy -> maps to addToEndOfQueue on read
      await seed('addToEndOfQueue', 2);
      await seed('share', 3);

      // Read back the way the configurator does. Legacy + current both map to
      // addToEndOfQueue, so the list contains it twice.
      final asRead = await repo.watchEpisodeActions().first;
      expect(
        asRead.where((a) => a == EpisodeAction.addToEndOfQueue).length,
        2,
        reason: 'precondition: legacy + current both map to addToEndOfQueue',
      );

      // Now save that list back, exactly like tapping Save in the configurator.
      // Before the fix this throws (UNIQUE constraint) and nothing persists.
      await repo.saveEpisodeActions(asRead);

      // After saving, the order must round-trip with the duplicate collapsed.
      final after = await repo.watchEpisodeActions().first;
      expect(after, [
        EpisodeAction.playNow,
        EpisodeAction.addToEndOfQueue,
        EpisodeAction.share,
      ]);
    },
  );
}
