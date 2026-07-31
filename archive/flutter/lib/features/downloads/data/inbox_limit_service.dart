import 'package:drift/drift.dart';
import 'package:logging/logging.dart';

import '../../../data/db/app_database.dart';
import '../../../data/db/enums.dart';
import '../../settings/data/app_settings_repository.dart';

final _log = Logger('InboxLimitService');

/// Enforces per-podcast inbox limits by hiding episodes from the inbox
/// (`inboxDismissed = true`). One-directional: it never clears the flag, so it
/// can't fight Clear Inbox or an include/exclude restore (#319, #320).
class InboxLimitService {
  InboxLimitService({
    required AppDatabase database,
    required AppSettingsRepository settings,
  }) : _db = database,
       _settings = settings;

  final AppDatabase _db;
  final AppSettingsRepository _settings;

  /// Applies count caps and age limits across all inbox-included podcasts.
  ///
  /// Early-outs before touching any podcast when no limits are in effect (no
  /// global default and no per-podcast value), so the common no-limits case —
  /// including every user on the upgrade that ships this — does effectively no
  /// work. This protects the cold-launch win from #278.
  Future<void> applyInboxLimits() async {
    final globalDefault = await _settings.getInboxDefaultMaxEpisodes();

    final anyPerPodcast =
        await (_db.selectOnly(_db.podcasts)
              ..addColumns([_db.podcasts.id])
              ..where(
                _db.podcasts.inboxMaxEpisodes.isNotNull() |
                    _db.podcasts.inboxAgeLimitHours.isNotNull(),
              )
              ..limit(1))
            .get();
    if (globalDefault == null && anyPerPodcast.isEmpty) return;

    final podcasts = await _db.select(_db.podcasts).get();
    final now = DateTime.now().toUtc();
    for (final podcast in podcasts) {
      if (await _isExcluded(podcast)) continue;
      await _applyForRow(podcast, now: now, globalDefault: globalDefault);
    }
  }

  /// Applies limits for a single podcast. Used after a feed refresh and after an
  /// inbox include/exclude restore so caps aren't left reversed.
  Future<void> applyForPodcast(int podcastId, {DateTime? now}) async {
    final podcast = await (_db.select(
      _db.podcasts,
    )..where((p) => p.id.equals(podcastId))).getSingleOrNull();
    if (podcast == null || await _isExcluded(podcast)) return;
    final globalDefault = await _settings.getInboxDefaultMaxEpisodes();
    await _applyForRow(
      podcast,
      now: now ?? DateTime.now().toUtc(),
      globalDefault: globalDefault,
    );
  }

  Future<void> _applyForRow(
    PodcastRow podcast, {
    required DateTime now,
    required int? globalDefault,
  }) async {
    // Age pass.
    final ageHours = podcast.inboxAgeLimitHours;
    if (ageHours != null) {
      final cutoff = now.subtract(Duration(hours: ageHours));
      await (_db.update(_db.episodes)..where(
            (e) =>
                e.podcastId.equals(podcast.id) &
                e.status.equals(EpisodeStatus.newEpisode.name) &
                e.inboxDismissed.equals(false) &
                e.positionSeconds.equals(0) &
                e.pubDate.isSmallerThanValue(cutoff),
          ))
          .write(const EpisodesCompanion(inboxDismissed: Value(true)));
    }

    // Count pass.
    final cap = podcast.inboxMaxEpisodes ?? globalDefault;
    if (cap != null) {
      final keepIds =
          (await (_db.selectOnly(_db.episodes)
                    ..addColumns([_db.episodes.id])
                    ..where(
                      _db.episodes.podcastId.equals(podcast.id) &
                          _db.episodes.status.equals(
                            EpisodeStatus.newEpisode.name,
                          ) &
                          _db.episodes.inboxDismissed.equals(false) &
                          _db.episodes.positionSeconds.equals(0),
                    )
                    ..orderBy([
                      OrderingTerm.desc(_db.episodes.pubDate),
                      OrderingTerm.desc(_db.episodes.id),
                    ])
                    ..limit(cap))
                  .get())
              .map((r) => r.read(_db.episodes.id)!)
              .toList();

      await (_db.update(_db.episodes)..where(
            (e) =>
                e.podcastId.equals(podcast.id) &
                e.status.equals(EpisodeStatus.newEpisode.name) &
                e.inboxDismissed.equals(false) &
                e.positionSeconds.equals(0) &
                e.id.isNotIn(keepIds),
          ))
          .write(const EpisodesCompanion(inboxDismissed: Value(true)));
    }
    _log.fine('Applied inbox limits for podcast ${podcast.id}');
  }

  Future<bool> _isExcluded(PodcastRow podcast) async {
    final optInOnly = await _settings.isInboxOptInOnly();
    return optInOnly ? !podcast.inboxIncluded : podcast.inboxExcluded;
  }
}
