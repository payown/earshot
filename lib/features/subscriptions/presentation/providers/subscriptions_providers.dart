import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/core_providers.dart';
import '../../data/podcast_repository.dart';
import '../../data/podcast_repository_impl.dart';
import '../../domain/episode.dart';
import '../../domain/podcast.dart';

final podcastRepositoryProvider = Provider<PodcastRepository>(
  (ref) => PodcastRepositoryImpl(
    database: ref.watch(appDatabaseProvider),
    dio: ref.watch(dioProvider),
    rssParser: ref.watch(rssParserProvider),
  ),
);

final subscriptionsProvider = StreamProvider<List<Podcast>>(
  (ref) => ref.watch(podcastRepositoryProvider).watchSubscriptions(),
);

final episodesProvider = StreamProvider.family<List<Episode>, int>(
  (ref, podcastId) =>
      ref.watch(podcastRepositoryProvider).watchEpisodes(podcastId),
);
