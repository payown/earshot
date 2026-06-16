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
    this.inboxMaxEpisodes,
    this.inboxAgeLimitHours,
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
  final int? inboxMaxEpisodes;
  final int? inboxAgeLimitHours;
  final DateTime createdAt;
  final DateTime? refreshedAt;

  /// True when this podcast has a playback override (speed or trim silence).
  /// Drives the "Reset to global speed" affordances, which only clear playback
  /// overrides — keep this separate from [hasCustomSettings] so adding an inbox
  /// limit doesn't surface a speed-reset button (or null-bang a missing speed).
  bool get hasPlaybackOverride =>
      speedOverride != null || trimSilenceOverride != null;

  /// True when this podcast has any per-podcast override at all, including the
  /// inbox count cap and age limit.
  bool get hasCustomSettings =>
      hasPlaybackOverride ||
      inboxMaxEpisodes != null ||
      inboxAgeLimitHours != null;
}
