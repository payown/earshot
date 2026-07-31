import '../../subscriptions/domain/episode.dart';
import '../../subscriptions/domain/podcast.dart';
import '../domain/podcast_folder.dart';

abstract interface class FolderRepository {
  Stream<List<PodcastFolder>> watchFolders();

  Stream<PodcastFolder?> watchFolder(int folderId);

  Stream<List<Podcast>> watchPodcastsInFolder(int folderId);

  Stream<List<int>> watchFolderIdsForPodcast(int podcastId);

  Stream<List<Podcast>> watchUnfiledPodcasts();

  Future<PodcastFolder> createFolder(String name);

  Future<void> renameFolder(int folderId, String name);

  Future<void> deleteFolder(int folderId);

  Future<void> setFolderQueueAgeLimit(int folderId, int? days);

  Future<void> addPodcastToFolder(int folderId, int podcastId);

  Future<void> removePodcastFromFolder(int folderId, int podcastId);

  Future<void> setMemberships(int podcastId, List<int> folderIds);

  Future<void> reorderFolders(List<int> orderedIds);

  Future<List<Episode>> getLatestUnplayedPerPodcast(int folderId);

  Future<List<({String rssUrl, String title})>> getFolderSubscriptions(
    int folderId,
  );

  Future<
    List<({String? folderName, List<({String rssUrl, String title})> podcasts})>
  >
  getAllWithFolderStructure();
}
