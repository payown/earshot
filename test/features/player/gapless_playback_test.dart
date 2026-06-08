import 'package:audio_service/audio_service.dart';
import 'package:earshot/core/constants/playback.dart';
import 'package:earshot/features/player/data/audio_handler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

void main() {
  group('resolveAudioSource', () {
    test('returns file:// URI when downloadPath is set', () {
      const path = '/data/user/0/media.com.earshot/episode.mp3';
      const item = MediaItem(
        id: 'https://example.com/episode.mp3',
        title: 'Test',
        extras: {'downloadPath': path},
      );
      final source = resolveAudioSource(item) as UriAudioSource;
      expect(source.uri.scheme, 'file');
    });

    test('returns https:// URI when downloadPath is absent', () {
      const url = 'https://example.com/episode.mp3';
      const item = MediaItem(id: url, title: 'Test');
      final source = resolveAudioSource(item) as UriAudioSource;
      expect(source.uri.scheme, 'https');
      expect(source.uri.host, 'example.com');
    });

    test('returns https:// URI when downloadPath is null in extras', () {
      const url = 'https://example.com/episode.mp3';
      const item = MediaItem(
        id: url,
        title: 'Test',
        extras: {'episodeId': 42, 'downloadPath': null},
      );
      final source = resolveAudioSource(item) as UriAudioSource;
      expect(source.uri.scheme, 'https');
    });
  });

  group('shouldPreload', () {
    const threshold = kGaplessPreloadThreshold;
    const hour = Duration(hours: 1);

    test('returns false when well before threshold', () {
      final position = hour - threshold - const Duration(seconds: 1);
      expect(shouldPreload(position, hour, threshold), isFalse);
    });

    test('returns true exactly at threshold boundary', () {
      final position = hour - threshold;
      expect(shouldPreload(position, hour, threshold), isTrue);
    });

    test('returns true when past threshold', () {
      final position = hour - const Duration(seconds: 5);
      expect(shouldPreload(position, hour, threshold), isTrue);
    });

    test('returns false when duration is zero', () {
      expect(
        shouldPreload(Duration.zero, Duration.zero, threshold),
        isFalse,
      );
    });

    test('returns false when position is zero and duration is unknown', () {
      expect(
        shouldPreload(Duration.zero, Duration.zero, threshold),
        isFalse,
      );
    });

    test('handles short episodes shorter than threshold', () {
      const shortDuration = Duration(seconds: 30);
      // Any position triggers preload for episodes shorter than the threshold
      // because duration - threshold is negative (30s - 60s = -30s).
      expect(
        shouldPreload(const Duration(seconds: 1), shortDuration, threshold),
        isTrue,
      );
    });
  });
}
