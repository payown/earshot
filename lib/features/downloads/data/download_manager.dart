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

  Future<DownloadStartResult> downloadEpisode(int episodeId) async {
    final row = await (_db.select(
      _db.episodes,
    )..where((e) => e.id.equals(episodeId))).getSingleOrNull();

    if (row == null) return DownloadStartResult.notFound;
    if (row.downloadStatus == DownloadStatus.downloaded) {
      return DownloadStartResult.alreadyDownloaded;
    }
    if (row.downloadStatus == DownloadStatus.downloading) {
      return DownloadStartResult.alreadyDownloading;
    }

    if (!await _isWifiAvailable()) {
      _log.info('Download skipped — not on Wi-Fi');
      return DownloadStartResult.skippedNoWifi;
    }

    await _setStatus(episodeId, DownloadStatus.pending);

    final file = await _destinationFile(episodeId, row.audioUrl);
    final cancelToken = CancelToken();
    _cancelTokens[episodeId] = cancelToken;

    try {
      await _setStatus(episodeId, DownloadStatus.downloading);
      await _dio.download(
        row.audioUrl,
        file.path,
        cancelToken: cancelToken,
      );
      await _db.transaction(() async {
        await _setStatus(episodeId, DownloadStatus.downloaded);
        await (_db.update(_db.episodes)..where((e) => e.id.equals(episodeId)))
            .write(EpisodesCompanion(downloadPath: Value(file.path)));
      });
      _log.info('Downloaded episode $episodeId to ${file.path}');
      return DownloadStartResult.started;
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        _log.fine('Download cancelled for episode $episodeId');
        if (await file.exists()) await file.delete();
        await _setStatus(episodeId, DownloadStatus.none);
        return DownloadStartResult.started;
      }
      _log.warning('Download failed for episode $episodeId: ${e.message}');
      await _setStatus(episodeId, DownloadStatus.failed);
      return DownloadStartResult.failed;
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

  Future<void> downloadRecentEpisodes(int podcastId, int count) async {
    final episodes =
        await (_db.select(_db.episodes)
              ..where((e) => e.podcastId.equals(podcastId))
              ..orderBy([(e) => OrderingTerm.desc(e.pubDate)])
              ..limit(count))
            .get();

    for (final ep in episodes) {
      await downloadEpisode(ep.id);
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
