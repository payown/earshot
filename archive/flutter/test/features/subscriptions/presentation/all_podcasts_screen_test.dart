import 'package:earshot/features/folders/data/folder_repository.dart';
import 'package:earshot/features/folders/presentation/providers/folders_providers.dart';
import 'package:earshot/features/settings/domain/quick_action_definition.dart';
import 'package:earshot/features/settings/presentation/providers/settings_providers.dart';
import 'package:earshot/features/subscriptions/data/podcast_repository.dart';
import 'package:earshot/features/subscriptions/domain/podcast.dart';
import 'package:earshot/features/subscriptions/presentation/providers/subscriptions_providers.dart';
import 'package:earshot/features/subscriptions/presentation/screens/all_podcasts_screen.dart';
import 'package:earshot/features/subscriptions/presentation/screens/podcast_detail_screen.dart';
import 'package:earshot/features/subscriptions/presentation/widgets/alphabet_index_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

class MockPodcastRepository extends Mock implements PodcastRepository {}

class MockFolderRepository extends Mock implements FolderRepository {}

final _now = DateTime(2024, 6, 1);

Podcast _fakePodcast({int id = 1, String title = 'Test Podcast'}) => Podcast(
  id: id,
  rssUrl: 'https://example.com/feed.xml',
  title: title,
  author: 'Jane Smith',
  autoQueue: false,
  notificationEnabled: false,
  inboxExcluded: false,
  inboxIncluded: false,
  createdAt: _now,
);

Widget _buildApp(MockPodcastRepository repo) {
  final fr = MockFolderRepository();
  when(() => fr.watchFolders()).thenAnswer((_) => Stream.value([]));
  when(
    () => fr.watchPodcastsInFolder(any()),
  ).thenAnswer((_) => Stream.value([]));

  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, __) => const AllPodcastsScreen()),
      GoRoute(
        path: '/subscriptions/:id',
        builder: (_, state) => PodcastDetailScreen(
          podcastId: int.parse(state.pathParameters['id']!),
        ),
      ),
      GoRoute(path: '/settings', builder: (_, __) => const Scaffold()),
    ],
  );

  return ProviderScope(
    overrides: [
      podcastRepositoryProvider.overrideWithValue(repo),
      folderRepositoryProvider.overrideWithValue(fr),
      podcastActionsProvider.overrideWith(
        (_) => Stream.value(defaultPodcastActions),
      ),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  late MockPodcastRepository repo;

  setUp(() {
    repo = MockPodcastRepository();
  });

  group('AllPodcastsScreen', () {
    testWidgets('shows loading indicator while data loads', (tester) async {
      when(
        () => repo.watchSubscriptions(),
      ).thenAnswer((_) => const Stream.empty());

      await tester.pumpWidget(_buildApp(repo));
      // Do not pump — stream hasn't emitted yet.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('shows empty state when no podcasts', (tester) async {
      when(
        () => repo.watchSubscriptions(),
      ).thenAnswer((_) => Stream.value([]));

      await tester.pumpWidget(_buildApp(repo));
      await tester.pump();

      expect(find.text('No podcasts yet.'), findsOneWidget);
    });

    testWidgets('shows podcast list when subscriptions exist', (tester) async {
      when(
        () => repo.watchSubscriptions(),
      ).thenAnswer((_) => Stream.value([_fakePodcast()]));

      await tester.pumpWidget(_buildApp(repo));
      await tester.pump();

      expect(find.text('Test Podcast'), findsOneWidget);
    });

    testWidgets(
      'alphabet index is an adjustable element starting at the first letter',
      (tester) async {
        final handle = tester.ensureSemantics();

        when(() => repo.watchSubscriptions()).thenAnswer(
          (_) => Stream.value([
            _fakePodcast(id: 1, title: 'Apple Cast'),
            _fakePodcast(id: 2, title: 'Banana Cast'),
          ]),
        );

        await tester.pumpWidget(_buildApp(repo));
        await tester.pumpAndSettle();

        final node = tester.getSemantics(
          find.bySemanticsLabel('Alphabet index'),
        );
        expect(node.value, 'A, 1 podcast');

        RendererBinding.instance.renderViews.first.owner!.semanticsOwner!
            .performAction(
              node.id,
              SemanticsAction.increase,
            );
        await tester.pump();

        final updated = tester.getSemantics(
          find.bySemanticsLabel('Alphabet index'),
        );
        expect(updated.value, 'B, 1 podcast');

        handle.dispose();
      },
    );

    testWidgets(
      'tapping a letter in the index scrolls its podcasts into view',
      (
        tester,
      ) async {
        // Use a taller viewport so all 26 index letters are on-screen at once,
        // matching a real phone rather than the small default test surface.
        tester.view.physicalSize = const Size(800, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final letters = List.generate(26, (i) => String.fromCharCode(65 + i));
        when(() => repo.watchSubscriptions()).thenAnswer(
          (_) => Stream.value([
            for (var i = 0; i < letters.length; i++)
              _fakePodcast(id: i + 1, title: '${letters[i]} Show'),
          ]),
        );

        await tester.pumpWidget(_buildApp(repo));
        await tester.pumpAndSettle();

        expect(find.text('Z Show'), findsNothing);

        await tester.tap(
          find.descendant(
            of: find.byType(AlphabetIndexBar),
            matching: find.text('Z'),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Z Show'), findsOneWidget);
      },
    );

    testWidgets('shows user-friendly message on error', (tester) async {
      when(
        () => repo.watchSubscriptions(),
      ).thenAnswer((_) => Stream.error(Exception('network error')));

      await tester.pumpWidget(_buildApp(repo));
      await tester.pumpAndSettle();

      expect(find.text('Something went wrong.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      // Raw exception text must not be shown directly in the UI.
      expect(find.text('Error: Exception: network error'), findsNothing);
    });

    testWidgets('tapping podcast navigates to detail screen', (tester) async {
      when(
        () => repo.watchSubscriptions(),
      ).thenAnswer((_) => Stream.value([_fakePodcast()]));
      when(
        () => repo.watchPodcast(1),
      ).thenAnswer((_) => Stream.value(_fakePodcast()));
      when(() => repo.watchEpisodes(1)).thenAnswer((_) => Stream.value([]));

      await tester.pumpWidget(_buildApp(repo));
      await tester.pump();

      await tester.tap(find.bySemanticsLabel('Test Podcast, by Jane Smith'));
      await tester.pumpAndSettle();

      expect(find.byType(PodcastDetailScreen), findsOneWidget);
    });

    testWidgets('settings button is present in app bar', (tester) async {
      when(
        () => repo.watchSubscriptions(),
      ).thenAnswer((_) => Stream.value([]));

      await tester.pumpWidget(_buildApp(repo));
      await tester.pump();

      expect(
        find.byTooltip('Settings'),
        findsOneWidget,
      );
    });
  });
}
