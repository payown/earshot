import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:logging/logging.dart';

import '../../../data/db/app_database.dart';
import '../../../data/rss/parsed_feed.dart';
import '../../../data/rss/rss_parser.dart';
import '../domain/episode.dart';
import '../domain/podcast.dart';
import 'podcast_exception.dart';
import 'podcast_repository.dart';

final _log = Logger('PodcastRepository');

class PodcastRepositoryImpl implements PodcastRepository {
  const PodcastRepositoryImpl({
    required AppDatabase database,
    required Dio dio,
    required RssParser rssParser,
  }) : _db = database,
       _dio = dio,
       _rssParser = rssParser;

  final AppDatabase _db;
  final Dio _dio;
  final RssParser _rssParser;

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

    await _upsertEpisodes(podcastId, feed.episodes, preserveUserData: false);

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
  Stream<List<Episode>> watchEpisodes(int podcastId) {
    return (_db.select(_db.episodes)
          ..where((e) => e.podcastId.equals(podcastId))
          ..orderBy([(e) => OrderingTerm.desc(e.pubDate)]))
        .watch()
        .map((rows) => rows.map(_episodeFromRow).toList());
  }

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

    await _upsertEpisodes(podcastId, feed.episodes, preserveUserData: true);

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

  // When preserveUserData is true, existing episodes only get metadata
  // columns updated (status/position are preserved). When false (initial
  // subscribe), the full row is inserted and conflicts are ignored.
  Future<void> _upsertEpisodes(
    int podcastId,
    List<ParsedEpisode> episodes, {
    required bool preserveUserData,
  }) async {
    for (final ep in episodes) {
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
    speedOverride: row.speedOverride,
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
