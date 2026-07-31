class PodcastFolder {
  const PodcastFolder({
    required this.id,
    required this.name,
    required this.sortOrder,
    required this.createdAt,
    this.queueAgeLimitDays,
  });

  final int id;
  final String name;
  final int sortOrder;
  final int? queueAgeLimitDays;
  final DateTime createdAt;
}
