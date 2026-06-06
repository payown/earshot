import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/playback.dart';
import '../../../../core/providers/core_providers.dart';
import '../../../../data/db/enums.dart';
import '../../../../features/settings/data/app_settings_repository.dart';
import '../../../../features/subscriptions/domain/episode.dart';
import '../../../subscriptions/presentation/providers/subscriptions_providers.dart';
import '../../domain/queue_group.dart';
import '../../data/audio_handler.dart';
import '../../data/position_tracker.dart';
import '../../data/queue_repository.dart';
import '../../data/queue_repository_impl.dart';
import '../../domain/sleep_timer.dart';

// Overridden in main() after AudioService.init completes.
final audioHandlerProvider = Provider<EarshotAudioHandler>(
  (_) => throw UnimplementedError('audioHandlerProvider not initialized'),
);

final positionTrackerProvider = Provider<PositionTracker>(
  (ref) {
    final tracker = PositionTracker(database: ref.watch(appDatabaseProvider));
    final handler = ref.watch(audioHandlerProvider);
    tracker.attach(handler.playbackState, handler.episodeIdStream);
    ref.onDispose(tracker.dispose);
    return tracker;
  },
);

final playbackStateProvider = StreamProvider<PlaybackState>(
  (ref) => ref.watch(audioHandlerProvider).playbackState,
);

final mediaItemProvider = StreamProvider<MediaItem?>(
  (ref) => ref.watch(audioHandlerProvider).mediaItem,
);

final positionProvider = StreamProvider<Duration>(
  (ref) => ref.watch(audioHandlerProvider).positionStream,
);

final queueRepositoryProvider = Provider<QueueRepository>(
  (ref) => QueueRepositoryImpl(database: ref.watch(appDatabaseProvider)),
);

final queueProvider = StreamProvider<List<Episode>>(
  (ref) => ref.watch(queueRepositoryProvider).watchQueue(),
);

// Session-only set of podcast IDs whose queue groups are collapsed. Default
// is empty — every group expanded — so the queue looks unchanged the first
// time grouping is enabled. Not persisted; resets on app restart.
class CollapsedQueueGroupsNotifier extends Notifier<Set<int>> {
  @override
  Set<int> build() => <int>{};

  void toggle(int podcastId) {
    final next = {...state};
    if (next.contains(podcastId)) {
      next.remove(podcastId);
    } else {
      next.add(podcastId);
    }
    state = next;
  }
}

final collapsedQueueGroupsProvider =
    NotifierProvider<CollapsedQueueGroupsNotifier, Set<int>>(
      CollapsedQueueGroupsNotifier.new,
    );

// Tracks the podcast ID of the group being played via "Play Group". Null means
// no group context — normal queue playback. Cleared when the group boundary is
// crossed (whether playback stops or continues past the group).
class ActiveGroupNotifier extends Notifier<int?> {
  @override
  int? build() => null;

  void set(int? podcastId) => state = podcastId;
}

final activeGroupPodcastIdProvider =
    NotifierProvider<ActiveGroupNotifier, int?>(ActiveGroupNotifier.new);

final groupedQueueProvider = Provider<AsyncValue<List<QueueGroup>>>((ref) {
  final episodes = ref.watch(queueProvider);
  final subs = ref.watch(subscriptionsProvider);

  return episodes.whenData((eps) {
    final pods = subs.asData?.value;
    final podcastTitles = <int, String>{
      if (pods != null)
        for (final p in pods) p.id: p.title,
    };
    final groups = <int, List<Episode>>{};
    final groupOrder = <int>[];
    for (final ep in eps) {
      if (!groups.containsKey(ep.podcastId)) {
        groups[ep.podcastId] = [];
        groupOrder.add(ep.podcastId);
      }
      groups[ep.podcastId]!.add(ep);
    }
    return groupOrder
        .map(
          (id) => QueueGroup(
            podcastId: id,
            podcastName: podcastTitles[id] ?? 'Unknown podcast',
            episodes: groups[id]!,
          ),
        )
        .toList();
  });
});

final sleepTimerStateProvider = StreamProvider<SleepTimerState>(
  (ref) => ref.watch(audioHandlerProvider).sleepTimer.stateStream,
);

// ── Audio enhancement settings ────────────────────────────────────────────────

class _AudioSettingNotifier extends AsyncNotifier<bool> {
  _AudioSettingNotifier({
    required Future<bool> Function(AppSettingsRepositoryImpl) read,
    required Future<void> Function(AppSettingsRepositoryImpl, bool) write,
  }) : _read = read,
       _write = write;

  final Future<bool> Function(AppSettingsRepositoryImpl) _read;
  final Future<void> Function(AppSettingsRepositoryImpl, bool) _write;

  @override
  Future<bool> build() async {
    final db = ref.watch(appDatabaseProvider);
    return _read(AppSettingsRepositoryImpl(database: db));
  }

  Future<void> set(bool value) async {
    state = AsyncData(value);
    final db = ref.read(appDatabaseProvider);
    await _write(AppSettingsRepositoryImpl(database: db), value);
  }
}

class _GlobalSpeedNotifier extends AsyncNotifier<double> {
  @override
  Future<double> build() async {
    final db = ref.watch(appDatabaseProvider);
    return AppSettingsRepositoryImpl(database: db).getGlobalSpeed();
  }

  Future<void> set(double speed) async {
    state = AsyncData(speed);
    final db = ref.read(appDatabaseProvider);
    await AppSettingsRepositoryImpl(database: db).setGlobalSpeed(speed);
  }
}

final globalSpeedProvider = AsyncNotifierProvider<_GlobalSpeedNotifier, double>(
  _GlobalSpeedNotifier.new,
);

final skipSilenceProvider = AsyncNotifierProvider<_AudioSettingNotifier, bool>(
  () => _AudioSettingNotifier(
    read: (r) => r.isSkipSilenceEnabled(),
    write: (r, v) => r.setSkipSilenceEnabled(enabled: v),
  ),
);

final voiceEnhanceProvider = AsyncNotifierProvider<_AudioSettingNotifier, bool>(
  () => _AudioSettingNotifier(
    read: (r) => r.isVoiceEnhanceEnabled(),
    write: (r, v) => r.setVoiceEnhanceEnabled(enabled: v),
  ),
);

final directTouchEnabledProvider =
    AsyncNotifierProvider<_AudioSettingNotifier, bool>(
      () => _AudioSettingNotifier(
        read: (r) => r.getDirectTouchEnabled(),
        write: (r, v) => r.setDirectTouchEnabled(v),
      ),
    );

final currentEpisodeDescriptionProvider = StreamProvider<String?>((ref) {
  final episodeId =
      ref.watch(mediaItemProvider).asData?.value?.extras?['episodeId'] as int?;
  if (episodeId == null) return Stream.value(null);
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.episodes)..where((e) => e.id.equals(episodeId)))
      .watchSingleOrNull()
      .map((row) => row?.description);
});

// Attaches AppSettingsRepository to the audio handler as soon as the DB is
// available so _applyPlaybackSettings can read global speed + trim silence
// without needing those values in every MediaItem's extras.
final handlerSettingsAttachmentProvider = Provider<void>((ref) {
  final handler = ref.read(audioHandlerProvider);
  final db = ref.watch(appDatabaseProvider);
  handler.attachSettings(AppSettingsRepositoryImpl(database: db));
});

// Watches episodeIdStream and persists the current episode ID so it can be
// restored after a force quit.
final episodeIdPersistenceProvider = Provider<void>((ref) {
  final handler = ref.read(audioHandlerProvider);
  final db = ref.read(appDatabaseProvider);
  final settings = AppSettingsRepositoryImpl(database: db);

  final sub = handler.episodeIdStream.listen((id) {
    unawaited(settings.setLastPlayingEpisodeId(id));
  });

  ref.onDispose(sub.cancel);
});

// Runs once on cold start. Reads the last playing episode from app_settings,
// fetches its episode + podcast rows, and calls loadEpisode() so the mini
// player reappears paused at the saved position.
final playbackRestorationProvider = FutureProvider<void>((ref) async {
  final db = ref.read(appDatabaseProvider);
  final settings = AppSettingsRepositoryImpl(database: db);

  final lastEpisodeId = await settings.getLastPlayingEpisodeId();
  if (lastEpisodeId == null) return;

  final episode = await (db.select(
    db.episodes,
  )..where((e) => e.id.equals(lastEpisodeId))).getSingleOrNull();

  if (episode == null || episode.status == EpisodeStatus.played) return;

  final podcast = await (db.select(
    db.podcasts,
  )..where((p) => p.id.equals(episode.podcastId))).getSingleOrNull();

  final handler = ref.read(audioHandlerProvider);
  await handler.loadEpisode(
    MediaItem(
      id: episode.audioUrl,
      title: podcast?.title ?? episode.title,
      artist: episode.title,
      album: podcast?.title,
      artUri: podcast?.artworkUrl != null
          ? Uri.tryParse(podcast!.artworkUrl!)
          : null,
      duration: episode.durationSeconds != null
          ? Duration(seconds: episode.durationSeconds!)
          : null,
      extras: {
        'episodeId': episode.id,
        'podcastId': episode.podcastId,
        if (podcast?.speedOverride != null)
          'speedOverride': podcast!.speedOverride!,
        if (podcast?.trimSilenceOverride != null)
          'trimSilenceOverride': podcast!.trimSilenceOverride!,
        if (episode.downloadPath != null) 'downloadPath': episode.downloadPath!,
      },
    ),
    resumePositionSeconds: episode.positionSeconds,
  );
});

final queueAutoAdvanceProvider = Provider<void>((ref) {
  final handler = ref.read(audioHandlerProvider);
  final queueRepo = ref.read(queueRepositoryProvider);

  // Prevents the position listener from queuing redundant preload calls when
  // the advance handler has already preloaded the next item.
  var preloadScheduled = false;

  MediaItem _buildMediaItem({
    required Episode episode,
    required String? podcastTitle,
    required Uri? artUri,
    required double? speedOverride,
    required bool? trimSilenceOverride,
  }) {
    return MediaItem(
      id: episode.audioUrl,
      title: podcastTitle ?? episode.title,
      artist: episode.title,
      album: podcastTitle,
      artUri: artUri,
      duration: episode.durationSeconds != null
          ? Duration(seconds: episode.durationSeconds!)
          : null,
      extras: {
        'episodeId': episode.id,
        'podcastId': episode.podcastId,
        if (speedOverride != null) 'speedOverride': speedOverride,
        if (trimSilenceOverride != null)
          'trimSilenceOverride': trimSilenceOverride,
        if (episode.downloadPath != null) 'downloadPath': episode.downloadPath!,
      },
    );
  }

  Future<void> preloadNextEpisode() async {
    final db = ref.read(appDatabaseProvider);
    final queue = await queueRepo.watchQueue().first;
    if (queue.length < 2) {
      preloadScheduled = false;
      return;
    }
    final next = queue[1];
    final podcast = await (db.select(
      db.podcasts,
    )..where((p) => p.id.equals(next.podcastId))).getSingleOrNull();
    await handler.preloadNext(
      _buildMediaItem(
        episode: next,
        podcastTitle: podcast?.title,
        artUri: next.artworkUrl != null ? Uri.tryParse(next.artworkUrl!) : null,
        speedOverride: podcast?.speedOverride,
        trimSilenceOverride: podcast?.trimSilenceOverride,
      ),
    );
  }

  Future<bool> checkGroupBoundary(
    List<Episode> updatedQueue,
    AppSettingsRepositoryImpl settingsRepo,
  ) async {
    final activeGroupPodcastId = ref.read<int?>(activeGroupPodcastIdProvider);
    if (activeGroupPodcastId == null) return false;
    final groupEnded =
        updatedQueue.isEmpty ||
        updatedQueue.first.podcastId != activeGroupPodcastId;
    if (!groupEnded) return false;
    ref
        .read<ActiveGroupNotifier>(activeGroupPodcastIdProvider.notifier)
        .set(null);
    final continueAfterGroup = await settingsRepo.isContinueAfterGroupEnds();
    if (!continueAfterGroup) {
      await handler.stop();
      return true;
    }
    return false;
  }

  // Watches position and preloads the next queue episode when within
  // kGaplessPreloadThreshold of the end, enabling gapless transitions.
  final positionSub = handler.positionStream.listen((position) async {
    if (preloadScheduled) return;
    final duration = handler.mediaItem.value?.duration;
    if (duration == null) return;
    if (!shouldPreload(position, duration, kGaplessPreloadThreshold)) return;

    // Set flag synchronously before any await so concurrent position events
    // don't race in and schedule duplicate preloads.
    preloadScheduled = true;

    final db = ref.read(appDatabaseProvider);
    final settingsRepo = AppSettingsRepositoryImpl(database: db);
    final gaplessEnabled = await settingsRepo.isGaplessPlaybackEnabled();
    if (!gaplessEnabled) {
      preloadScheduled = false;
      return;
    }

    unawaited(preloadNextEpisode());
  });

  // Called by the audio handler when a gapless transition occurs mid-playlist.
  // Handles bookkeeping: remove completed episode, check group boundary,
  // and preload the next-next episode to keep the gapless chain going.
  handler.onEpisodeAdvanced = (int? previousEpisodeId) async {
    preloadScheduled = false;

    if (previousEpisodeId != null) {
      await queueRepo.removeFromQueue(previousEpisodeId);
    }

    final db = ref.read(appDatabaseProvider);
    final settingsRepo = AppSettingsRepositoryImpl(database: db);
    final updatedQueue = await queueRepo.watchQueue().first;

    final stopped = await checkGroupBoundary(updatedQueue, settingsRepo);
    if (stopped) return;

    // Preload the episode after the new current so the chain stays warm.
    if (updatedQueue.length > 1) {
      preloadScheduled = true;
      unawaited(preloadNextEpisode());
    }
  };

  // Called when the last episode in the playlist finishes (no preloaded next).
  handler.onEpisodeCompleted = () async {
    preloadScheduled = false;

    final db = ref.read(appDatabaseProvider);
    final settingsRepo = AppSettingsRepositoryImpl(database: db);
    final continueAfterQueue = await settingsRepo.isContinueAfterQueue();

    // Read queue BEFORE removing the completed episode so currentIndex is
    // accurate.
    final queue = await queueRepo.watchQueue().first;
    final currentEpisodeId =
        handler.mediaItem.value?.extras?['episodeId'] as int?;
    final currentIndex = currentEpisodeId != null
        ? queue.indexWhere((e) => e.id == currentEpisodeId)
        : -1;

    if (currentEpisodeId != null) {
      await queueRepo.removeFromQueue(currentEpisodeId);
    }

    final remaining = currentIndex >= 0 ? queue.length - 1 : queue.length;

    final updatedQueue = await queueRepo.watchQueue().first;

    final stopped = await checkGroupBoundary(updatedQueue, settingsRepo);
    if (stopped) return;

    if (remaining == 0 || currentIndex >= queue.length - 1) {
      if (!continueAfterQueue) {
        await handler.stop();
        return;
      }
    }

    if (updatedQueue.isEmpty) {
      await handler.stop();
      return;
    }

    final next = updatedQueue.first;
    final nextPodcast = await (db.select(
      db.podcasts,
    )..where((p) => p.id.equals(next.podcastId))).getSingleOrNull();
    await handler.playEpisode(
      _buildMediaItem(
        episode: next,
        podcastTitle: nextPodcast?.title,
        artUri: next.artworkUrl != null ? Uri.tryParse(next.artworkUrl!) : null,
        speedOverride: nextPodcast?.speedOverride,
        trimSilenceOverride: nextPodcast?.trimSilenceOverride,
      ),
      resumePositionSeconds: next.positionSeconds,
    );
  };

  ref.onDispose(() {
    unawaited(positionSub.cancel());
    handler.onEpisodeCompleted = null;
    handler.onEpisodeAdvanced = null;
  });
});
