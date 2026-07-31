import 'package:earshot/features/player/presentation/widgets/airplay_button.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AirPlayButton', () {
    testWidgets('renders the AirPlay route picker on iOS', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      await tester.pumpWidget(_wrap(const AirPlayButton()));

      final view = tester.widget<UiKitView>(find.byType(UiKitView));
      expect(view.viewType, 'media.payown.earshot/airplay_button');

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('renders nothing on Android', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      await tester.pumpWidget(_wrap(const AirPlayButton()));

      expect(find.byType(UiKitView), findsNothing);
      expect(tester.getSize(find.byType(AirPlayButton)), Size.zero);

      debugDefaultTargetPlatformOverride = null;
    });
  });
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));
