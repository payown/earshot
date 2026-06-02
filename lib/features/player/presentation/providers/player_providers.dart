import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
      },
    ),
    resumePositionSeconds: episode.positionSeconds,
  );
});

final queueAutoAdvanceProvider = Provider<void>((ref) {
  final handler = ref.read(audioHandlerProvider);
  final queueRepo = ref.read(queueRepositoryProvider);

  handler.onEpisodeCompleted = () async {
    final queue = await queueRepo.watchQueue().first;
    if (queue.isEmpty) {
      await handler.stop();
      return;
    }
    final next = queue.first;
    await queueRepo.removeFromQueue(next.id);
    final db = ref.read(appDatabaseProvider);
    final nextPodcast = await (db.select(
      db.podcasts,
    )..where((p) => p.id.equals(next.podcastId))).getSingleOrNull();
    await handler.playEpisode(
      MediaItem(
        id: next.audioUrl,
        title: nextPodcast?.title ?? next.title,
        artist: next.title,
        album: nextPodcast?.title,
        artUri: next.artworkUrl != null ? Uri.tryParse(next.artworkUrl!) : null,
        duration: next.durationSeconds != null
            ? Duration(seconds: next.durationSeconds!)
            : null,
        extras: {
          'episodeId': next.id,
          'podcastId': next.podcastId,
          if (nextPodcast?.speedOverride != null)
            'speedOverride': nextPodcast!.speedOverride!,
        },
      ),
      resumePositionSeconds: next.positionSeconds,
    );
  };

  ref.onDispose(() => handler.onEpisodeCompleted = null);
});
