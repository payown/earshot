import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../../../core/constants/playback.dart';
import '../../../../core/providers/core_providers.dart';
import '../../../../features/settings/data/app_settings_repository.dart';
import '../../../../features/settings/presentation/providers/settings_providers.dart';
import '../../../../features/subscriptions/domain/episode.dart';
import '../../../subscriptions/presentation/providers/subscriptions_providers.dart';
import '../../domain/queue_group.dart';
import '../../data/audio_handler.dart';
import '../../data/position_tracker.dart';
import '../../data/queue_repository.dart';
import '../../data/queue_repository_impl.dart';
import '../../domain/resume_position.dart';
import '../../domain/sleep_timer.dart';

final _log = Logger('PlayerProviders');

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

// Whether the one-off "Stop after this episode" toggle is on. In-memory only;
// resets when the next episode completes or the app restarts.
final stopAfterCurrentEpisodeProvider = StreamProvider<bool>(
  (ref) => ref.watch(audioHandlerProvider).stopAfterCurrentEpisodeStream,
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
  handler.attachDatabase(db);
});

// Watches skip interval settings and syncs them to the audio handler so
// AirPods clicks and lock screen controls use the user's chosen durations.
final skipDurationsAttachmentProvider = Provider<void>((ref) {
  final handler = ref.read(audioHandlerProvider);
  final forwardSecs = ref.watch(skipForwardSecondsProvider).asData?.value ?? 30;
  final backSecs = ref.watch(skipBackSecondsProvider).asData?.value ?? 15;
  handler.setSkipDurations(
    forward: Duration(seconds: forwardSecs),
    back: Duration(seconds: backSecs),
  );
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
  try {
    final db = ref.read(appDatabaseProvider);
    final settings = AppSettingsRepositoryImpl(database: db);

    final lastEpisodeId = await settings.getLastPlayingEpisodeId();
    if (lastEpisodeId == null) return;

    final episode = await (db.select(
      db.episodes,
    )..where((e) => e.id.equals(lastEpisodeId))).getSingleOrNull();

    if (episode == null) return;
    if (!shouldRestoreLastPlaying(
      status: episode.status,
      positionSeconds: episode.positionSeconds,
    )) {
      return;
    }

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
          if (episode.downloadPath != null)
            'downloadPath': episode.downloadPath!,
        },
      ),
      resumePositionSeconds: clampedResumePosition(
        positionSeconds: episode.positionSeconds,
        durationSeconds: episode.durationSeconds,
      ),
    );
  } catch (error, stackTrace) {
    _log.severe('Failed to restore last playing episode', error, stackTrace);
    await Sentry.captureException(error, stackTrace: stackTrace);
  }
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

  // Index of the currently-playing episode in [queue], or -1 if not present.
  int currentIndexIn(List<Episode> queue) {
    final id = handler.mediaItem.value?.extras?['episodeId'] as int?;
    if (id == null) return -1;
    return queue.indexWhere((e) => e.id == id);
  }

  Future<void> preloadNextEpisode() async {
    try {
      final db = ref.read(appDatabaseProvider);
      final queue = await queueRepo.watchQueue().first;
      // Preload the item that follows the CURRENT episode in true order (not the
      // queue head), so gapless works when playing from a mid-queue position.
      final i = currentIndexIn(queue);
      if (i < 0 || i + 1 >= queue.length) {
        // Leave preloadScheduled = true. No next episode exists, so there's
        // nothing to preload. Resetting to false would cause positionSub to
        // re-enter on every ~200ms tick for the rest of the episode — a hot
        // DB-read loop that pegs the CPU. onEpisodeAdvanced/Completed will
        // reset the flag when the episode actually finishes.
        return;
      }
      final next = queue[i + 1];
      final podcast = await (db.select(
        db.podcasts,
      )..where((p) => p.id.equals(next.podcastId))).getSingleOrNull();
      await handler.preloadNext(
        _buildMediaItem(
          episode: next,
          podcastTitle: podcast?.title,
          artUri: next.artworkUrl != null
              ? Uri.tryParse(next.artworkUrl!)
              : null,
          speedOverride: podcast?.speedOverride,
          trimSilenceOverride: podcast?.trimSilenceOverride,
        ),
      );
    } catch (e, st) {
      _log.warning('Gapless preload failed', e, st);
      unawaited(Sentry.captureException(e, stackTrace: st));
    }
  }

  // Loads and plays [next], resuming from its saved position.
  Future<void> playNext(Episode next) async {
    final db = ref.read(appDatabaseProvider);
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
      resumePositionSeconds: clampedResumePosition(
        positionSeconds: next.positionSeconds,
        durationSeconds: next.durationSeconds,
      ),
    );
  }

  // Watches position and preloads the next queue episode when within
  // kGaplessPreloadThreshold of the end, enabling gapless transitions.
  final positionSub = handler.positionStream.listen(
    (position) async {
      try {
        if (preloadScheduled) return;
        final duration = handler.mediaItem.value?.duration;
        if (duration == null) return;
        if (!shouldPreload(position, duration, kGaplessPreloadThreshold))
          return;

        // Set flag synchronously before any await so concurrent position events
        // don't race in and schedule duplicate preloads.
        preloadScheduled = true;

        final db = ref.read(appDatabaseProvider);
        final settingsRepo = AppSettingsRepositoryImpl(database: db);
        final gaplessEnabled = await settingsRepo.isGaplessPlaybackEnabled();
        if (!gaplessEnabled) {
          // Leave preloadScheduled = true. Gapless is disabled, so we'll never
          // preload for this episode. Same reasoning as preloadNextEpisode above.
          return;
        }

        // Only gapless-preload when group continuation is on and no stop is
        // pending. Otherwise the completion needs a boundary/stop decision, so
        // route it through onEpisodeCompleted (no gapless advance) instead.
        final continueAfterGroup = await settingsRepo
            .isContinueAfterGroupEnds();
        if (handler.stopAfterCurrentEpisode || !continueAfterGroup) {
          return;
        }

        unawaited(preloadNextEpisode());
      } catch (e, st) {
        _log.warning('positionSub listener error', e, st);
        unawaited(Sentry.captureException(e, stackTrace: st));
      }
    },
    onError: (Object e, StackTrace st) {
      // onError handles errors emitted by positionStream itself (not async
      // listener throws — those are caught by the try/catch above). Providing
      // onError here also prevents stream errors from escaping to the root zone,
      // so we must capture to Sentry explicitly.
      _log.warning('positionSub stream error', e, st);
      unawaited(Sentry.captureException(e, stackTrace: st));
    },
  );

  // Called by the audio handler when a gapless transition occurs mid-playlist.
  // Gapless only runs when group continuation is on (see the positionSub gate),
  // so there is never a boundary stop to make here — just remove the finished
  // episode and keep the chain warm.
  handler.onEpisodeAdvanced = (int? previousEpisodeId) async {
    preloadScheduled = false;

    if (previousEpisodeId != null) {
      await queueRepo.markPlayedAndRemove(previousEpisodeId);
    }

    final updatedQueue = await queueRepo.watchQueue().first;

    // Preload the episode after the new current so the chain stays warm.
    if (currentIndexIn(updatedQueue) + 1 < updatedQueue.length) {
      preloadScheduled = true;
      unawaited(preloadNextEpisode());
    }
  };

  // Called when the current episode finishes with no preloaded gapless next.
  // [stopAfter] is true when the one-off "Stop after this episode" toggle or the
  // sleep timer's end-of-episode mode was active.
  handler.onEpisodeCompleted = ({required bool stopAfter}) async {
    preloadScheduled = false;

    final settingsRepo = AppSettingsRepositoryImpl(
      database: ref.read(appDatabaseProvider),
    );

    // Read the queue BEFORE removing the completed episode so its index and
    // podcast are accurate.
    final queue = await queueRepo.watchQueue().first;
    final currentEpisodeId =
        handler.mediaItem.value?.extras?['episodeId'] as int?;
    final currentIndex = currentEpisodeId != null
        ? queue.indexWhere((e) => e.id == currentEpisodeId)
        : -1;
    final completedPodcastId = currentIndex >= 0
        ? queue[currentIndex].podcastId
        : null;

    if (currentEpisodeId != null) {
      await queueRepo.markPlayedAndRemove(currentEpisodeId);
    }

    // Stop after this episode (one-off toggle / sleep timer end-of-episode).
    if (stopAfter) {
      await handler.stop();
      return;
    }

    final continueAfterQueue = await settingsRepo.isContinueAfterQueue();
    final continueAfterGroup = await settingsRepo.isContinueAfterGroupEnds();

    // Both switches off → stop after the current episode (no auto-advance).
    if (!continueAfterQueue && !continueAfterGroup) {
      await handler.stop();
      return;
    }

    final updatedQueue = await queueRepo.watchQueue().first;

    // Advance to the item that FOLLOWED the completed one in true order. After
    // removal, that item now sits at currentIndex.
    final hasNext = currentIndex >= 0 && currentIndex < updatedQueue.length;
    if (!hasNext) {
      // The completed episode was the last in true order (end of queue). Keep
      // playing only if the user opted to continue past the queue; then fall
      // back to whatever remains at the top.
      if (continueAfterQueue && updatedQueue.isNotEmpty) {
        await playNext(updatedQueue.first);
      } else {
        await handler.stop();
      }
      return;
    }

    final next = updatedQueue[currentIndex];

    if (nextEqualsCompleted(next.id, currentEpisodeId)) {
      // markPlayedAndRemove did not take effect (a concurrent gapless advance
      // already removed it). Stop rather than restart the same episode.
      _log.warning(
        'onEpisodeCompleted: next episode equals completed episode, stopping',
      );
      await handler.stop();
      return;
    }

    // Group boundary: the next item is a different podcast than the one that
    // just finished. Gated by "Continue after group ends".
    if (completedPodcastId != null &&
        next.podcastId != completedPodcastId &&
        !continueAfterGroup) {
      await handler.stop();
      return;
    }

    await playNext(next);
  };

  // Drop a stale gapless preload when the queue changes, so an episode that was
  // removed (or reordered out of the next slot) can't still play gaplessly
  // (#297). Clearing routes completion through onEpisodeCompleted, which
  // consults the live queue; positionSub re-preloads the correct next when near
  // the end again.
  final queueReconcileSub = queueRepo.watchQueue().listen((queue) {
    if (handler.isAdvancing) return;
    final stale = preloadedNextIsStale(
      preloadedNextEpisodeId: handler.preloadedNextEpisodeId,
      currentEpisodeId: handler.currentEpisodeId,
      queueEpisodeIds: queue.map((e) => e.id).toList(),
    );
    if (!stale) return;
    unawaited(handler.clearPreloadedNext());
    preloadScheduled = false;
  });

  ref.onDispose(() {
    unawaited(positionSub.cancel());
    unawaited(queueReconcileSub.cancel());
    handler.onEpisodeCompleted = null;
    handler.onEpisodeAdvanced = null;
  });
});
