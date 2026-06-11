import 'package:earshot/features/onboarding/presentation/screens/onboarding_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _buildApp() {
  return const ProviderScope(child: MaterialApp(home: OnboardingScreen()));
}

void main() {
  group('OnboardingScreen', () {
    testWidgets('focus lands on the first page heading on load', (
      tester,
    ) async {
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      expect(find.text('Welcome to Earshot'), findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'onboarding-heading',
      );
    });

    testWidgets(
      'focus moves to the next page heading, not the Next button',
      (tester) async {
        await tester.pumpWidget(_buildApp());
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(FilledButton, 'Next'));
        await tester.pumpAndSettle();

        expect(find.text('How your content flows'), findsOneWidget);
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'onboarding-heading',
        );
      },
    );
  });
}
