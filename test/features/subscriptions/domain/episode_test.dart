import 'package:earshot/data/db/enums.dart';
import 'package:earshot/features/subscriptions/domain/episode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Episode _makeEpisode({String? downloadPath}) => Episode(
    id: 1,
    podcastId: 1,
    guid: 'test-guid',
    title: 'Test Episode',
    audioUrl: 'https://example.com/ep.mp3',
    status: EpisodeStatus.newEpisode,
    downloadStatus: downloadPath != null
        ? DownloadStatus.downloaded
        : DownloadStatus.none,
    positionSeconds: 0,
    createdAt: DateTime(2024),
    downloadPath: downloadPath,
  );

  group('Episode.isDownloaded', () {
    test('returns true when downloadPath is non-null', () {
      final ep = _makeEpisode(downloadPath: '/var/mobile/Documents/ep.mp3');
      expect(ep.isDownloaded, isTrue);
    });

    test('returns false when downloadPath is null', () {
      final ep = _makeEpisode(downloadPath: null);
      expect(ep.isDownloaded, isFalse);
    });
  });
}
