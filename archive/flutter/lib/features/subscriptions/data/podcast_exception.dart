sealed class PodcastException implements Exception {
  const PodcastException(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

final class PodcastFetchException extends PodcastException {
  const PodcastFetchException(super.message);
}

final class PodcastAlreadySubscribedException extends PodcastException {
  const PodcastAlreadySubscribedException(String rssUrl)
    : super('Already subscribed to $rssUrl');
}

final class PodcastNotFoundException extends PodcastException {
  const PodcastNotFoundException(String rssUrl)
    : super('No valid podcast found at $rssUrl');
}
