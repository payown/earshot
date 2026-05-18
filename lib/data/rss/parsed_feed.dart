class ParsedPodcast {
  const ParsedPodcast({
    required this.title,
    required this.episodes,
    this.author,
    this.description,
    this.artworkUrl,
    this.websiteUrl,
    this.language,
    this.category,
  });

  final String title;
  final String? author;
  final String? description;
  final String? artworkUrl;
  final String? websiteUrl;
  final String? language;
  final String? category;
  final List<ParsedEpisode> episodes;
}

class ParsedEpisode {
  const ParsedEpisode({
    required this.guid,
    required this.title,
    required this.audioUrl,
    this.description,
    this.durationSeconds,
    this.pubDate,
    this.artworkUrl,
    this.episodeNumber,
    this.seasonNumber,
    this.chapterUrl,
    this.transcriptUrl,
  });

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
}
