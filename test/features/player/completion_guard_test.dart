import 'package:earshot/features/player/data/audio_handler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shouldHonorCompleted', () {
    test('honors completion after real playback', () {
      // playRequestedSinceLoad is sticky, so this also covers a pause (user
      // or sleep timer) landing at the exact media end: the request flag
      // stays true and a genuine completion is not suppressed.
      expect(
        shouldHonorCompleted(
          readySinceLoad: true,
          playRequestedSinceLoad: true,
        ),
        isTrue,
      );
    });

    test(
      'ignores completion-on-load (never ready, playback never requested)',
      () {
        // Restoring at/past the media end after a crash: the player reports
        // completed without ever reaching ready or being asked to play.
        expect(
          shouldHonorCompleted(
            readySinceLoad: false,
            playRequestedSinceLoad: false,
          ),
          isFalse,
        );
      },
    );

    test('ignores completion when playback was never requested', () {
      expect(
        shouldHonorCompleted(
          readySinceLoad: true,
          playRequestedSinceLoad: false,
        ),
        isFalse,
      );
    });

    test('ignores completion before the player ever reached ready', () {
      expect(
        shouldHonorCompleted(
          readySinceLoad: false,
          playRequestedSinceLoad: true,
        ),
        isFalse,
      );
    });
  });
}
