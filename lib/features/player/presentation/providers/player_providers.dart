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
