import 'package:earshot/features/downloads/data/inbox_limit_service.dart';
import 'package:earshot/features/downloads/presentation/providers/downloads_providers.dart';
import 'package:earshot/features/settings/presentation/providers/settings_providers.dart';
import 'package:earshot/features/subscriptions/data/podcast_repository.dart';
import 'package:earshot/features/subscriptions/domain/podcast.dart';
import 'package:earshot/features/subscriptions/presentation/providers/subscriptions_providers.dart';
import 'package:earshot/features/subscriptions/presentation/screens/podcast_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockPodcastRepository extends Mock implements PodcastRepository {}

class MockInboxLimitService extends Mock implements InboxLimitService {}

/// Stub for the global default so the per-podcast "Use default" label resolves
/// deterministically without touching a real database.
class _FakeInboxDefaultNotifier extends InboxDefaultMaxEpisodesNotifier {
  _FakeInboxDefaultNotifier(this._value);

  final int? _value;

  @override
  Future<int?> build() async => _value;
}

final _now = DateTime(2024, 6, 1);

Podcast _fakePodcast({
  int id = 1,
  int? inboxMaxEpisodes,
  int? inboxAgeLimitHours,
}) => Podcast(
  id: id,
  rssUrl: 'https://example.com/feed.xml',
  title: 'Test Podcast',
  autoQueue: false,
  notificationEnabled: false,
  inboxExcluded: false,
  inboxIncluded: false,
  inboxMaxEpisodes: inboxMaxEpisodes,
  inboxAgeLimitHours: inboxAgeLimitHours,
  createdAt: _now,
);

Widget _buildApp(
  MockPodcastRepository repo,
  MockInboxLimitService service, {
  int podcastId = 1,
  int? globalDefault,
}) {
  return ProviderScope(
    overrides: [
      podcastRepositoryProvider.overrideWithValue(repo),
      inboxLimitServiceProvider.overrideWithValue(service),
      inboxDefaultMaxEpisodesProvider.overrideWith(
        () => _FakeInboxDefaultNotifier(globalDefault),
      ),
    ],
    child: MaterialApp(home: PodcastSettingsScreen(podcastId: podcastId)),
  );
}

void main() {
  late MockPodcastRepository repo;
  late MockInboxLimitService service;

  setUpAll(() {
    registerFallbackValue(0);
  });

  setUp(() {
    repo = MockPodcastRepository();
    service = MockInboxLimitService();
    when(
      () => service.applyForPodcast(any(), now: any(named: 'now')),
    ).thenAnswer((_) async {});
    when(
      () => repo.setInboxMaxEpisodes(any(), any()),
    ).thenAnswer((_) async {});
    when(
      () => repo.setInboxAgeLimitHours(any(), any()),
    ).thenAnswer((_) async {});
  });

  void stubPodcast(Podcast podcast) {
    when(
      () => repo.watchPodcast(podcast.id),
    ).thenAnswer((_) => Stream.value(podcast));
  }

  testWidgets('renders both inbox-limit rows with default values', (
    tester,
  ) async {
    stubPodcast(_fakePodcast());

    await tester.pumpWidget(_buildApp(repo, service));
    await tester.pumpAndSettle();

    expect(find.text('Episodes in inbox'), findsOneWidget);
    expect(find.text('Remove from inbox after'), findsOneWidget);
    // Defaults: no per-podcast cap, no age limit. The "Use default" subtitle
    // names the resolved global value (null global => "No limit").
    expect(find.text('Use default (No limit)'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
  });

  testWidgets('rows reflect the podcast current values', (tester) async {
    stubPodcast(
      _fakePodcast(inboxMaxEpisodes: 5, inboxAgeLimitHours: 168),
    );

    await tester.pumpWidget(_buildApp(repo, service));
    await tester.pumpAndSettle();

    expect(find.text('5'), findsOneWidget);
    expect(find.text('1 week'), findsOneWidget);
  });

  testWidgets('selecting an episode cap writes through and re-applies limits', (
    tester,
  ) async {
    stubPodcast(_fakePodcast());

    await tester.pumpWidget(_buildApp(repo, service));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Episodes in inbox'));
    await tester.pumpAndSettle();

    // Pick "3" from the picker sheet.
    await tester.tap(find.text('3'));
    await tester.pumpAndSettle();

    verify(() => repo.setInboxMaxEpisodes(1, 3)).called(1);
    verify(() => service.applyForPodcast(1)).called(1);
  });

  testWidgets('selecting an age limit writes the mapped hours and re-applies', (
    tester,
  ) async {
    stubPodcast(_fakePodcast());

    await tester.pumpWidget(_buildApp(repo, service));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Remove from inbox after'));
    await tester.pumpAndSettle();

    // "1 day" maps to 24 hours.
    await tester.tap(find.text('1 day'));
    await tester.pumpAndSettle();

    verify(() => repo.setInboxAgeLimitHours(1, 24)).called(1);
    verify(() => service.applyForPodcast(1)).called(1);
  });

  testWidgets('choosing "Use default" clears the per-podcast cap (null)', (
    tester,
  ) async {
    stubPodcast(_fakePodcast(inboxMaxEpisodes: 5));

    await tester.pumpWidget(_buildApp(repo, service));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Episodes in inbox'));
    await tester.pumpAndSettle();

    // The picker's "Use default" option resolves the global value too. The
    // subtitle behind the sheet shows the same text, so tap the option (last).
    await tester.tap(find.text('Use default (No limit)').last);
    await tester.pumpAndSettle();

    verify(() => repo.setInboxMaxEpisodes(1, null)).called(1);
    verify(() => service.applyForPodcast(1)).called(1);
  });
}
