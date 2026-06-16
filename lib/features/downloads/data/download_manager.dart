import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/utils/time_format.dart';
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
    required AppSettingsRepository settings,
  }) : _db = database,
       _settings = settings {
    _updateSubscription = FileDownloader().updates.listen(_onTaskUpdate);
    unawaited(_resetStuckDownloads());
  }

  final AppDatabase _db;
  final AppSettingsRepository _settings;
  StreamSubscription<TaskUpdate>? _updateSubscription;
  final _auditController = StreamController<String>.broadcast();

  Stream<String> get downloadAuditEvents => _auditController.stream;

  Future<void> dispose() async {
    await _updateSubscription?.cancel();
    _updateSubscription = null;
    await _auditController.close();
  }

  // Reconcile any rows left in downloading/pending from a previous session
  // (e.g. from the old dio-based approach or a crash) that have no
  // corresponding active task in background_downloader.
  Future<void> _resetStuckDownloads() async {
    final activeTasks = await FileDownloader().allTasks(allGroups: true);
    final activeIds = activeTasks.map((t) => t.taskId).toSet();
    final stuck =
        await (_db.select(_db.episodes)..where(
              (e) => e.downloadStatus.isIn([
                DownloadStatus.downloading.name,
                DownloadStatus.pending.name,
              ]),
            ))
            .get();
    for (final ep in stuck) {
      if (!activeIds.contains(_taskId(ep.id))) {
        await _setStatus(ep.id, DownloadStatus.failed);
        _log.fine('Reset stuck download for episode ${ep.id}');
      }
    }
  }

  Future<void> _onTaskUpdate(TaskUpdate update) async {
    if (update is! TaskStatusUpdate) return;
    final episodeId = _episodeIdFromTaskId(update.task.taskId);
    if (episodeId == null) return;

    switch (update.status) {
      case TaskStatus.complete:
        final path = await update.task.filePath();
        final episodeRow = await (_db.select(
          _db.episodes,
        )..where((e) => e.id.equals(episodeId))).getSingleOrNull();
        await _db.transaction(() async {
          await _setStatus(episodeId, DownloadStatus.downloaded);
          await (_db.update(_db.episodes)..where((e) => e.id.equals(episodeId)))
              .write(EpisodesCompanion(downloadPath: Value(path)));
        });
        _log.info('Downloaded episode $episodeId to $path');
        if (episodeRow != null) {
          _auditController.add(
            '${episodeRow.title} downloaded at ${formatTimeOfDay(DateTime.now())}',
          );
        }
      case TaskStatus.failed:
      case TaskStatus.notFound:
        await _setStatus(episodeId, DownloadStatus.failed);
        _log.warning(
          'Download failed for episode $episodeId: ${update.status}',
        );
      case TaskStatus.canceled:
        final file = await _destinationFile(episodeId, update.task.url);
        if (await file.exists()) await file.delete();
        await _setStatus(episodeId, DownloadStatus.none);
      case TaskStatus.running:
        await _setStatus(episodeId, DownloadStatus.downloading);
      case TaskStatus.enqueued:
        await _setStatus(episodeId, DownloadStatus.pending);
      default:
        break;
    }
  }

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

    final file = await _destinationFile(episodeId, row.audioUrl);
    final ext = p.extension(file.path);
    final task = DownloadTask(
      url: row.audioUrl,
      taskId: _taskId(episodeId),
      baseDirectory: BaseDirectory.applicationDocuments,
      directory: 'downloads',
      filename: 'ep_$episodeId$ext',
      updates: Updates.status,
    );

    final enqueued = await FileDownloader().enqueue(task);
    if (!enqueued) {
      _log.warning('Failed to enqueue download for episode $episodeId');
      return DownloadStartResult.failed;
    }

    _log.info('Enqueued background download for episode $episodeId');
    return DownloadStartResult.started;
  }

  Future<void> cancelDownload(int episodeId) async {
    await FileDownloader().cancelTaskWithId(_taskId(episodeId));
  }

  Future<void> deleteDownload(int episodeId) async {
    await FileDownloader().cancelTaskWithId(_taskId(episodeId));

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

  /// Copies the downloaded audio for [episodeId] into the temp directory under a
  /// human-readable name (`<Podcast> - <Title><ext>`) and returns that file,
  /// ready to hand to the OS share sheet.
  ///
  /// Returns null if the episode isn't downloaded or the file is missing. The
  /// copy is required because `share_plus` shares an on-disk file under its real
  /// basename; sharing the stored `ep_<id><ext>` file directly would surface
  /// that unfriendly name in "Save to Files".
  Future<File?> prepareExportFile(int episodeId) async {
    final ep = await (_db.select(
      _db.episodes,
    )..where((e) => e.id.equals(episodeId))).getSingleOrNull();

    if (ep == null || ep.downloadStatus != DownloadStatus.downloaded) {
      return null;
    }
    final path = ep.downloadPath;
    if (path == null) return null;

    final source = File(path);
    if (!await source.exists()) return null;

    final podcast = await (_db.select(
      _db.podcasts,
    )..where((p0) => p0.id.equals(ep.podcastId))).getSingleOrNull();

    final ext = p.extension(path); // real extension, e.g. .mp3 / .m4a
    final name = _sanitizeExportName(
      '${podcast?.title ?? 'Podcast'} - ${ep.title}',
    );
    final tmpDir = await getTemporaryDirectory();
    final dest = File(p.join(tmpDir.path, '$name$ext'));
    return source.copy(dest.path);
  }

  /// Strips filesystem-illegal and control characters, collapses whitespace,
  /// and caps length so the exported temp filename stays sane.
  String _sanitizeExportName(String raw) {
    final cleaned = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned.length > 120 ? cleaned.substring(0, 120).trim() : cleaned;
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
      await _enqueueEpisode(ep);
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
      await _enqueueEpisode(ep);
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
      await _enqueueEpisode(ep);
    }
  }

  Future<void> deleteAllDownloads() async {
    final episodes =
        await (_db.select(_db.episodes)..where(
              (e) => e.downloadStatus.equals(DownloadStatus.downloaded.name),
            ))
            .get();

    for (final ep in episodes) {
      await FileDownloader().cancelTaskWithId(_taskId(ep.id));
      if (ep.downloadPath case final path?) {
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
    }

    await (_db.update(_db.episodes)..where(
          (e) => e.downloadStatus.equals(DownloadStatus.downloaded.name),
        ))
        .write(
          const EpisodesCompanion(
            downloadStatus: Value(DownloadStatus.none),
            downloadPath: Value(null),
          ),
        );

    _log.info('Deleted all downloads (${episodes.length} episodes)');
  }

  // Deletes downloaded episodes whose pubDate is older than [days] days,
  // regardless of played status. Returns the number of episodes deleted.
  Future<int> deleteDownloadsOlderThan(int days) async {
    final cutoff = DateTime.now().toUtc().subtract(Duration(days: days));
    final episodes =
        await (_db.select(_db.episodes)..where(
              (e) =>
                  e.downloadStatus.equals(DownloadStatus.downloaded.name) &
                  e.pubDate.isSmallerThanValue(cutoff),
            ))
            .get();

    for (final ep in episodes) {
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
    }

    if (episodes.isNotEmpty) {
      _log.info('Deleted ${episodes.length} downloads older than $days days');
    }
    return episodes.length;
  }

  Future<int> getTotalDownloadBytes() async {
    final episodes =
        await (_db.select(_db.episodes)..where(
              (e) => e.downloadStatus.equals(DownloadStatus.downloaded.name),
            ))
            .get();

    var total = 0;
    for (final ep in episodes) {
      if (ep.downloadPath case final path?) {
        try {
          final stat = await File(path).stat();
          total += stat.size;
        } catch (_) {
          // File may be missing; skip it
        }
      }
    }
    return total;
  }

  // Deletes oldest-published episodes until total storage is under [maxBytes].
  Future<void> applyStorageCap(int maxBytes) async {
    var total = await getTotalDownloadBytes();
    if (total <= maxBytes) return;

    final episodes =
        await (_db.select(_db.episodes)
              ..where(
                (e) => e.downloadStatus.equals(DownloadStatus.downloaded.name),
              )
              ..orderBy([(e) => OrderingTerm.asc(e.pubDate)]))
            .get();

    for (final ep in episodes) {
      if (total <= maxBytes) break;
      var fileSize = 0;
      if (ep.downloadPath case final path?) {
        final file = File(path);
        if (await file.exists()) {
          try {
            fileSize = (await file.stat()).size;
            await file.delete();
          } catch (_) {}
        }
      }
      await (_db.update(_db.episodes)..where((e) => e.id.equals(ep.id))).write(
        const EpisodesCompanion(
          downloadStatus: Value(DownloadStatus.none),
          downloadPath: Value(null),
        ),
      );
      total -= fileSize;
      _log.fine('Storage cap: deleted download for episode ${ep.id}');
    }

    _log.info('Storage cap applied — ${total ~/ (1024 * 1024)} MB remaining');
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

  Future<void> _enqueueEpisode(EpisodeRow ep) async {
    final file = await _destinationFile(ep.id, ep.audioUrl);
    final ext = p.extension(file.path);
    final task = DownloadTask(
      url: ep.audioUrl,
      taskId: _taskId(ep.id),
      baseDirectory: BaseDirectory.applicationDocuments,
      directory: 'downloads',
      filename: 'ep_${ep.id}$ext',
      updates: Updates.status,
    );
    final enqueued = await FileDownloader().enqueue(task);
    if (!enqueued) {
      _log.warning('Failed to enqueue download for episode ${ep.id}');
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

  static String _taskId(int episodeId) => 'ep_$episodeId';

  static int? _episodeIdFromTaskId(String taskId) {
    if (!taskId.startsWith('ep_')) return null;
    return int.tryParse(taskId.substring(3));
  }
}
