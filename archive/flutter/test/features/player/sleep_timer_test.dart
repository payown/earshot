import 'package:earshot/features/player/domain/sleep_timer.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SleepTimer', () {
    late List<String> expired;
    late SleepTimer timer;

    setUp(() {
      expired = [];
      timer = SleepTimer(onExpired: () => expired.add('expired'));
    });

    tearDown(() => timer.dispose());

    // ── inactive state ──────────────────────────────────────────────────────

    test('is inactive by default', () {
      expect(timer.isActive, isFalse);
    });

    test('current state is inactive when not set', () {
      expect(timer.current.isActive, isFalse);
      expect(timer.current.preset, isNull);
      expect(timer.current.remaining, isNull);
    });

    // ── end-of-episode mode ─────────────────────────────────────────────────

    group('endOfEpisode preset', () {
      test('marks timer active with endOfEpisode flag', () {
        timer.set(SleepTimerPreset.endOfEpisode);

        expect(timer.isActive, isTrue);
        expect(timer.endOfEpisode, isTrue);
        expect(timer.current.endOfEpisode, isTrue);
        expect(timer.current.preset, SleepTimerPreset.endOfEpisode);
      });

      test('fires onExpired when onEpisodeEnded is called', () {
        timer.set(SleepTimerPreset.endOfEpisode);
        timer.onEpisodeEnded();

        expect(expired, hasLength(1));
      });

      test('is inactive after expiry', () {
        timer.set(SleepTimerPreset.endOfEpisode);
        timer.onEpisodeEnded();

        expect(timer.isActive, isFalse);
      });

      test(
        'does not fire when onEpisodeEnded is called in time-based mode',
        () {
          timer.set(SleepTimerPreset.fiveMinutes);
          timer.onEpisodeEnded();

          expect(expired, isEmpty);
        },
      );
    });

    // ── timed mode ──────────────────────────────────────────────────────────

    group('timed presets', () {
      test('marks timer active', () {
        timer.set(SleepTimerPreset.fiveMinutes);

        expect(timer.isActive, isTrue);
        expect(timer.endOfEpisode, isFalse);
        expect(timer.current.preset, SleepTimerPreset.fiveMinutes);
      });

      test('remaining duration is close to preset duration on start', () {
        timer.set(SleepTimerPreset.fiveMinutes);

        // DateTime.now() based — just check it's within 2 s of 5 minutes.
        final remaining = timer.current.remaining!;
        expect(remaining.inSeconds, closeTo(300, 2));
      });

      // Note: SleepTimer uses DateTime.now() for remaining checks, which
      // fakeAsync does not control. Expiry-on-elapsed tests would require
      // injecting a clock into SleepTimer (tracked as a future refactor).
      // The end-of-episode expiry path (which does not use DateTime.now())
      // is covered in the endOfEpisode group above.

      test('does not fire before duration elapses', () {
        fakeAsync((async) {
          timer.set(SleepTimerPreset.fiveMinutes);
          async.elapse(const Duration(minutes: 4, seconds: 59));

          expect(expired, isEmpty);
          expect(timer.isActive, isTrue);
        });
      });
    });

    // ── extend ──────────────────────────────────────────────────────────────

    group('extend', () {
      test('adds 5 minutes to remaining time immediately after set', () {
        timer.set(SleepTimerPreset.fiveMinutes);
        timer.extend();

        // _endTime moved from now+5min to now+10min so remaining ≈ 600s.
        final remaining = timer.current.remaining!;
        expect(remaining.inSeconds, closeTo(600, 2));
      });

      test('custom duration extends by that amount', () {
        timer.set(SleepTimerPreset.fiveMinutes);
        timer.extend(by: const Duration(minutes: 10));

        final remaining = timer.current.remaining!;
        expect(remaining.inSeconds, closeTo(900, 2));
      });

      test('no-op in endOfEpisode mode', () {
        timer.set(SleepTimerPreset.endOfEpisode);
        timer.extend();

        expect(timer.endOfEpisode, isTrue);
        expect(timer.current.remaining, isNull);
      });

      test('no-op when timer is inactive', () {
        timer.extend();

        expect(timer.isActive, isFalse);
      });

      test('prevents expiry if elapsed would have fired it', () {
        fakeAsync((async) {
          timer.set(SleepTimerPreset.fiveMinutes);
          async.elapse(const Duration(minutes: 4));
          timer.extend();

          async.elapse(const Duration(minutes: 1, seconds: 30));

          expect(expired, isEmpty);
          expect(timer.isActive, isTrue);
        });
      });
    });

    // ── cancel ───────────────────────────────────────────────────────────────

    group('cancel', () {
      test('deactivates a timed timer', () {
        fakeAsync((async) {
          timer.set(SleepTimerPreset.fiveMinutes);
          timer.cancel();

          expect(timer.isActive, isFalse);
        });
      });

      test('deactivates an end-of-episode timer', () {
        timer.set(SleepTimerPreset.endOfEpisode);
        timer.cancel();

        expect(timer.isActive, isFalse);
        expect(timer.endOfEpisode, isFalse);
      });

      test('cancelled timer does not fire after duration elapses', () {
        fakeAsync((async) {
          timer.set(SleepTimerPreset.fiveMinutes);
          timer.cancel();
          async.elapse(const Duration(minutes: 6));

          expect(expired, isEmpty);
        });
      });
    });

    // ── set replaces active timer ─────────────────────────────────────────

    group('set cancels previous timer', () {
      test('replacing a timed timer with end-of-episode', () {
        fakeAsync((async) {
          timer.set(SleepTimerPreset.fiveMinutes);
          timer.set(SleepTimerPreset.endOfEpisode);

          async.elapse(const Duration(minutes: 6));

          expect(expired, isEmpty);
          expect(timer.endOfEpisode, isTrue);
        });
      });

      test('replacing end-of-episode with a timed timer', () {
        fakeAsync((async) {
          timer.set(SleepTimerPreset.endOfEpisode);
          timer.set(SleepTimerPreset.fiveMinutes);

          timer.onEpisodeEnded();

          expect(expired, isEmpty);
          expect(timer.endOfEpisode, isFalse);
        });
      });
    });

    // ── stateStream ──────────────────────────────────────────────────────────

    group('stateStream', () {
      test('emits active state when timer is set', () async {
        final states = <SleepTimerState>[];
        final sub = timer.stateStream.listen(states.add);

        timer.set(SleepTimerPreset.endOfEpisode);
        await Future<void>.delayed(Duration.zero);

        expect(states, isNotEmpty);
        expect(states.last.isActive, isTrue);
        await sub.cancel();
      });

      test('emits inactive state after cancel', () async {
        final states = <SleepTimerState>[];
        final sub = timer.stateStream.listen(states.add);

        timer.set(SleepTimerPreset.endOfEpisode);
        timer.cancel();
        await Future<void>.delayed(Duration.zero);

        expect(states.last.isActive, isFalse);
        await sub.cancel();
      });
    });

    // ── announcementLabel ────────────────────────────────────────────────────

    group('SleepTimerState.announcementLabel', () {
      test('inactive returns "No sleep timer"', () {
        const state = SleepTimerState.inactive();
        expect(state.announcementLabel, 'No sleep timer');
      });

      test('end-of-episode returns expected label', () {
        const state = SleepTimerState(isActive: true, endOfEpisode: true);
        expect(state.announcementLabel, 'Sleep timer: end of episode');
      });

      test('1 minute remaining uses singular', () {
        const state = SleepTimerState(
          isActive: true,
          remaining: Duration(minutes: 1),
        );
        expect(state.announcementLabel, 'Sleep timer: 1 minute');
      });

      test('multiple minutes uses plural', () {
        const state = SleepTimerState(
          isActive: true,
          remaining: Duration(minutes: 5),
        );
        expect(state.announcementLabel, 'Sleep timer: 5 minutes');
      });

      test('under 1 minute shows seconds', () {
        const state = SleepTimerState(
          isActive: true,
          remaining: Duration(seconds: 30),
        );
        expect(state.announcementLabel, 'Sleep timer: 30 seconds');
      });

      test('1 second remaining uses singular', () {
        const state = SleepTimerState(
          isActive: true,
          remaining: Duration(seconds: 1),
        );
        expect(state.announcementLabel, 'Sleep timer: 1 second');
      });
    });
  });
}
