import 'package:earshot/features/player/data/audio_handler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shouldHonorCompleted', () {
    test('honors completion after real playback', () {
      expect(
        shouldHonorCompleted(readySinceLoad: true, playing: true),
        isTrue,
      );
    });

    test('ignores completion-on-load (never reached ready, not playing)', () {
      // Restoring at/past the media end after a crash: the player reports
      // completed without ever reaching ready or being asked to play.
      expect(
        shouldHonorCompleted(readySinceLoad: false, playing: false),
        isFalse,
      );
    });

    test('ignores completion when playback was never requested', () {
      expect(
        shouldHonorCompleted(readySinceLoad: true, playing: false),
        isFalse,
      );
    });

    test('ignores completion before the player ever reached ready', () {
      expect(
        shouldHonorCompleted(readySinceLoad: false, playing: true),
        isFalse,
      );
    });
  });
}
