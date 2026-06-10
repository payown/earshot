import 'package:earshot/features/player/domain/resume_position.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('clampedResumePosition', () {
    test('returns 0 when position is 0', () {
      expect(
        clampedResumePosition(positionSeconds: 0, durationSeconds: 3600),
        0,
      );
    });

    test('resumes at the saved position when duration is unknown', () {
      // Regression: feeds without itunes:duration restarted from 0 on every
      // relaunch. The 95% rule can't apply, so trust the saved position;
      // the completion-on-load case is covered by the playback-evidence
      // gates in the audio handler and PositionTracker.
      expect(
        clampedResumePosition(positionSeconds: 500, durationSeconds: null),
        500,
      );
    });

    test('resumes at the saved position when duration is 0', () {
      expect(
        clampedResumePosition(positionSeconds: 500, durationSeconds: 0),
        500,
      );
    });

    test('returns the saved position when below 95% of duration', () {
      expect(
        clampedResumePosition(positionSeconds: 1800, durationSeconds: 3600),
        1800,
      );
    });

    test('returns 0 at exactly 95% of duration', () {
      expect(
        clampedResumePosition(positionSeconds: 3420, durationSeconds: 3600),
        0,
      );
    });

    test('returns 0 past 95% of duration', () {
      expect(
        clampedResumePosition(positionSeconds: 3599, durationSeconds: 3600),
        0,
      );
    });

    test('returns 0 at or past the full duration', () {
      expect(
        clampedResumePosition(positionSeconds: 3600, durationSeconds: 3600),
        0,
      );
      expect(
        clampedResumePosition(positionSeconds: 4000, durationSeconds: 3600),
        0,
      );
    });
  });
}
