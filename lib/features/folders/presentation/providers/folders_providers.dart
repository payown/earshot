import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/core_providers.dart';
import '../../../subscriptions/domain/podcast.dart';
import '../../data/folder_repository.dart';
import '../../data/folder_repository_impl.dart';
import '../../domain/podcast_folder.dart';

final folderRepositoryProvider = Provider<FolderRepository>(
  (ref) => FolderRepositoryImpl(database: ref.watch(appDatabaseProvider)),
);

final foldersProvider = StreamProvider<List<PodcastFolder>>(
  (ref) => ref.watch(folderRepositoryProvider).watchFolders(),
);

final folderProvider = StreamProvider.family<PodcastFolder?, int>(
  (ref, folderId) => ref.watch(folderRepositoryProvider).watchFolder(folderId),
);

final podcastsInFolderProvider = StreamProvider.family<List<Podcast>, int>(
  (ref, folderId) =>
      ref.watch(folderRepositoryProvider).watchPodcastsInFolder(folderId),
);

final folderIdsForPodcastProvider = StreamProvider.family<List<int>, int>(
  (ref, podcastId) =>
      ref.watch(folderRepositoryProvider).watchFolderIdsForPodcast(podcastId),
);

final unfiledPodcastsProvider = StreamProvider<List<Podcast>>(
  (ref) => ref.watch(folderRepositoryProvider).watchUnfiledPodcasts(),
);
