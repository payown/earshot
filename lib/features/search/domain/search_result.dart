class PodcastSearchResult {
  const PodcastSearchResult({
    required this.title,
    required this.feedUrl,
    this.author,
    this.artworkUrl,
    this.description,
  });

  final String title;
  final String feedUrl;
  final String? author;
  final String? artworkUrl;
  final String? description;
}
