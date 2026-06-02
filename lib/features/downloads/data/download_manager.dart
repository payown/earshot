import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../data/db/app_database.dart';
import '../../../data/db/enums.dart';
import '../../../features/settings/data/app_settings_repository.dart';

final _log = Logger('DownloadManager');

enum DownloadStartResult {
  started,
  skippedNoWifi,
  alreadyDownloaded,
  alreadyDownloading,
  notFound,
  failed,
}

class DownloadManager {
  DownloadManager({
    required AppDatabase database,
    required Dio dio,
    required AppSettingsRepository settings,
  }) : _db = database,
       _dio = dio,
       _settings = settings;

  final AppDatabase _db;
  final Dio _dio;
  final AppSettingsRepository _settings;

  final Map<int, CancelToken> _cancelTokens = {};

  Future<DownloadStartResult> downloadEpisode(
    int episodeId, {
    void Function(String message)? onComplete,
  }) async {
    final row = await (_db.select(
      _db.episodes,
    )..where((e) => e.id.equals(episodeId))).getSingleOrNull();

    if (row == null) return DownloadStartResult.notFound;
    if (row.downloadStatus == DownloadStatus.downloaded) {
      return DownloadStartResult.alreadyDownloaded;
    }
    if (row.downloadStatus == DownloadStatus.downloading ||
        row.downloadStatus == DownloadStatus.pending) {
      return DownloadStartResult.alreadyDownloading;
    }

    if (!await _isWifiAvailable()) {
      _log.info('Download skipped — not on Wi-Fi');
      return DownloadStartResult.skippedNoWifi;
    }

    final cancelToken = CancelToken();
    _cancelTokens[episodeId] = cancelToken;
    await _setStatus(episodeId, DownloadStatus.pending);
    unawaited(_runDownload(episodeId, row.audioUrl, cancelToken, onComplete));
    return DownloadStartResult.started;
  }

  Future<void> _runDownload(
    int episodeId,
    String audioUrl,
    CancelToken cancelToken,
    void Function(String message)? onComplete,
  ) async {
    final file = await _destinationFile(episodeId, audioUrl);
    try {
      if (cancelToken.isCancelled) {
        await _setStatus(episodeId, DownloadStatus.none);
        return;
      }
      await _setStatus(episodeId, DownloadStatus.downloading);
      await _dio.download(
        audioUrl,
        file.path,
        cancelToken: cancelToken,
        options: Options(receiveTimeout: null),
      );
      await _db.transaction(() async {
        await _setStatus(episodeId, DownloadStatus.downloaded);
        await (_db.update(_db.episodes)..where((e) => e.id.equals(episodeId)))
            .write(EpisodesCompanion(downloadPath: Value(file.path)));
      });
      _log.info('Downloaded episode $episodeId to ${file.path}');
      onComplete?.call('Download complete');
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        _log.fine('Download cancelled for episode $episodeId');
        if (await file.exists()) await file.delete();
        await _setStatus(episodeId, DownloadStatus.none);
      } else {
        _log.warning('Download failed for episode $episodeId: ${e.message}');
        await _setStatus(episodeId, DownloadStatus.failed);
        onComplete?.call('Download failed');
      }
    } catch (e, st) {
      _log.warning('Unexpected download error for $episodeId: $e\n$st');
      await _setStatus(episodeId, DownloadStatus.failed);
      onComplete?.call('Download failed');
    } finally {
      _cancelTokens.remove(episodeId);
    }
  }

  Future<void> cancelDownload(int episodeId) async {
    _cancelTokens[episodeId]?.cancel('User cancelled');
  }

  Future<void> deleteDownload(int episodeId) async {
    final row = await (_db.select(
      _db.episodes,
    )..where((e) => e.id.equals(episodeId))).getSingleOrNull();

    if (row?.downloadPath case final path?) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }

    await (_db.update(
      _db.episodes,
    )..where((e) => e.id.equals(episodeId))).write(
      const EpisodesCompanion(
        downloadStatus: Value(DownloadStatus.none),
        downloadPath: Value(null),
      ),
    );

    _log.info('Deleted download for episode $episodeId');
  }

  Future<void> downloadInboxEpisodes() async {
    final episodes =
        await (_db.select(_db.episodes)..where(
              (e) =>
                  e.status.equals(EpisodeStatus.newEpisode.name) &
                  e.inboxDismissed.equals(false) &
                  e.downloadStatus.isNotIn([
                    DownloadStatus.downloaded.name,
                    DownloadStatus.downloading.name,
                    DownloadStatus.pending.name,
                  ]),
            ))
            .get();

    for (final ep in episodes) {
      if (!await _isWifiAvailable()) {
        _log.info('Inbox batch download stopped — not on Wi-Fi');
        return;
      }
      final cancelToken = CancelToken();
      _cancelTokens[ep.id] = cancelToken;
      await _setStatus(ep.id, DownloadStatus.pending);
      unawaited(_runDownload(ep.id, ep.audioUrl, cancelToken, null));
    }
  }

  Future<void> downloadQueueEpisodes() async {
    final query = _db.select(_db.queueItems).join([
      innerJoin(
        _db.episodes,
        _db.episodes.id.equalsExp(_db.queueItems.episodeId),
      ),
    ])..orderBy([OrderingTerm.asc(_db.queueItems.position)]);

    final rows = await query.get();
    final episodes = rows
        .map((r) => r.readTable(_db.episodes))
        .where(
          (ep) =>
              ep.downloadStatus != DownloadStatus.downloaded &&
              ep.downloadStatus != DownloadStatus.downloading &&
              ep.downloadStatus != DownloadStatus.pending,
        )
        .toList();

    for (final ep in episodes) {
      if (!await _isWifiAvailable()) {
        _log.info('Queue batch download stopped — not on Wi-Fi');
        return;
      }
      final cancelToken = CancelToken();
      _cancelTokens[ep.id] = cancelToken;
      await _setStatus(ep.id, DownloadStatus.pending);
      unawaited(_runDownload(ep.id, ep.audioUrl, cancelToken, null));
    }
  }

  // Deletes downloaded audio files and resets status for played episodes
  // whose playedAt timestamp is older than [days] days.
  Future<void> applyDownloadRetention(int days) async {
    final cutoff = DateTime.now().toUtc().subtract(Duration(days: days));
    final expired =
        await (_db.select(_db.episodes)..where(
              (e) =>
                  e.downloadStatus.equals(DownloadStatus.downloaded.name) &
                  e.playedAt.isSmallerThanValue(cutoff),
            ))
            .get();

    for (final ep in expired) {
      if (ep.downloadPath case final path?) {
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
      await (_db.update(_db.episodes)..where((e) => e.id.equals(ep.id))).write(
        const EpisodesCompanion(
          downloadStatus: Value(DownloadStatus.none),
          downloadPath: Value(null),
        ),
      );
      _log.fine('Retention purge: deleted download for episode ${ep.id}');
    }

    if (expired.isNotEmpty) {
      _log.info('Retention purge complete — ${expired.length} files removed');
    }
  }

  Future<void> downloadRecentEpisodes(int podcastId, int count) async {
    final episodes =
        await (_db.select(_db.episodes)
              ..where((e) => e.podcastId.equals(podcastId))
              ..orderBy([(e) => OrderingTerm.desc(e.pubDate)])
              ..limit(count))
            .get();

    for (final ep in episodes) {
      if (ep.downloadStatus == DownloadStatus.downloaded ||
          ep.downloadStatus == DownloadStatus.downloading ||
          ep.downloadStatus == DownloadStatus.pending) {
        continue;
      }
      if (!await _isWifiAvailable()) {
        _log.info('Batch download stopped — not on Wi-Fi');
        return;
      }
      final cancelToken = CancelToken();
      _cancelTokens[ep.id] = cancelToken;
      await _setStatus(ep.id, DownloadStatus.pending);
      await _runDownload(ep.id, ep.audioUrl, cancelToken, null);
    }
  }

  Future<bool> _isWifiAvailable() async {
    final wifiOnly = await _settings.isWifiOnlyDownloads();
    if (!wifiOnly) return true;
    final result = await Connectivity().checkConnectivity();
    return result.contains(ConnectivityResult.wifi);
  }

  Future<void> _setStatus(int episodeId, DownloadStatus status) async {
    await (_db.update(_db.episodes)..where((e) => e.id.equals(episodeId)))
        .write(EpisodesCompanion(downloadStatus: Value(status)));
  }

  Future<File> _destinationFile(int episodeId, String url) async {
    final dir = await getApplicationDocumentsDirectory();
    final downloadsDir = Directory(p.join(dir.path, 'downloads'));
    await downloadsDir.create(recursive: true);
    final ext = p.extension(Uri.parse(url).path).split('?').first;
    return File(p.join(downloadsDir.path, 'ep_$episodeId$ext'));
  }
}
