class Podcast {
  const Podcast({
    required this.id,
    required this.rssUrl,
    required this.title,
    required this.autoQueue,
    required this.notificationEnabled,
    required this.inboxExcluded,
    required this.inboxIncluded,
    required this.createdAt,
    this.author,
    this.description,
    this.artworkUrl,
    this.websiteUrl,
    this.language,
    this.category,
    this.speedOverride,
    this.trimSilenceOverride,
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
  final bool inboxExcluded;
  final bool inboxIncluded;
  final double? speedOverride;
  final bool? trimSilenceOverride;
  final int? queueAgeLimitDays;
  final DateTime createdAt;
  final DateTime? refreshedAt;

  bool get hasCustomSettings =>
      speedOverride != null || trimSilenceOverride != null;
}
