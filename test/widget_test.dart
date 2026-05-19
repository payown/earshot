import 'package:drift/native.dart';
import 'package:earshot/core/providers/core_providers.dart';
import 'package:earshot/core/router/app_router.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/features/subscriptions/data/podcast_repository.dart';
import 'package:earshot/features/subscriptions/presentation/providers/subscriptions_providers.dart';
import 'package:earshot/main.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockPodcastRepository extends Mock implements PodcastRepository {}

void main() {
  testWidgets('app renders onboarding on first launch', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final repo = MockPodcastRepository();
    when(() => repo.watchSubscriptions()).thenAnswer((_) => Stream.value([]));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          podcastRepositoryProvider.overrideWithValue(repo),
          appDatabaseProvider.overrideWithValue(db),
          // Override onboarding state directly — avoids async DB reads in GoRouter.
          isOnboardingCompleteProvider.overrideWith((_) async => false),
        ],
        child: const EarshotApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Welcome to Earshot'), findsOneWidget);
    // Close DB before widget disposal to prevent Drift timer leaks in tests.
    await db.close();
  });

  testWidgets('app renders main shell after onboarding complete', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final repo = MockPodcastRepository();
    when(() => repo.watchSubscriptions()).thenAnswer((_) => Stream.value([]));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          podcastRepositoryProvider.overrideWithValue(repo),
          appDatabaseProvider.overrideWithValue(db),
          isOnboardingCompleteProvider.overrideWith((_) async => true),
        ],
        child: const EarshotApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Subscriptions'), findsOneWidget);
    expect(find.text('Inbox'), findsOneWidget);
    await db.close();
  });
}
