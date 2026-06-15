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

  group('nextEqualsCompleted', () {
    test('true when the next episode is the one that just completed', () {
      // markPlayedAndRemove no-opped and the completed episode is still at the
      // queue head — playing it would restart it from the beginning.
      expect(nextEqualsCompleted(42, 42), isTrue);
    });

    test('false when the next episode differs from the completed episode', () {
      expect(nextEqualsCompleted(43, 42), isFalse);
    });

    test('false when the next episode id is null', () {
      expect(nextEqualsCompleted(null, 42), isFalse);
    });

    test('false when the completed episode id is null', () {
      expect(nextEqualsCompleted(42, null), isFalse);
    });

    test('false when both ids are null', () {
      expect(nextEqualsCompleted(null, null), isFalse);
    });
  });
}
