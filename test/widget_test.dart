import 'package:drift/native.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/features/subscriptions/data/podcast_repository.dart';
import 'package:earshot/features/subscriptions/presentation/providers/subscriptions_providers.dart';
import 'package:earshot/core/providers/core_providers.dart';
import 'package:earshot/main.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockPodcastRepository extends Mock implements PodcastRepository {}

void main() {
  testWidgets('app renders with bottom navigation on launch', (tester) async {
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
    await tester.pump();

    // Bottom nav should be present.
    expect(find.text('Subscriptions'), findsOneWidget);
    expect(find.text('Inbox'), findsOneWidget);
    expect(find.text('Queue'), findsOneWidget);
    expect(find.text('Downloads'), findsOneWidget);

    await db.close();
  });
}
