import '../../subscriptions/domain/episode.dart';

class QueueGroup {
  const QueueGroup({
    required this.podcastId,
    required this.podcastName,
    required this.episodes,
  });

  final int podcastId;
  final String podcastName;
  final List<Episode> episodes;
}
