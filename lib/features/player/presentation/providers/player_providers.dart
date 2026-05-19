import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/core_providers.dart';
import '../../../../features/subscriptions/domain/episode.dart';
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

final sleepTimerStateProvider = StreamProvider<SleepTimerState>(
  (ref) => ref.watch(audioHandlerProvider).sleepTimer.stateStream,
);

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
    await handler.playEpisode(
      MediaItem(
        id: next.audioUrl,
        title: next.title,
        artUri: next.artworkUrl != null ? Uri.tryParse(next.artworkUrl!) : null,
        duration: next.durationSeconds != null
            ? Duration(seconds: next.durationSeconds!)
            : null,
        extras: {'episodeId': next.id},
      ),
      resumePositionSeconds: next.positionSeconds,
    );
  };

  ref.onDispose(() => handler.onEpisodeCompleted = null);
});
