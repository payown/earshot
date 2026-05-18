import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/core_providers.dart';
import '../../../../features/subscriptions/domain/episode.dart';
import '../../data/audio_handler.dart';
import '../../data/queue_repository.dart';
import '../../data/queue_repository_impl.dart';

// Overridden in main() after AudioService.init completes.
final audioHandlerProvider = Provider<EarshotAudioHandler>(
  (_) => throw UnimplementedError('audioHandlerProvider not initialized'),
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
