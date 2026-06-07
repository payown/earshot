import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:logging/logging.dart';

import '../../../core/utils/time_format.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/enums.dart';
import '../../../data/rss/parsed_feed.dart';
import '../../../data/rss/rss_parser.dart';
import '../../settings/data/app_settings_repository.dart';
import '../domain/episode.dart';
import '../domain/podcast.dart';
import 'podcast_exception.dart';
import 'podcast_repository.dart';

final _log = Logger('PodcastRepository');

class PodcastRepositoryImpl implements PodcastRepository {
  PodcastRepositoryImpl({
    required AppDatabase database,
    required Dio dio,
    required RssParser rssParser,
    required AppSettingsRepository settings,
  }) : _db = database,
       _dio = dio,
       _rssParser = rssParser,
       _settings = settings;

  final AppDatabase _db;
  final Dio _dio;
  final RssParser _rssParser;
  final AppSettingsRepository _settings;
  final _auditController = StreamController<String>.broadcast();

  @override
  Stream<String> get feedRefreshAuditEvents => _auditController.stream;

  @override
  Future<Podcast> subscribe(String rssUrl) async {
    final existing = await (_db.select(
      _db.podcasts,
    )..where((p) => p.rssUrl.equals(rssUrl))).getSingleOrNull();

    if (existing != null) {
      throw PodcastAlreadySubscribedException(rssUrl);
    }

    final feed = await _fetchAndParse(rssUrl);

    if (feed.title.isEmpty) {
      throw PodcastNotFoundException(rssUrl);
    }

    final podcastId = await _db
        .into(_db.podcasts)
        .insert(
          PodcastsCompanion.insert(
            rssUrl: rssUrl,
            title: feed.title,
            author: Value(feed.author),
            description: Value(feed.description),
            artworkUrl: Value(feed.artworkUrl),
            websiteUrl: Value(feed.websiteUrl),
            language: Value(feed.language),
            category: Value(feed.category),
            refreshedAt: Value(DateTime.now().toUtc()),
          ),
        );

    await _upsertEpisodes(
      podcastId,
      feed.episodes,
      preserveUserData: false,
      inboxLimit: 3,
    );

    _log.info('Subscribed to podcast: ${feed.title}');

    final row = await (_db.select(
      _db.podcasts,
    )..where((p) => p.id.equals(podcastId))).getSingle();

    return _podcastFromRow(row);
  }

  @override
  Future<void> unsubscribe(int podcastId) async {
    await (_db.delete(_db.podcasts)..where((p) => p.id.equals(podcastId))).go();
    _log.info('Unsubscribed from podcast $podcastId');
  }

  @override
  Stream<List<Podcast>> watchSubscriptions() {
    return (_db.select(_db.podcasts)
          ..orderBy([(p) => OrderingTerm.asc(p.title)]))
        .watch()
        .map((rows) => rows.map(_podcastFromRow).toList());
  }

  @override
  Stream<Podcast?> watchPodcast(int podcastId) {
    return (_db.select(_db.podcasts)..where((p) => p.id.equals(podcastId)))
        .watchSingleOrNull()
        .map((row) => row == null ? null : _podcastFromRow(row));
  }

  @override
  Stream<List<Episode>> watchEpisodes(int podcastId) {
    return (_db.select(_db.episodes)
          ..where((e) => e.podcastId.equals(podcastId))
          ..orderBy([(e) => OrderingTerm.desc(e.pubDate)]))
        .watch()
        .map((rows) => rows.map(_episodeFromRow).toList());
  }

  @override
  Future<void> refreshAllFeeds() async {
    final podcasts = await (_db.select(
      _db.podcasts,
    )..orderBy([(p) => OrderingTerm(expression: p.title.lower())])).get();
    // Apply inbox filter settings as a DB-only operation first so episodes are
    // dismissed/shown correctly even if individual network fetches fail below.
    await _applyInboxDismissals(podcasts);
    for (final podcast in podcasts) {
      try {
        await refreshFeed(podcast.id);
      } catch (e) {
        _log.warning('Background refresh failed for podcast ${podcast.id}: $e');
      }
    }
    _log.info(
      'Background feed refresh complete for ${podcasts.length} podcasts',
    );
  }

  Future<void> _applyInboxDismissals(List<PodcastRow> podcasts) async {
    final inboxOptInOnly = await _settings.isInboxOptInOnly();
    final toExclude = <int>[];
    final toInclude = <int>[];
    for (final podcast in podcasts) {
      if (inboxOptInOnly ? !podcast.inboxIncluded : podcast.inboxExcluded) {
        toExclude.add(podcast.id);
      } else if (inboxOptInOnly) {
        // In opt-in mode, restore episodes for podcasts that are now included
        // (e.g., user toggled them in during a prior session).
        toInclude.add(podcast.id);
      }
    }
    if (toExclude.isNotEmpty) {
      await _setEpisodesDismissed(toExclude, dismissed: true);
    }
    if (toInclude.isNotEmpty) {
      await _setEpisodesDismissed(toInclude, dismissed: false);
    }
  }

  Future<void> _setEpisodesDismissed(
    List<int> podcastIds, {
    required bool dismissed,
  }) async {
    await (_db.update(_db.episodes)..where(
          (e) =>
              e.podcastId.isIn(podcastIds) &
              e.inboxDismissed.equals(!dismissed) &
              e.status.equals(EpisodeStatus.newEpisode.name),
        ))
        .write(EpisodesCompanion(inboxDismissed: Value(dismissed)));
  }

  Future<void> _setEpisodeDismissed(
    int podcastId, {
    required bool dismissed,
  }) => _setEpisodesDismissed([podcastId], dismissed: dismissed);

  @override
  Future<void> refreshFeed(int podcastId) async {
    final podcastRow = await (_db.select(
      _db.podcasts,
    )..where((p) => p.id.equals(podcastId))).getSingleOrNull();

    if (podcastRow == null) return;

    final feed = await _fetchAndParse(podcastRow.rssUrl);

    await (_db.update(
      _db.podcasts,
    )..where((p) => p.id.equals(podcastId))).write(
      PodcastsCompanion(
        title: Value(feed.title),
        author: Value(feed.author),
        description: Value(feed.description),
        artworkUrl: Value(feed.artworkUrl),
        websiteUrl: Value(feed.websiteUrl),
        language: Value(feed.language),
        category: Value(feed.category),
        refreshedAt: Value(DateTime.now().toUtc()),
      ),
    );

    final inboxOptInOnly = await _settings.isInboxOptInOnly();
    final dismissed = inboxOptInOnly
        ? !podcastRow.inboxIncluded
        : podcastRow.inboxExcluded;
    await _upsertEpisodes(
      podcastId,
      feed.episodes,
      preserveUserData: true,
      inboxDismissed: dismissed,
    );

    // Retroactively apply dismissal to existing rows. _upsertEpisodes only
    // sets inboxDismissed on newly-inserted rows; existing rows keep their
    // previous value until this runs.
    await _setEpisodeDismissed(podcastId, dismissed: dismissed);

    _log.info('Refreshed feed for podcast $podcastId');
    _auditController.add('Feed checked at ${formatTimeOfDay(DateTime.now())}');
  }

  Future<ParsedPodcast> _fetchAndParse(String rssUrl) async {
    try {
      final response = await _dio.get<String>(rssUrl);
      final body = response.data;
      if (body == null || body.isEmpty) {
        throw PodcastFetchException('Empty response from $rssUrl');
      }
      return _rssParser.parse(body);
    } on DioException catch (e) {
      throw PodcastFetchException('Network error: ${e.message}');
    } on RssParseException {
      throw PodcastNotFoundException(rssUrl);
    }
  }

  // When preserveUserData is true, existing episodes only get metadata
  // columns updated (status/position are preserved). When false (initial
  // subscribe), the full row is inserted and conflicts are ignored.
  // inboxLimit controls how many of the most-recent episodes land as
  // newEpisode on initial subscribe; the rest are inserted as played so
  // they don't flood the inbox (only meaningful when preserveUserData=false).
  // inboxDismissed pre-dismisses new episodes so they never appear in the
  // inbox (used when the podcast is excluded or inbox opt-in mode is on).
  Future<void> _upsertEpisodes(
    int podcastId,
    List<ParsedEpisode> episodes, {
    required bool preserveUserData,
    int inboxLimit = 3,
    bool inboxDismissed = false,
  }) async {
    // On initial subscribe, sort newest-first so inboxLimit applies to the
    // most-recent episodes rather than arbitrary feed order.
    final ordered = preserveUserData
        ? episodes
        : (List<ParsedEpisode>.from(episodes)..sort((a, b) {
            if (a.pubDate == null) return 1;
            if (b.pubDate == null) return -1;
            return b.pubDate!.compareTo(a.pubDate!);
          }));

    for (var i = 0; i < ordered.length; i++) {
      final ep = ordered[i];

      // Historical episodes (beyond the inbox limit) are inserted as played
      // so they don't flood the inbox on bulk imports like OPML.
      final initialStatus = i < inboxLimit
          ? EpisodeStatus.newEpisode
          : EpisodeStatus.played;

      final companion = EpisodesCompanion.insert(
        podcastId: podcastId,
        guid: ep.guid,
        title: ep.title,
        audioUrl: ep.audioUrl,
        description: Value(ep.description),
        durationSeconds: Value(ep.durationSeconds),
        pubDate: Value(ep.pubDate),
        artworkUrl: Value(ep.artworkUrl),
        episodeNumber: Value(ep.episodeNumber),
        seasonNumber: Value(ep.seasonNumber),
        chapterUrl: Value(ep.chapterUrl),
        transcriptUrl: Value(ep.transcriptUrl),
        status: preserveUserData ? const Value.absent() : Value(initialStatus),
        inboxDismissed: Value(inboxDismissed),
      );

      if (preserveUserData) {
        await _db
            .into(_db.episodes)
            .insert(
              companion,
              onConflict: DoUpdate(
                (_) => EpisodesCompanion(
                  title: Value(ep.title),
                  audioUrl: Value(ep.audioUrl),
                  description: Value(ep.description),
                  durationSeconds: Value(ep.durationSeconds),
                  pubDate: Value(ep.pubDate),
                  artworkUrl: Value(ep.artworkUrl),
                  episodeNumber: Value(ep.episodeNumber),
                  seasonNumber: Value(ep.seasonNumber),
                  chapterUrl: Value(ep.chapterUrl),
                  transcriptUrl: Value(ep.transcriptUrl),
                ),
                target: [_db.episodes.podcastId, _db.episodes.guid],
              ),
            );
      } else {
        await _db
            .into(_db.episodes)
            .insert(companion, mode: InsertMode.insertOrIgnore);
      }
    }
  }

  @override
  Future<void> clearInbox() async {
    await (_db.update(
          _db.episodes,
        )..where(
          (e) =>
              e.status.equals(EpisodeStatus.newEpisode.name) &
              e.inboxDismissed.equals(false),
        ))
        .write(
          const EpisodesCompanion(inboxDismissed: Value(true)),
        );
    _log.info('Cleared inbox');
  }

  @override
  Future<void> updateEpisodeStatus(int episodeId, EpisodeStatus status) async {
    await (_db.update(
      _db.episodes,
    )..where((e) => e.id.equals(episodeId))).write(
      EpisodesCompanion(
        status: Value(status),
        playedAt: status == EpisodeStatus.played
            ? Value(DateTime.now().toUtc())
            : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> updateSpeedOverride(int podcastId, double? speed) async {
    await (_db.update(_db.podcasts)..where((p) => p.id.equals(podcastId)))
        .write(PodcastsCompanion(speedOverride: Value(speed)));
    _log.fine('Speed override for podcast $podcastId set to $speed');
  }

  @override
  Future<void> updateTrimSilenceOverride(
    int podcastId,
    bool? trimSilence,
  ) async {
    await (_db.update(_db.podcasts)..where((p) => p.id.equals(podcastId)))
        .write(PodcastsCompanion(trimSilenceOverride: Value(trimSilence)));
    _log.fine(
      'Trim silence override for podcast $podcastId set to $trimSilence',
    );
  }

  @override
  Future<void> disableCustomSettings(int podcastId) async {
    await (_db.update(
      _db.podcasts,
    )..where((p) => p.id.equals(podcastId))).write(
      const PodcastsCompanion(
        speedOverride: Value(null),
        trimSilenceOverride: Value(null),
      ),
    );
    _log.fine('Custom settings cleared for podcast $podcastId');
  }

  @override
  Future<void> setInboxExcluded(int podcastId, {required bool excluded}) async {
    await (_db.update(_db.podcasts)..where((p) => p.id.equals(podcastId)))
        .write(PodcastsCompanion(inboxExcluded: Value(excluded)));
    // Mirror the flag change onto episodes immediately so the inbox updates
    // without requiring a manual refresh. When un-excluding, restore episodes
    // that were dismissed because of this setting.
    await _setEpisodeDismissed(podcastId, dismissed: excluded);
    _log.fine('Inbox excluded for podcast $podcastId set to $excluded');
  }

  @override
  Future<void> setInboxIncluded(int podcastId, {required bool included}) async {
    await (_db.update(_db.podcasts)..where((p) => p.id.equals(podcastId)))
        .write(PodcastsCompanion(inboxIncluded: Value(included)));
    // In opt-in mode, mirror the flag change onto episodes immediately.
    // Removing a podcast hides its episodes; adding it back restores them.
    final inboxOptInOnly = await _settings.isInboxOptInOnly();
    if (inboxOptInOnly) {
      await _setEpisodeDismissed(podcastId, dismissed: !included);
    }
    _log.fine('Inbox included for podcast $podcastId set to $included');
  }

  Podcast _podcastFromRow(PodcastRow row) => Podcast(
    id: row.id,
    rssUrl: row.rssUrl,
    title: row.title,
    author: row.author,
    description: row.description,
    artworkUrl: row.artworkUrl,
    websiteUrl: row.websiteUrl,
    language: row.language,
    category: row.category,
    autoQueue: row.autoQueue,
    notificationEnabled: row.notificationEnabled,
    inboxExcluded: row.inboxExcluded,
    inboxIncluded: row.inboxIncluded,
    speedOverride: row.speedOverride,
    trimSilenceOverride: row.trimSilenceOverride,
    queueAgeLimitDays: row.queueAgeLimitDays,
    createdAt: row.createdAt,
    refreshedAt: row.refreshedAt,
  );

  Episode _episodeFromRow(EpisodeRow row) => Episode(
    id: row.id,
    podcastId: row.podcastId,
    guid: row.guid,
    title: row.title,
    description: row.description,
    audioUrl: row.audioUrl,
    durationSeconds: row.durationSeconds,
    pubDate: row.pubDate,
    artworkUrl: row.artworkUrl,
    episodeNumber: row.episodeNumber,
    seasonNumber: row.seasonNumber,
    chapterUrl: row.chapterUrl,
    transcriptUrl: row.transcriptUrl,
    status: row.status,
    downloadStatus: row.downloadStatus,
    downloadPath: row.downloadPath,
    positionSeconds: row.positionSeconds,
    playedAt: row.playedAt,
    createdAt: row.createdAt,
  );
}
