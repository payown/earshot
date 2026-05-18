import '../../../data/db/enums.dart';

class Episode {
  const Episode({
    required this.id,
    required this.podcastId,
    required this.guid,
    required this.title,
    required this.audioUrl,
    required this.status,
    required this.downloadStatus,
    required this.positionSeconds,
    required this.createdAt,
    this.description,
    this.durationSeconds,
    this.pubDate,
    this.artworkUrl,
    this.episodeNumber,
    this.seasonNumber,
    this.chapterUrl,
    this.transcriptUrl,
    this.downloadPath,
    this.playedAt,
  });

  final int id;
  final int podcastId;
  final String guid;
  final String title;
  final String? description;
  final String audioUrl;
  final int? durationSeconds;
  final DateTime? pubDate;
  final String? artworkUrl;
  final int? episodeNumber;
  final int? seasonNumber;
  final String? chapterUrl;
  final String? transcriptUrl;
  final EpisodeStatus status;
  final DownloadStatus downloadStatus;
  final String? downloadPath;
  final int positionSeconds;
  final DateTime? playedAt;
  final DateTime createdAt;
}
