import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/core_providers.dart';
import '../../data/quick_action_repository.dart';
import '../../data/quick_action_repository_impl.dart';
import '../../domain/quick_action_definition.dart';

final quickActionRepositoryProvider = Provider<QuickActionRepository>(
  (ref) => QuickActionRepositoryImpl(database: ref.watch(appDatabaseProvider)),
);

final episodeActionsProvider = FutureProvider<List<EpisodeAction>>(
  (ref) => ref.watch(quickActionRepositoryProvider).getEpisodeActions(),
);

final podcastActionsProvider = FutureProvider<List<PodcastAction>>(
  (ref) => ref.watch(quickActionRepositoryProvider).getPodcastActions(),
);
