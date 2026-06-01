import 'package:drift/drift.dart';

import '../../../data/db/app_database.dart';
import '../../../data/db/enums.dart';
import '../domain/quick_action_definition.dart';
import 'quick_action_repository.dart';

class QuickActionRepositoryImpl implements QuickActionRepository {
  const QuickActionRepositoryImpl({required AppDatabase database})
    : _db = database;

  final AppDatabase _db;

  @override
  Stream<List<EpisodeAction>> watchEpisodeActions() {
    return (_db.select(_db.quickActionConfigs)
          ..where(
            (q) => q.contentType.equals(QuickActionContentType.episode.name),
          )
          ..orderBy([(q) => OrderingTerm.asc(q.sortOrder)]))
        .watch()
        .map((rows) {
          if (rows.isEmpty) return defaultEpisodeActions;
          return rows.map((r) {
            // Migrate legacy "addToQueue" key (renamed to addToEndOfQueue).
            final key = r.actionKey == 'addToQueue'
                ? 'addToEndOfQueue'
                : r.actionKey;
            return EpisodeAction.values.firstWhere(
              (a) => a.key == key,
              orElse: () => EpisodeAction.playNow,
            );
          }).toList();
        });
  }

  @override
  Stream<List<PodcastAction>> watchPodcastActions() {
    return (_db.select(_db.quickActionConfigs)
          ..where(
            (q) => q.contentType.equals(QuickActionContentType.podcast.name),
          )
          ..orderBy([(q) => OrderingTerm.asc(q.sortOrder)]))
        .watch()
        .map((rows) {
          if (rows.isEmpty) return defaultPodcastActions;
          return rows
              .map(
                (r) => PodcastAction.values.firstWhere(
                  (a) => a.key == r.actionKey,
                  orElse: () => PodcastAction.open,
                ),
              )
              .toList();
        });
  }

  @override
  Future<void> saveEpisodeActions(List<EpisodeAction> actions) =>
      _saveActions(QuickActionContentType.episode, actions.map((a) => a.key));

  @override
  Future<void> savePodcastActions(List<PodcastAction> actions) =>
      _saveActions(QuickActionContentType.podcast, actions.map((a) => a.key));

  Future<void> _saveActions(
    QuickActionContentType contentType,
    Iterable<String> actionKeys,
  ) async {
    await _db.transaction(() async {
      await (_db.delete(
        _db.quickActionConfigs,
      )..where((q) => q.contentType.equals(contentType.name))).go();

      var order = 0;
      for (final key in actionKeys) {
        await _db
            .into(_db.quickActionConfigs)
            .insert(
              QuickActionConfigsCompanion.insert(
                contentType: contentType,
                actionKey: key,
                sortOrder: order++,
              ),
            );
      }
    });
  }
}
