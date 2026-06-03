import 'package:dio/dio.dart';
import 'package:logging/logging.dart';
import 'package:workmanager/workmanager.dart';

import '../../data/db/app_database.dart';
import '../../data/rss/rss_parser.dart';
import '../../features/downloads/data/download_manager.dart';
import '../../features/settings/data/app_settings_repository.dart';
import '../../features/subscriptions/data/podcast_repository_impl.dart';

const _refreshFeedsTask = 'media.payown.earshot.refreshFeeds';
const _downloadEpisodesTask = 'media.payown.earshot.downloadEpisodes';

final _log = Logger('BackgroundTasks');

/// Must be a top-level function; workmanager spins up a separate Flutter engine.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, _) async {
    switch (taskName) {
      case _refreshFeedsTask:
        return _runFeedRefresh();
      case _downloadEpisodesTask:
        return _runEpisodeDownloads();
      default:
        _log.warning('Unknown background task: $taskName');
        return false;
    }
  });
}

Future<bool> _runFeedRefresh() async {
  final db = AppDatabase();
  try {
    final repo = PodcastRepositoryImpl(
      database: db,
      dio: _buildDio(),
      rssParser: RssParser(),
      settings: AppSettingsRepositoryImpl(database: db),
    );
    await repo.refreshAllFeeds();
    return true;
  } catch (e, st) {
    _log.severe('Feed refresh background task failed', e, st);
    return false;
  } finally {
    await db.close();
  }
}

Future<bool> _runEpisodeDownloads() async {
  final db = AppDatabase();
  try {
    final settings = AppSettingsRepositoryImpl(database: db);
    final manager = DownloadManager(
      database: db,
      settings: settings,
    );

    // Per-podcast auto-queue downloads (existing behaviour).
    final downloadCount = await settings.getAutoDownloadCount();
    final autoQueuePodcasts = await (db.select(
      db.podcasts,
    )..where((p) => p.autoQueue.equals(true))).get();
    for (final podcast in autoQueuePodcasts) {
      await manager.downloadRecentEpisodes(podcast.id, downloadCount);
    }

    // Inbox and Queue auto-download.
    if (await settings.isAutoDownloadInbox()) {
      await manager.downloadInboxEpisodes();
    }
    if (await settings.isAutoDownloadQueue()) {
      await manager.downloadQueueEpisodes();
    }

    // Download retention cleanup.
    final retentionDays = await settings.getDownloadRetentionDays();
    if (retentionDays != null) {
      await manager.applyDownloadRetention(retentionDays);
    }

    return true;
  } catch (e, st) {
    _log.severe('Episode download background task failed', e, st);
    return false;
  } finally {
    await db.close();
  }
}

Dio _buildDio() => Dio(
  BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
  ),
);

class BackgroundTaskService {
  const BackgroundTaskService._();

  static Future<void> initialize() async {
    await Workmanager().initialize(callbackDispatcher);
  }

  static Future<void> scheduleAll() async {
    await Workmanager().registerPeriodicTask(
      _refreshFeedsTask,
      _refreshFeedsTask,
      frequency: const Duration(hours: 6),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );

    await Workmanager().registerPeriodicTask(
      _downloadEpisodesTask,
      _downloadEpisodesTask,
      frequency: const Duration(hours: 12),
      constraints: Constraints(
        networkType: NetworkType.connected,
        requiresDeviceIdle: true,
      ),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  }
}
