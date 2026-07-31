import 'dart:async';
import 'dart:math' show min;

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:logging/logging.dart';

import '../../../core/utils/time_format.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/enums.dart';
import '../../../data/rss/parsed_feed.dart';
import '../../../data/rss/rss_parser.dart';
import '../../downloads/data/inbox_limit_service.dart';
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

    // Seed the inbox using the effective count cap when a finite global default
    // is set, otherwise keep the existing anti-flood default of 3 (No limit).
    final seed = await _settings.getInboxDefaultMaxEpisodes() ?? 3;
    await _upsertEpisodes(
      podcastId,
      feed.episodes,
      preserveUserData: false,
      inboxLimit: seed,
    );

    // Set the high-water mark so the first refresh doesn't re-surface the
    // episodes inserted during subscribe as backlog. Future-dated items are
    // excluded so a misdated episode can't push the mark ahead of real new
    // episodes (#296). Fall back to now() when no usable pubDate exists in the
    // feed so the gate is always seeded.
    final nowUtc = DateTime.now().toUtc();
    final latestOnSubscribe = _latestNonFuturePubDate(
      feed.episodes,
      now: nowUtc,
    );
    await (_db.update(
      _db.podcasts,
    )..where((p) => p.id.equals(podcastId))).write(
      PodcastsCompanion(lastSeenPubDate: Value(latestOnSubscribe ?? nowUtc)),
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
          ..orderBy([(p) => OrderingTerm(expression: p.title.lower())]))
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

  // Fetch up to this many feeds concurrently. Higher values reduce total
  // refresh time but increase peak network and CPU load.
  static const _kRefreshConcurrency = 5;

  @override
  Future<void> refreshAllFeeds() async {
    final batchStartedAt = DateTime.now().toUtc();
    final podcasts = await (_db.select(
      _db.podcasts,
    )..orderBy([(p) => OrderingTerm(expression: p.title.lower())])).get();
    // Apply inbox filter settings as a DB-only operation first so episodes are
    // dismissed/shown correctly even if individual network fetches fail below.
    await _applyInboxDismissals(podcasts);

    // Fetch feeds in parallel batches. With 50 feeds at ~2s each, serial takes
    // ~100s; 5 concurrent cuts that to ~20s.
    for (var i = 0; i < podcasts.length; i += _kRefreshConcurrency) {
      final batch = podcasts.sublist(
        i,
        min(i + _kRefreshConcurrency, podcasts.length),
      );
      await Future.wait(
        batch.map((podcast) async {
          try {
            await refreshFeed(podcast.id, batchRefreshedAt: batchStartedAt);
          } catch (e, st) {
            _log.warning(
              'Feed refresh failed for podcast ${podcast.id}',
              e,
              st,
            );
          }
        }),
      );
    }

    _log.info(
      'Background feed refresh complete for ${podcasts.length} podcasts',
    );
    _auditController.add(
      'All feeds checked at ${formatTimeOfDay(batchStartedAt.toLocal())}',
    );
  }

  Future<void> _applyInboxDismissals(List<PodcastRow> podcasts) async {
    final inboxOptInOnly = await _settings.isInboxOptInOnly();
    final toExclude = <int>[];
    for (final podcast in podcasts) {
      if (inboxOptInOnly ? !podcast.inboxIncluded : podcast.inboxExcluded) {
        toExclude.add(podcast.id);
      }
    }
    if (toExclude.isNotEmpty) {
      await _setEpisodesDismissed(toExclude, dismissed: true);
    }
    // The restore direction (dismissed=false) is handled by setInboxIncluded at
    // toggle time. Running it here on every refresh would undo clearInbox for
    // opt-in mode users, mirroring the regression fixed in refreshFeed (#200).
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

  /// Returns auto-dismissed backlog episodes whose pubDate was just bumped past
  /// the inbox high-water mark to the inbox (#298). Deliberately conservative:
  /// every condition must hold, so a false negative (a real republish that
  /// doesn't resurface) is preferred over a false positive (re-flooding the
  /// inbox with episodes the user already finished).
  ///
  /// Eligibility — all required:
  /// - `status == played` AND `inboxDismissed == true`: the durable marker that
  ///   this row was auto-dismissed backlog, not user action (a user marking an
  ///   inbox episode played leaves inboxDismissed false).
  /// - `playedAt IS NULL`: a second, independent guard — every user play path
  ///   stamps playedAt, the backlog insert does not.
  /// - `positionSeconds == 0`: never started.
  /// - not in the queue.
  /// - `sinceMark < pubDate <= now`: genuinely newer than the old mark, and not
  ///   future-dated (future items must not enter the inbox, #296).
  Future<void> _resurrectRepublishedEpisodes(
    int podcastId, {
    required DateTime sinceMark,
    required DateTime now,
  }) async {
    final queuedEpisodeIds = _db.selectOnly(_db.queueItems)
      ..addColumns([_db.queueItems.episodeId]);
    await (_db.update(_db.episodes)..where(
          (e) =>
              e.podcastId.equals(podcastId) &
              e.status.equals(EpisodeStatus.played.name) &
              e.inboxDismissed.equals(true) &
              e.playedAt.isNull() &
              e.positionSeconds.equals(0) &
              e.pubDate.isBiggerThanValue(sinceMark) &
              e.pubDate.isSmallerOrEqualValue(now) &
              e.id.isNotInQuery(queuedEpisodeIds),
        ))
        .write(
          const EpisodesCompanion(
            status: Value(EpisodeStatus.newEpisode),
            inboxDismissed: Value(false),
          ),
        );
  }

  @override
  Future<void> refreshFeed(int podcastId, {DateTime? batchRefreshedAt}) async {
    final podcastRow = await (_db.select(
      _db.podcasts,
    )..where((p) => p.id.equals(podcastId))).getSingleOrNull();

    if (podcastRow == null) return;

    final refreshedAt = batchRefreshedAt ?? DateTime.now().toUtc();
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
        refreshedAt: Value(refreshedAt),
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
      lastSeenPubDate: podcastRow.lastSeenPubDate,
    );

    // Retroactively dismiss existing rows when this podcast is excluded from
    // the inbox. The restore direction (dismissed=false) is handled by
    // setInboxExcluded/setInboxIncluded at toggle time — running it here would
    // silently undo any Clear Inbox the user performed.
    if (dismissed) {
      await _setEpisodeDismissed(podcastId, dismissed: true);
    }

    final nowUtc = DateTime.now().toUtc();

    // Bring a republished episode back to the inbox: same GUID, but its pubDate
    // was bumped past the high-water mark by this refresh (#298). Only episodes
    // that were auto-dismissed backlog the user never touched are eligible;
    // anything the user played, started, queued, or cleared is left alone.
    // Skipped when the podcast is excluded from the inbox. Uses the pre-advance
    // mark (the row's stored lastSeenPubDate, still unchanged here).
    final oldMark = podcastRow.lastSeenPubDate;
    if (!dismissed && oldMark != null) {
      await _resurrectRepublishedEpisodes(
        podcastId,
        sinceMark: oldMark,
        now: nowUtc,
      );
    }

    // Advance the high-water mark to the newest non-future pub date seen in
    // this fetch. Future-dated items are ignored: letting one advance the mark
    // would make every later, correctly-dated episode look like backlog and be
    // silently dismissed from the inbox (#296).
    final latestPubDate = _latestNonFuturePubDate(feed.episodes, now: nowUtc);
    final prev = podcastRow.lastSeenPubDate;
    // Clamp an already-future mark back to now so a podcast poisoned before this
    // fix self-heals on its next refresh, not only via the v13 migration.
    final clampedPrev = (prev != null && prev.isAfter(nowUtc)) ? nowUtc : prev;
    final DateTime? newMark;
    if (clampedPrev == null) {
      newMark = latestPubDate;
    } else if (latestPubDate == null || !latestPubDate.isAfter(clampedPrev)) {
      newMark = clampedPrev;
    } else {
      newMark = latestPubDate;
    }
    if (newMark != null && newMark != prev) {
      await (_db.update(_db.podcasts)..where((p) => p.id.equals(podcastId)))
          .write(PodcastsCompanion(lastSeenPubDate: Value(newMark)));
    }

    // Inbox limits run last so they see the final inbox state for this feed
    // (after #298 resurrection and the high-water mark advance). A republished
    // episode resurfaced by #298 that is now beyond the count cap or past the
    // age cutoff is correctly re-trimmed in this same pass.
    await InboxLimitService(
      database: _db,
      settings: _settings,
    ).applyForPodcast(podcastId, now: nowUtc);

    _log.info('Refreshed feed for podcast $podcastId');
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

  /// The newest episode pub date that is not after [now].
  ///
  /// Future-dated items (from feeds with bad timezones, scheduling bugs, or
  /// "sticky" episodes) are excluded so they can never advance the inbox
  /// high-water mark. If one did, every later episode with a correct date would
  /// fail the `isAfter(lastSeenPubDate)` test and be treated as backlog, so new
  /// episodes would silently stop reaching the inbox (#296). Returns null when
  /// no episode has a usable past-or-present pubDate.
  DateTime? _latestNonFuturePubDate(
    List<ParsedEpisode> episodes, {
    required DateTime now,
  }) {
    return episodes
        .where((e) => e.pubDate != null && !e.pubDate!.isAfter(now))
        .map((e) => e.pubDate!)
        .fold<DateTime?>(
          null,
          (max, d) => max == null || d.isAfter(max) ? d : max,
        );
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
    DateTime? lastSeenPubDate,
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

    // One batched write instead of an awaited INSERT per episode. A feed with
    // 100 episodes was 100 sequential round-trips; multiplied across a large
    // library during refresh this was a major contributor to the inbox being
    // unreachable on cold launch (#278). Behavior per row is unchanged — only
    // the execution is batched into a single prepared-statement transaction.
    await _db.batch((b) {
      for (var i = 0; i < ordered.length; i++) {
        final ep = ordered[i];

        // Historical episodes (beyond the inbox limit) are inserted as played
        // so they don't flood the inbox on bulk imports like OPML.
        final initialStatus = i < inboxLimit
            ? EpisodeStatus.newEpisode
            : EpisodeStatus.played;

        // On refresh, episodes at or before the high-water mark are backlog —
        // insert them as played/dismissed so they never surface in the inbox.
        // Null pubDates are also treated as backlog once a mark exists: real new
        // episodes from healthy feeds carry pubDates; items with no parseable
        // date are overwhelmingly recycled backlog from feeds with unstable
        // GUIDs.
        final isBacklog =
            preserveUserData &&
            lastSeenPubDate != null &&
            (ep.pubDate == null || !ep.pubDate!.isAfter(lastSeenPubDate));

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
          status: preserveUserData
              ? (isBacklog
                    ? const Value(EpisodeStatus.played)
                    : const Value.absent())
              : Value(initialStatus),
          inboxDismissed: isBacklog ? const Value(true) : Value(inboxDismissed),
        );

        if (preserveUserData) {
          b.insert(
            _db.episodes,
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
          b.insert(_db.episodes, companion, mode: InsertMode.insertOrIgnore);
        }
      }
    });
  }

  @override
  Future<void> dismissFromInbox(
    int episodeId, {
    required bool alsoMarkPlayed,
  }) async {
    await (_db.update(
      _db.episodes,
    )..where((e) => e.id.equals(episodeId))).write(
      EpisodesCompanion(
        inboxDismissed: const Value(true),
        status: alsoMarkPlayed
            ? const Value(EpisodeStatus.played)
            : const Value.absent(),
        playedAt: alsoMarkPlayed
            ? Value(DateTime.now().toUtc())
            : const Value.absent(),
      ),
    );
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
    // Re-including (un-excluding) clears inboxDismissed for the whole podcast,
    // which would silently reverse a count/age trim. Re-apply the limits so the
    // user never sees more than the cap after a restore.
    if (!excluded) {
      await InboxLimitService(
        database: _db,
        settings: _settings,
      ).applyForPodcast(podcastId);
    }
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
      // Including a podcast clears inboxDismissed for its episodes, which would
      // silently reverse a count/age trim. Re-apply the limits after the restore
      // so caps aren't reversed by a re-include.
      if (included) {
        await InboxLimitService(
          database: _db,
          settings: _settings,
        ).applyForPodcast(podcastId);
      }
    }
    _log.fine('Inbox included for podcast $podcastId set to $included');
  }

  @override
  Future<void> setInboxMaxEpisodes(int podcastId, int? max) =>
      (_db.update(_db.podcasts)..where((p) => p.id.equals(podcastId))).write(
        PodcastsCompanion(inboxMaxEpisodes: Value(max)),
      );

  @override
  Future<void> setInboxAgeLimitHours(int podcastId, int? hours) =>
      (_db.update(_db.podcasts)..where((p) => p.id.equals(podcastId))).write(
        PodcastsCompanion(inboxAgeLimitHours: Value(hours)),
      );

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
    inboxMaxEpisodes: row.inboxMaxEpisodes,
    inboxAgeLimitHours: row.inboxAgeLimitHours,
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
