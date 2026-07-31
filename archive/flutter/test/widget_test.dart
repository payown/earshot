import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:earshot/core/presentation/widgets/accessible_nav_bar.dart';
import 'package:earshot/core/providers/core_providers.dart';
import 'package:earshot/core/router/app_router.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/data/db/enums.dart';
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

    // "Library" appears in both the AppBar title and the bottom-nav label.
    // Target the nav label specifically so the assertion remains meaningful.
    expect(
      find.descendant(
        of: find.byType(AccessibleNavBar),
        matching: find.text('Library'),
      ),
      findsOneWidget,
    );
    expect(find.text('Inbox'), findsOneWidget);
    await db.close();
  });

  testWidgets('inbox tab speaks "Inbox, N new" when there are new episodes', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final repo = MockPodcastRepository();
    when(() => repo.watchSubscriptions()).thenAnswer((_) => Stream.value([]));

    await db
        .into(db.podcasts)
        .insert(
          PodcastsCompanion.insert(
            rssUrl: 'https://example.com/feed.xml',
            title: 'Test Podcast',
          ),
        );
    for (var i = 0; i < 2; i++) {
      await db
          .into(db.episodes)
          .insert(
            EpisodesCompanion.insert(
              podcastId: 1,
              guid: 'ep-$i',
              title: 'Episode $i',
              audioUrl: 'https://example.com/ep$i.mp3',
              status: const Value(EpisodeStatus.newEpisode),
            ),
          );
    }

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

    // The real provider -> ternary -> AccessibleNavBar wiring should speak the
    // count, while the visible label stays "Inbox" (#322).
    expect(find.bySemanticsLabel('Inbox, 2 new'), findsOneWidget);
    await db.close();
    handle.dispose();
  });
}
