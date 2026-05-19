import '../../../data/db/enums.dart';
import '../domain/episode.dart';
import '../domain/podcast.dart';

abstract interface class PodcastRepository {
  Future<Podcast> subscribe(String rssUrl);

  Future<void> unsubscribe(int podcastId);

  Stream<List<Podcast>> watchSubscriptions();

  Stream<Podcast?> watchPodcast(int podcastId);

  Stream<List<Episode>> watchEpisodes(int podcastId);

  Future<void> refreshFeed(int podcastId);

  Future<void> updateEpisodeStatus(int episodeId, EpisodeStatus status);

  Future<void> markAllInboxPlayed();

  Future<void> updateSpeedOverride(int podcastId, double? speed);
}
