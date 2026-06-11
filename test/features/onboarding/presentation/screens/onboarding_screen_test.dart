import 'package:earshot/core/router/app_router.dart';
import 'package:earshot/features/onboarding/presentation/screens/onboarding_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

Widget _buildApp() {
  return const ProviderScope(child: MaterialApp(home: OnboardingScreen()));
}

Widget _buildReplayApp(GoRouter router) {
  return ProviderScope(child: MaterialApp.router(routerConfig: router));
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

  group('OnboardingScreen replay mode', () {
    testWidgets(
      'Next is enabled on the add-podcast page without adding a podcast, '
      'and the last page shows Done and pops back',
      (tester) async {
        final router = GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(
              path: '/',
              builder: (_, __) => const Scaffold(body: Text('Settings')),
            ),
            GoRoute(
              path: AppRoutes.tutorial,
              builder: (_, __) => const OnboardingScreen(replayMode: true),
            ),
          ],
        );

        await tester.pumpWidget(_buildReplayApp(router));
        await tester.pumpAndSettle();
        router.push(AppRoutes.tutorial);
        await tester.pumpAndSettle();

        // Advance through all 6 pages, including "Add your first podcast"
        // (page 6), without adding a podcast.
        for (var i = 0; i < 6; i++) {
          await tester.tap(find.widgetWithText(FilledButton, 'Next'));
          await tester.pumpAndSettle();
        }

        expect(find.text("You're all set"), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'Done'), findsOneWidget);
        expect(
          find.widgetWithText(FilledButton, 'Start Listening'),
          findsNothing,
        );

        await tester.tap(find.widgetWithText(FilledButton, 'Done'));
        await tester.pumpAndSettle();

        expect(find.byType(OnboardingScreen), findsNothing);
        expect(find.text('Settings'), findsOneWidget);
      },
    );

    testWidgets(
      'falls back to navigating to Settings when there is nothing to pop',
      (tester) async {
        final router = GoRouter(
          initialLocation: AppRoutes.tutorial,
          routes: [
            GoRoute(
              path: AppRoutes.settings,
              builder: (_, __) => const Scaffold(body: Text('Settings Screen')),
            ),
            GoRoute(
              path: AppRoutes.tutorial,
              builder: (_, __) => const OnboardingScreen(replayMode: true),
            ),
          ],
        );

        await tester.pumpWidget(_buildReplayApp(router));
        await tester.pumpAndSettle();

        // /tutorial is the only entry on the stack, so there's nothing to
        // pop back to.
        for (var i = 0; i < 6; i++) {
          await tester.tap(find.widgetWithText(FilledButton, 'Next'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.widgetWithText(FilledButton, 'Done'));
        await tester.pumpAndSettle();

        expect(find.byType(OnboardingScreen), findsNothing);
        expect(find.text('Settings Screen'), findsOneWidget);
      },
    );
  });
}
