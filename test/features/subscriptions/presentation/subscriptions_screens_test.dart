import 'package:drift/native.dart';
import 'package:earshot/core/providers/core_providers.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/data/db/enums.dart';
import 'package:earshot/features/downloads/data/download_manager.dart';
import 'package:earshot/features/downloads/presentation/providers/downloads_providers.dart';
import 'package:earshot/features/subscriptions/data/podcast_exception.dart';
import 'package:earshot/features/subscriptions/data/podcast_repository.dart';
import 'package:earshot/features/subscriptions/domain/episode.dart';
import 'package:earshot/features/subscriptions/domain/podcast.dart';
import 'package:earshot/features/subscriptions/presentation/providers/subscriptions_providers.dart';
import 'package:earshot/features/subscriptions/presentation/screens/add_podcast_screen.dart';
import 'package:earshot/features/subscriptions/presentation/screens/podcast_detail_screen.dart';
import 'package:earshot/features/subscriptions/presentation/screens/subscriptions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

class MockPodcastRepository extends Mock implements PodcastRepository {}

class MockDownloadManager extends Mock implements DownloadManager {}

final _now = DateTime(2024, 6, 1);

Podcast _fakePodcast({
  int id = 1,
  String title = 'Test Podcast',
  String? author = 'Jane Smith',
}) => Podcast(
  id: id,
  rssUrl: 'https://example.com/feed.xml',
  title: title,
  author: author,
  autoQueue: false,
  notificationEnabled: false,
  createdAt: _now,
);

Episode _fakeEpisode({int id = 1}) => Episode(
  id: id,
  podcastId: 1,
  guid: 'ep-$id',
  title: 'Episode $id',
  audioUrl: 'https://example.com/ep$id.mp3',
  status: EpisodeStatus.newEpisode,
  downloadStatus: DownloadStatus.none,
  positionSeconds: 0,
  createdAt: _now,
  durationSeconds: 3600,
  pubDate: DateTime(2024, 1, id),
);

Widget _buildApp(Widget child, MockPodcastRepository repo) {
  // Wrap in a minimal GoRouter so context.push/go calls work in tests.
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, __) => child),
      GoRoute(
        path: '/subscriptions/:id',
        builder: (_, state) => PodcastDetailScreen(
          podcastId: int.parse(state.pathParameters['id']!),
        ),
      ),
      GoRoute(
        path: '/add-podcast',
        builder: (_, __) => const AddPodcastScreen(),
      ),
      GoRoute(path: '/search', builder: (_, __) => const Scaffold()),
      GoRoute(path: '/settings', builder: (_, __) => const Scaffold()),
    ],
  );
  return ProviderScope(
    overrides: [
      podcastRepositoryProvider.overrideWithValue(repo),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  late MockPodcastRepository repo;

  setUp(() {
    repo = MockPodcastRepository();
  });

  group('SubscriptionsScreen', () {
    testWidgets('shows empty state when no subscriptions', (tester) async {
      when(() => repo.watchSubscriptions()).thenAnswer((_) => Stream.value([]));

      await tester.pumpWidget(_buildApp(const SubscriptionsScreen(), repo));
      await tester.pump();

      expect(find.text('No podcasts yet'), findsOneWidget);
      expect(find.text('Add your first podcast'), findsOneWidget);
    });

    testWidgets('shows podcast list when subscriptions exist', (tester) async {
      when(
        () => repo.watchSubscriptions(),
      ).thenAnswer((_) => Stream.value([_fakePodcast()]));

      await tester.pumpWidget(_buildApp(const SubscriptionsScreen(), repo));
      await tester.pump();

      expect(find.text('Test Podcast'), findsOneWidget);
      expect(find.text('Jane Smith'), findsOneWidget);
    });

    testWidgets('podcast list tile has semantic label with author', (
      tester,
    ) async {
      when(
        () => repo.watchSubscriptions(),
      ).thenAnswer((_) => Stream.value([_fakePodcast()]));

      await tester.pumpWidget(_buildApp(const SubscriptionsScreen(), repo));
      await tester.pump();

      // The tile uses Semantics + ExcludeSemantics; find by the label directly.
      expect(
        find.bySemanticsLabel('Test Podcast, by Jane Smith'),
        findsOneWidget,
      );
    });

    testWidgets('FAB has accessible label', (tester) async {
      when(() => repo.watchSubscriptions()).thenAnswer((_) => Stream.value([]));

      await tester.pumpWidget(_buildApp(const SubscriptionsScreen(), repo));
      await tester.pump();

      // Verify the FAB tooltip is set — this is what VoiceOver announces.
      final fabNode = tester.getSemantics(find.byType(FloatingActionButton));
      expect(fabNode.tooltip, 'Add podcast');
    });

    testWidgets('tapping podcast navigates to detail screen', (tester) async {
      when(
        () => repo.watchSubscriptions(),
      ).thenAnswer((_) => Stream.value([_fakePodcast()]));
      when(
        () => repo.watchPodcast(1),
      ).thenAnswer((_) => Stream.value(_fakePodcast()));
      when(() => repo.watchEpisodes(1)).thenAnswer((_) => Stream.value([]));

      await tester.pumpWidget(_buildApp(const SubscriptionsScreen(), repo));
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Test Podcast, by Jane Smith'));
      await tester.pumpAndSettle();

      expect(find.byType(PodcastDetailScreen), findsOneWidget);
    });

    testWidgets('tapping FAB navigates to add podcast screen', (tester) async {
      when(() => repo.watchSubscriptions()).thenAnswer((_) => Stream.value([]));

      await tester.pumpWidget(_buildApp(const SubscriptionsScreen(), repo));
      await tester.pump();
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.byType(AddPodcastScreen), findsOneWidget);
    });
  });

  group('AddPodcastScreen', () {
    testWidgets('submit button is enabled with a valid URL', (tester) async {
      await tester.pumpWidget(_buildApp(const AddPodcastScreen(), repo));

      await tester.enterText(
        find.byType(TextField),
        'https://example.com/feed.rss',
      );
      await tester.pump();

      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNotNull);
    });

    testWidgets('shows error when URL is empty on submit', (tester) async {
      await tester.pumpWidget(_buildApp(const AddPodcastScreen(), repo));

      await tester.tap(find.byType(FilledButton));
      await tester.pump();

      expect(find.text('Please enter a URL.'), findsOneWidget);
    });

    testWidgets('shows already-subscribed error message', (tester) async {
      when(
        () => repo.subscribe(any()),
      ).thenThrow(const PodcastAlreadySubscribedException('https://x.com'));

      await tester.pumpWidget(_buildApp(const AddPodcastScreen(), repo));
      await tester.enterText(
        find.byType(TextField),
        'https://x.com/feed.rss',
      );
      await tester.tap(find.byType(FilledButton));
      await tester.pump();

      expect(
        find.text("You're already subscribed to this podcast."),
        findsOneWidget,
      );
    });

    testWidgets('pops on successful subscribe', (tester) async {
      final podcast = _fakePodcast();
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final dlManager = MockDownloadManager();
      when(() => repo.subscribe(any())).thenAnswer((_) async => podcast);
      when(
        () => dlManager.downloadRecentEpisodes(any(), any()),
      ).thenAnswer((_) async {});
      when(
        () => repo.watchSubscriptions(),
      ).thenAnswer((_) => Stream.value([podcast]));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            podcastRepositoryProvider.overrideWithValue(repo),
            appDatabaseProvider.overrideWithValue(db),
            downloadManagerProvider.overrideWithValue(dlManager),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => const AddPodcastScreen(),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(AddPodcastScreen), findsOneWidget);

      await tester.enterText(
        find.byType(TextField),
        'https://example.com/feed.rss',
      );
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      expect(find.byType(AddPodcastScreen), findsNothing);
      await db.close();
    });
  });

  group('PodcastDetailScreen', () {
    testWidgets('shows podcast title in app bar', (tester) async {
      when(
        () => repo.watchPodcast(1),
      ).thenAnswer((_) => Stream.value(_fakePodcast()));
      when(() => repo.watchEpisodes(1)).thenAnswer((_) => Stream.value([]));

      await tester.pumpWidget(
        _buildApp(const PodcastDetailScreen(podcastId: 1), repo),
      );
      await tester.pump();

      expect(find.text('Test Podcast'), findsWidgets);
    });

    testWidgets('shows episode list', (tester) async {
      when(
        () => repo.watchPodcast(1),
      ).thenAnswer((_) => Stream.value(_fakePodcast()));
      when(
        () => repo.watchEpisodes(1),
      ).thenAnswer((_) => Stream.value([_fakeEpisode()]));

      await tester.pumpWidget(
        _buildApp(const PodcastDetailScreen(podcastId: 1), repo),
      );
      await tester.pump();

      expect(find.text('Episode 1'), findsOneWidget);
    });

    testWidgets('episodes section has accessible heading', (tester) async {
      when(
        () => repo.watchPodcast(1),
      ).thenAnswer((_) => Stream.value(_fakePodcast()));
      when(() => repo.watchEpisodes(1)).thenAnswer((_) => Stream.value([]));

      await tester.pumpWidget(
        _buildApp(const PodcastDetailScreen(podcastId: 1), repo),
      );
      await tester.pump();

      expect(
        tester.getSemantics(find.text('Episodes')),
        matchesSemantics(isHeader: true, label: 'Episodes'),
      );
    });

    testWidgets('episode tile has semantic label with duration', (
      tester,
    ) async {
      when(
        () => repo.watchPodcast(1),
      ).thenAnswer((_) => Stream.value(_fakePodcast()));
      when(
        () => repo.watchEpisodes(1),
      ).thenAnswer((_) => Stream.value([_fakeEpisode()]));

      await tester.pumpWidget(
        _buildApp(const PodcastDetailScreen(podcastId: 1), repo),
      );
      await tester.pump();

      final semantics = tester.getSemantics(find.text('Episode 1'));
      expect(semantics.label, contains('Episode 1'));
      expect(semantics.label, contains('1 hr'));
    });
  });
}
