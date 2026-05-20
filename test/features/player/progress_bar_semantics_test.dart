import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

// Mirrors the _ProgressBar semantics shape so we can test the accessible
// adjustable actions without requiring the full player Riverpod setup.
class _TestProgressBar extends StatelessWidget {
  const _TestProgressBar({
    required this.position,
    required this.duration,
    required this.onSeek,
  });

  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onSeek;

  static const _kStep = Duration(seconds: 30);

  @override
  Widget build(BuildContext context) {
    final posLabel = _format(position);
    final durLabel = _format(duration);
    final increased = _clamp(position + _kStep);
    final decreased = _clamp(position - _kStep);

    return Semantics(
      label: 'Playback position: $posLabel of $durLabel',
      slider: true,
      value: posLabel,
      increasedValue: _format(increased),
      decreasedValue: _format(decreased),
      onIncrease: () => onSeek(increased),
      onDecrease: () => onSeek(decreased),
      child: ExcludeSemantics(
        child: SizedBox(
          width: 300,
          height: 48,
          child: Slider(
            value: duration.inMilliseconds > 0
                ? (position.inMilliseconds / duration.inMilliseconds).clamp(
                    0.0,
                    1.0,
                  )
                : 0.0,
            onChanged: (v) {
              final ms = (v * duration.inMilliseconds).round();
              onSeek(Duration(milliseconds: ms));
            },
          ),
        ),
      ),
    );
  }

  Duration _clamp(Duration d) {
    if (d.isNegative) return Duration.zero;
    if (duration.inMilliseconds > 0 && d > duration) return duration;
    return d;
  }

  String _format(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

Finder _progressFinder() =>
    find.bySemanticsLabel(RegExp(r'Playback position:'));

void main() {
  group('_ProgressBar VoiceOver adjustable semantics', () {
    testWidgets(
      'has slider trait, value label, and increase/decrease actions',
      (tester) async {
        final semanticsHandle = tester.ensureSemantics();

        await tester.pumpWidget(
          _wrap(
            _TestProgressBar(
              position: const Duration(minutes: 5),
              duration: const Duration(minutes: 30),
              onSeek: (_) {},
            ),
          ),
        );

        expect(
          tester.getSemantics(_progressFinder()),
          matchesSemantics(
            label: 'Playback position: 05:00 of 30:00',
            value: '05:00',
            isSlider: true,
            hasIncreaseAction: true,
            hasDecreaseAction: true,
            increasedValue: '05:30',
            decreasedValue: '04:30',
          ),
        );

        semanticsHandle.dispose();
      },
    );

    testWidgets('onIncrease seeks forward 30 seconds', (tester) async {
      final semanticsHandle = tester.ensureSemantics();
      Duration? seeked;

      await tester.pumpWidget(
        _wrap(
          _TestProgressBar(
            position: const Duration(minutes: 5),
            duration: const Duration(minutes: 30),
            onSeek: (d) => seeked = d,
          ),
        ),
      );

      final nodeId = tester.getSemantics(_progressFinder()).id;
      RendererBinding.instance.renderViews.first.owner!.semanticsOwner!
          .performAction(
            nodeId,
            SemanticsAction.increase,
          );
      await tester.pump();

      expect(seeked, const Duration(minutes: 5, seconds: 30));
      semanticsHandle.dispose();
    });

    testWidgets('onDecrease seeks back 30 seconds', (tester) async {
      final semanticsHandle = tester.ensureSemantics();
      Duration? seeked;

      await tester.pumpWidget(
        _wrap(
          _TestProgressBar(
            position: const Duration(minutes: 5),
            duration: const Duration(minutes: 30),
            onSeek: (d) => seeked = d,
          ),
        ),
      );

      final nodeId = tester.getSemantics(_progressFinder()).id;
      RendererBinding.instance.renderViews.first.owner!.semanticsOwner!
          .performAction(
            nodeId,
            SemanticsAction.decrease,
          );
      await tester.pump();

      expect(seeked, const Duration(minutes: 4, seconds: 30));
      semanticsHandle.dispose();
    });

    testWidgets('decrease clamps to zero at start of episode', (tester) async {
      final semanticsHandle = tester.ensureSemantics();
      Duration? seeked;

      await tester.pumpWidget(
        _wrap(
          _TestProgressBar(
            position: const Duration(seconds: 10),
            duration: const Duration(minutes: 30),
            onSeek: (d) => seeked = d,
          ),
        ),
      );

      final nodeId = tester.getSemantics(_progressFinder()).id;
      RendererBinding.instance.renderViews.first.owner!.semanticsOwner!
          .performAction(
            nodeId,
            SemanticsAction.decrease,
          );
      await tester.pump();

      expect(seeked, Duration.zero);
      semanticsHandle.dispose();
    });

    testWidgets('increase clamps to duration at end of episode', (
      tester,
    ) async {
      const dur = Duration(minutes: 30);
      final semanticsHandle = tester.ensureSemantics();
      Duration? seeked;

      await tester.pumpWidget(
        _wrap(
          _TestProgressBar(
            position: const Duration(minutes: 29, seconds: 50),
            duration: dur,
            onSeek: (d) => seeked = d,
          ),
        ),
      );

      final nodeId = tester.getSemantics(_progressFinder()).id;
      RendererBinding.instance.renderViews.first.owner!.semanticsOwner!
          .performAction(
            nodeId,
            SemanticsAction.increase,
          );
      await tester.pump();

      expect(seeked, dur);
      semanticsHandle.dispose();
    });
  });
}
