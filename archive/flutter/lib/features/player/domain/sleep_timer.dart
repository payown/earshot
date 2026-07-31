import 'dart:async';

import 'package:logging/logging.dart';

final _log = Logger('SleepTimer');

enum SleepTimerPreset {
  endOfEpisode,
  fiveMinutes,
  tenMinutes,
  fifteenMinutes,
  thirtyMinutes,
  fortyFiveMinutes,
  sixtyMinutes;

  String get label => switch (this) {
    SleepTimerPreset.endOfEpisode => 'End of episode',
    SleepTimerPreset.fiveMinutes => '5 minutes',
    SleepTimerPreset.tenMinutes => '10 minutes',
    SleepTimerPreset.fifteenMinutes => '15 minutes',
    SleepTimerPreset.thirtyMinutes => '30 minutes',
    SleepTimerPreset.fortyFiveMinutes => '45 minutes',
    SleepTimerPreset.sixtyMinutes => '60 minutes',
  };

  Duration? get duration => switch (this) {
    SleepTimerPreset.endOfEpisode => null,
    SleepTimerPreset.fiveMinutes => const Duration(minutes: 5),
    SleepTimerPreset.tenMinutes => const Duration(minutes: 10),
    SleepTimerPreset.fifteenMinutes => const Duration(minutes: 15),
    SleepTimerPreset.thirtyMinutes => const Duration(minutes: 30),
    SleepTimerPreset.fortyFiveMinutes => const Duration(minutes: 45),
    SleepTimerPreset.sixtyMinutes => const Duration(minutes: 60),
  };
}

class SleepTimerState {
  const SleepTimerState({
    required this.isActive,
    this.preset,
    this.remaining,
    this.endOfEpisode = false,
  });

  const SleepTimerState.inactive()
    : isActive = false,
      preset = null,
      remaining = null,
      endOfEpisode = false;

  final bool isActive;
  // The preset that was selected. Null when inactive.
  final SleepTimerPreset? preset;
  final Duration? remaining;
  final bool endOfEpisode;

  String get announcementLabel {
    if (!isActive) return 'No sleep timer';
    if (endOfEpisode) return 'Sleep timer: end of episode';
    final r = remaining;
    if (r == null) return 'Sleep timer active';
    final m = r.inMinutes;
    final s = r.inSeconds.remainder(60);
    if (m > 0) return 'Sleep timer: $m ${m == 1 ? "minute" : "minutes"}';
    return 'Sleep timer: $s ${s == 1 ? "second" : "seconds"}';
  }
}

class SleepTimer {
  SleepTimer({required this.onExpired});

  final void Function() onExpired;

  final _stateController = StreamController<SleepTimerState>.broadcast();
  Stream<SleepTimerState> get stateStream => _stateController.stream;

  Timer? _countdownTimer;
  DateTime? _endTime;
  bool _endOfEpisode = false;
  SleepTimerPreset? _currentPreset;

  SleepTimerState get current {
    if (!isActive) return const SleepTimerState.inactive();
    if (_endOfEpisode) {
      return SleepTimerState(
        isActive: true,
        preset: _currentPreset,
        endOfEpisode: true,
      );
    }
    final remaining = _endTime?.difference(DateTime.now());
    return SleepTimerState(
      isActive: true,
      preset: _currentPreset,
      remaining: remaining,
    );
  }

  bool get isActive => _countdownTimer != null || _endOfEpisode;

  bool get endOfEpisode => _endOfEpisode;

  void set(SleepTimerPreset preset) {
    cancel();
    _currentPreset = preset;
    if (preset == SleepTimerPreset.endOfEpisode) {
      _endOfEpisode = true;
      _emit();
      _log.info('Sleep timer set: end of episode');
      return;
    }

    final duration = preset.duration!;
    _endTime = DateTime.now().add(duration);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final remaining = _endTime!.difference(DateTime.now());
      if (remaining.isNegative || remaining == Duration.zero) {
        _expire();
      } else {
        _emit();
      }
    });
    _emit();
    _log.info('Sleep timer set: ${preset.label}');
  }

  void extend({Duration by = const Duration(minutes: 5)}) {
    if (!isActive || _endOfEpisode) return;
    _endTime = _endTime!.add(by);
    _emit();
    _log.info('Sleep timer extended by ${by.inMinutes} minutes');
  }

  void cancel() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _endTime = null;
    _endOfEpisode = false;
    _currentPreset = null;
    _emit();
  }

  void onEpisodeEnded() {
    if (_endOfEpisode) _expire();
  }

  void _expire() {
    cancel();
    onExpired();
    _log.info('Sleep timer expired');
  }

  void _emit() {
    if (!_stateController.isClosed) {
      _stateController.add(current);
    }
  }

  void dispose() {
    _countdownTimer?.cancel();
    _stateController.close();
  }
}
