import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

// Mirrors _SpeedSelector so we can test semantics without the full player setup.
class _TestSpeedSelector extends StatelessWidget {
  const _TestSpeedSelector({
    required this.speed,
    required this.onSpeedChanged,
  });

  final double speed;
  final ValueChanged<double> onSpeedChanged;

  static final List<double> _speeds = List.unmodifiable([
    for (int i = 5; i <= 50; i++) i / 10.0,
  ]);

  @override
  Widget build(BuildContext context) {
    final idx = _nearestIndex(speed);
    final prev = idx > 0 ? _speeds[idx - 1] : null;
    final next = idx < _speeds.length - 1 ? _speeds[idx + 1] : null;

    return Semantics(
      label: 'Playback speed',
      slider: true,
      value: _label(speed),
      decreasedValue: prev != null ? _label(prev) : null,
      increasedValue: next != null ? _label(next) : null,
      onDecrease: prev != null ? () => onSpeedChanged(prev) : null,
      onIncrease: next != null ? () => onSpeedChanged(next) : null,
      child: ExcludeSemantics(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: prev != null ? () => onSpeedChanged(prev) : null,
            ),
            SizedBox(
              width: 56,
              child: Text(_label(speed), textAlign: TextAlign.center),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: next != null ? () => onSpeedChanged(next) : null,
            ),
          ],
        ),
      ),
    );
  }

  int _nearestIndex(double s) {
    var best = 0;
    var bestDist = (s - _speeds[0]).abs();
    for (var i = 1; i < _speeds.length; i++) {
      final d = (s - _speeds[i]).abs();
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
  }

  String _label(double s) {
    final tenths = (s * 10).round();
    if ((tenths / 10.0 - s).abs() < 1e-9) return '${s.toStringAsFixed(1)}x';
    return '${s.toStringAsFixed(2)}x';
  }
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));
Finder _speedFinder() => find.bySemanticsLabel('Playback speed');

void main() {
  group('_SpeedSelector VoiceOver adjustable semantics', () {
    testWidgets(
      'has slider trait, current value, and increase/decrease actions',
      (tester) async {
        final handle = tester.ensureSemantics();

        await tester.pumpWidget(
          _wrap(
            _TestSpeedSelector(
              speed: 1.0,
              onSpeedChanged: (_) {},
            ),
          ),
        );

        expect(
          tester.getSemantics(_speedFinder()),
          matchesSemantics(
            label: 'Playback speed',
            value: '1.0x',
            isSlider: true,
            hasIncreaseAction: true,
            hasDecreaseAction: true,
            increasedValue: '1.1x',
            decreasedValue: '0.9x',
          ),
        );

        handle.dispose();
      },
    );

    testWidgets('onIncrease moves to next speed', (tester) async {
      final handle = tester.ensureSemantics();
      double? selected;

      await tester.pumpWidget(
        _wrap(
          _TestSpeedSelector(speed: 1.0, onSpeedChanged: (s) => selected = s),
        ),
      );

      RendererBinding.instance.renderViews.first.owner!.semanticsOwner!
          .performAction(
            tester.getSemantics(_speedFinder()).id,
            SemanticsAction.increase,
          );
      await tester.pump();

      expect(selected, 1.1);
      handle.dispose();
    });

    testWidgets('onDecrease moves to previous speed', (tester) async {
      final handle = tester.ensureSemantics();
      double? selected;

      await tester.pumpWidget(
        _wrap(
          _TestSpeedSelector(speed: 1.0, onSpeedChanged: (s) => selected = s),
        ),
      );

      RendererBinding.instance.renderViews.first.owner!.semanticsOwner!
          .performAction(
            tester.getSemantics(_speedFinder()).id,
            SemanticsAction.decrease,
          );
      await tester.pump();

      expect(selected, 0.9);
      handle.dispose();
    });

    testWidgets('no increase action at maximum speed', (tester) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(
        _wrap(
          _TestSpeedSelector(speed: 5.0, onSpeedChanged: (_) {}),
        ),
      );

      expect(
        tester.getSemantics(_speedFinder()),
        matchesSemantics(
          label: 'Playback speed',
          value: '5.0x',
          isSlider: true,
          hasIncreaseAction: false,
          hasDecreaseAction: true,
        ),
      );

      handle.dispose();
    });

    testWidgets('legacy 1.25x speed displays as 1.25x not 1.3x', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(
        _wrap(
          _TestSpeedSelector(speed: 1.25, onSpeedChanged: (_) {}),
        ),
      );

      expect(
        tester.getSemantics(_speedFinder()),
        matchesSemantics(
          label: 'Playback speed',
          value: '1.25x',
          isSlider: true,
          hasIncreaseAction: true,
          hasDecreaseAction: true,
        ),
      );

      handle.dispose();
    });

    testWidgets('no decrease action at minimum speed', (tester) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(
        _wrap(
          _TestSpeedSelector(speed: 0.5, onSpeedChanged: (_) {}),
        ),
      );

      expect(
        tester.getSemantics(_speedFinder()),
        matchesSemantics(
          label: 'Playback speed',
          value: '0.5x',
          isSlider: true,
          hasIncreaseAction: true,
          hasDecreaseAction: false,
        ),
      );

      handle.dispose();
    });
  });
}
