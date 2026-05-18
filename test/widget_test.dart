import 'package:earshot/features/subscriptions/data/podcast_repository.dart';
import 'package:earshot/features/subscriptions/presentation/providers/subscriptions_providers.dart';
import 'package:earshot/main.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockPodcastRepository extends Mock implements PodcastRepository {}

void main() {
  testWidgets('app renders subscriptions screen on launch', (tester) async {
    final repo = MockPodcastRepository();
    when(() => repo.watchSubscriptions()).thenAnswer((_) => Stream.value([]));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [podcastRepositoryProvider.overrideWithValue(repo)],
        child: const EarshotApp(),
      ),
    );
    await tester.pump();

    expect(find.text('Earshot'), findsOneWidget);
    expect(find.text('No podcasts yet'), findsOneWidget);
  });
}
