import 'package:drift/native.dart';
import 'package:earshot/core/providers/core_providers.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/features/settings/data/app_settings_repository.dart';
import 'package:earshot/features/subscriptions/data/podcast_repository.dart';
import 'package:earshot/features/subscriptions/presentation/providers/subscriptions_providers.dart';
import 'package:earshot/main.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockPodcastRepository extends Mock implements PodcastRepository {}

void main() {
  testWidgets('app renders onboarding on first launch', (tester) async {
    final repo = MockPodcastRepository();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    when(() => repo.watchSubscriptions()).thenAnswer((_) => Stream.value([]));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          podcastRepositoryProvider.overrideWithValue(repo),
          appDatabaseProvider.overrideWithValue(db),
        ],
        child: const EarshotApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Welcome to Earshot'), findsOneWidget);
    await db.close();
  });

  testWidgets('app renders main shell after onboarding complete', (
    tester,
  ) async {
    final repo = MockPodcastRepository();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await AppSettingsRepositoryImpl(
      database: db,
    ).setOnboardingComplete(complete: true);
    when(() => repo.watchSubscriptions()).thenAnswer((_) => Stream.value([]));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          podcastRepositoryProvider.overrideWithValue(repo),
          appDatabaseProvider.overrideWithValue(db),
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
