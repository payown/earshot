enum StatsPeriod {
  thisWeek,
  thisMonth,
  thisYear,
  allTime
  ;

  String get label => switch (this) {
    StatsPeriod.thisWeek => 'This Week',
    StatsPeriod.thisMonth => 'This Month',
    StatsPeriod.thisYear => 'This Year',
    StatsPeriod.allTime => 'All Time',
  };

  DateTime? get since {
    final now = DateTime.now().toUtc();
    return switch (this) {
      StatsPeriod.thisWeek => now.subtract(Duration(days: now.weekday - 1)),
      StatsPeriod.thisMonth => DateTime.utc(now.year, now.month),
      StatsPeriod.thisYear => DateTime.utc(now.year),
      StatsPeriod.allTime => null,
    };
  }
}

class ListeningStats {
  const ListeningStats({
    required this.totalSeconds,
    required this.timeSavedSeconds,
    required this.episodesCompleted,
    required this.perPodcast,
  });

  final int totalSeconds;
  final int timeSavedSeconds;
  final int episodesCompleted;
  final List<PodcastStats> perPodcast;
}

class PodcastStats {
  const PodcastStats({
    required this.podcastId,
    required this.podcastTitle,
    required this.totalSeconds,
    required this.episodeCount,
  });

  final int podcastId;
  final String podcastTitle;
  final int totalSeconds;
  final int episodeCount;
}
