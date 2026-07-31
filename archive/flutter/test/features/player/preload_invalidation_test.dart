import 'package:earshot/features/player/data/audio_handler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('preloadedNextIsStale', () {
    test('keeps preload when nothing is preloaded', () {
      expect(
        preloadedNextIsStale(
          preloadedNextEpisodeId: null,
          currentEpisodeId: 1,
          queueEpisodeIds: const [1, 2, 3],
        ),
        isFalse,
      );
    });

    test('keeps preload when there is no current episode', () {
      expect(
        preloadedNextIsStale(
          preloadedNextEpisodeId: 2,
          currentEpisodeId: null,
          queueEpisodeIds: const [1, 2, 3],
        ),
        isFalse,
      );
    });

    test('keeps preload when current episode is no longer in the queue', () {
      // Current removed: out of scope for this fix; leave the preload alone.
      expect(
        preloadedNextIsStale(
          preloadedNextEpisodeId: 2,
          currentEpisodeId: 1,
          queueEpisodeIds: const [2, 3],
        ),
        isFalse,
      );
    });

    test('keeps preload when it is still the correct next episode', () {
      expect(
        preloadedNextIsStale(
          preloadedNextEpisodeId: 2,
          currentEpisodeId: 1,
          queueEpisodeIds: const [1, 2, 3],
        ),
        isFalse,
      );
    });

    test('stale when the preloaded next episode was removed (#297)', () {
      // 2 was the preloaded next; the user removed it, so 3 is now next.
      expect(
        preloadedNextIsStale(
          preloadedNextEpisodeId: 2,
          currentEpisodeId: 1,
          queueEpisodeIds: const [1, 3],
        ),
        isTrue,
      );
    });

    test('stale when current is now last and the preload should be gone', () {
      expect(
        preloadedNextIsStale(
          preloadedNextEpisodeId: 2,
          currentEpisodeId: 1,
          queueEpisodeIds: const [1],
        ),
        isTrue,
      );
    });

    test('stale when a reorder changed which episode comes next', () {
      // 3 was moved ahead of the preloaded 2.
      expect(
        preloadedNextIsStale(
          preloadedNextEpisodeId: 2,
          currentEpisodeId: 1,
          queueEpisodeIds: const [1, 3, 2],
        ),
        isTrue,
      );
    });
  });
}
