class Bookmark {
  const Bookmark({
    required this.id,
    required this.episodeId,
    required this.positionSeconds,
    required this.createdAt,
    this.note = '',
  });

  final int id;
  final int episodeId;
  final int positionSeconds;
  final String note;
  final DateTime createdAt;

  // Deep-link format per PRD §5.11
  String shareUrl(String baseUrl) => '$baseUrl?t=$positionSeconds';
}
