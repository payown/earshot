import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/core_providers.dart';
import '../../../settings/data/app_settings_repository.dart';
import '../../data/podcast_repository.dart';
import '../../data/podcast_repository_impl.dart';
import '../../domain/episode.dart';
import '../../domain/podcast.dart';

final podcastRepositoryProvider = Provider<PodcastRepository>(
  (ref) => PodcastRepositoryImpl(
    database: ref.watch(appDatabaseProvider),
    dio: ref.watch(dioProvider),
    rssParser: ref.watch(rssParserProvider),
    settings: AppSettingsRepositoryImpl(
      database: ref.watch(appDatabaseProvider),
    ),
  ),
);

final subscriptionsProvider = StreamProvider<List<Podcast>>(
  (ref) => ref.watch(podcastRepositoryProvider).watchSubscriptions(),
);

final podcastProvider = StreamProvider.family<Podcast?, int>(
  (ref, podcastId) =>
      ref.watch(podcastRepositoryProvider).watchPodcast(podcastId),
);

final episodesProvider = StreamProvider.family<List<Episode>, int>(
  (ref, podcastId) =>
      ref.watch(podcastRepositoryProvider).watchEpisodes(podcastId),
);

final feedRefreshAuditEventsProvider = StreamProvider<String>(
  (ref) => ref.watch(podcastRepositoryProvider).feedRefreshAuditEvents,
);
