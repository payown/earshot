import 'package:earshot/features/player/presentation/widgets/speed_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));
Finder _speedFinder() => find.bySemanticsLabel('Playback speed');

void main() {
  group('SpeedSelector VoiceOver adjustable semantics', () {
    testWidgets(
      'has slider trait, current value, and increase/decrease actions',
      (tester) async {
        final handle = tester.ensureSemantics();

        await tester.pumpWidget(
          _wrap(
            SpeedSelector(speed: 1.0, onSpeedChanged: (_) {}),
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
          SpeedSelector(speed: 1.0, onSpeedChanged: (s) => selected = s),
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
          SpeedSelector(speed: 1.0, onSpeedChanged: (s) => selected = s),
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
          SpeedSelector(speed: 5.0, onSpeedChanged: (_) {}),
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
          SpeedSelector(speed: 1.25, onSpeedChanged: (_) {}),
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
          SpeedSelector(speed: 0.5, onSpeedChanged: (_) {}),
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

    testWidgets('formatSpeed formats on-grid speeds to one decimal', (
      tester,
    ) async {
      expect(SpeedSelector.formatSpeed(1.0), '1.0x');
      expect(SpeedSelector.formatSpeed(1.5), '1.5x');
      expect(SpeedSelector.formatSpeed(5.0), '5.0x');
    });

    testWidgets('formatSpeed formats off-grid legacy speeds to two decimals', (
      tester,
    ) async {
      expect(SpeedSelector.formatSpeed(1.25), '1.25x');
      expect(SpeedSelector.formatSpeed(0.75), '0.75x');
    });
  });
}
