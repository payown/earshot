import 'package:flutter/material.dart';

class SpeedSelector extends StatelessWidget {
  const SpeedSelector({
    required this.speed,
    required this.onSpeedChanged,
    super.key,
  });

  final double speed;
  final ValueChanged<double> onSpeedChanged;

  // 0.5x to 5.0x in 0.1x increments (46 speeds)
  static final List<double> speeds = List.unmodifiable([
    for (int i = 5; i <= 50; i++) i / 10.0,
  ]);

  // If s is on the 0.1 grid (within float epsilon), one decimal is exact.
  // Legacy persisted speeds (e.g. 1.25x) fall through to two decimals.
  static String formatSpeed(double s) {
    final tenths = (s * 10).round();
    if ((tenths / 10.0 - s).abs() < 1e-9) return '${s.toStringAsFixed(1)}x';
    return '${s.toStringAsFixed(2)}x';
  }

  @override
  Widget build(BuildContext context) {
    final idx = _nearestIndex(speed);
    final prev = idx > 0 ? speeds[idx - 1] : null;
    final next = idx < speeds.length - 1 ? speeds[idx + 1] : null;

    return Semantics(
      label: 'Playback speed',
      slider: true,
      value: formatSpeed(speed),
      decreasedValue: prev != null ? formatSpeed(prev) : null,
      increasedValue: next != null ? formatSpeed(next) : null,
      onDecrease: prev != null ? () => onSpeedChanged(prev) : null,
      onIncrease: next != null ? () => onSpeedChanged(next) : null,
      excludeSemantics: true,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            iconSize: 28,
            onPressed: prev != null ? () => onSpeedChanged(prev) : null,
          ),
          SizedBox(
            width: 56,
            child: Text(
              formatSpeed(speed),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            iconSize: 28,
            onPressed: next != null ? () => onSpeedChanged(next) : null,
          ),
        ],
      ),
    );
  }

  int _nearestIndex(double s) {
    var best = 0;
    var bestDist = (s - speeds[0]).abs();
    for (var i = 1; i < speeds.length; i++) {
      final d = (s - speeds[i]).abs();
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
  }
}
