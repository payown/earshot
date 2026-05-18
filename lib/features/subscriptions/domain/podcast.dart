class Podcast {
  const Podcast({
    required this.id,
    required this.rssUrl,
    required this.title,
    required this.autoQueue,
    required this.notificationEnabled,
    required this.createdAt,
    this.author,
    this.description,
    this.artworkUrl,
    this.websiteUrl,
    this.language,
    this.category,
    this.speedOverride,
    this.queueAgeLimitDays,
    this.refreshedAt,
  });

  final int id;
  final String rssUrl;
  final String title;
  final String? author;
  final String? description;
  final String? artworkUrl;
  final String? websiteUrl;
  final String? language;
  final String? category;
  final bool autoQueue;
  final bool notificationEnabled;
  final double? speedOverride;
  final int? queueAgeLimitDays;
  final DateTime createdAt;
  final DateTime? refreshedAt;
}
