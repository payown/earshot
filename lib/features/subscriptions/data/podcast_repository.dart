import '../domain/episode.dart';
import '../domain/podcast.dart';

abstract interface class PodcastRepository {
  Future<Podcast> subscribe(String rssUrl);

  Future<void> unsubscribe(int podcastId);

  Stream<List<Podcast>> watchSubscriptions();

  Stream<List<Episode>> watchEpisodes(int podcastId);

  Future<void> refreshFeed(int podcastId);
}
