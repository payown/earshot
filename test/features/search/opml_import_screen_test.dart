import 'dart:async';
import 'dart:io';

import 'package:earshot/core/sharing/shared_file_provider.dart';
import 'package:earshot/core/sharing/sharing_intent_gateway.dart';
import 'package:earshot/features/search/presentation/screens/opml_import_screen.dart';
import 'package:earshot/features/subscriptions/data/podcast_exception.dart';
import 'package:earshot/features/subscriptions/data/podcast_repository.dart';
import 'package:earshot/features/subscriptions/domain/podcast.dart';
import 'package:earshot/features/subscriptions/presentation/providers/subscriptions_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockPodcastRepository extends Mock implements PodcastRepository {}

class _FakeGateway implements SharingIntentGateway {
  @override
  Future<List<String>> getInitialSharedFiles() async => const [];

  @override
  Stream<List<String>> get sharedFileStream => const Stream.empty();
}

const _opmlTemplate = '''
<?xml version="1.0" encoding="UTF-8"?>
<opml version="2.0">
  <head><title>Subscriptions</title></head>
  <body>
{outlines}
  </body>
</opml>
''';

String _opmlFor(List<String> feedUrls) {
  final outlines = feedUrls
      .map(
        (url) =>
            '    <outline type="rss" text="Feed" title="Feed" xmlUrl="$url"/>',
      )
      .join('\n');
  return _opmlTemplate.replaceFirst('{outlines}', outlines);
}

Podcast _fakePodcast(String rssUrl) => Podcast(
  id: 1,
  rssUrl: rssUrl,
  title: 'Feed',
  autoQueue: false,
  notificationEnabled: false,
  inboxExcluded: false,
  inboxIncluded: false,
  createdAt: DateTime(2024, 1, 1),
);

Widget _buildApp(MockPodcastRepository repo, List<String> sharedPaths) {
  return ProviderScope(
    overrides: [
      podcastRepositoryProvider.overrideWithValue(repo),
      sharingIntentGatewayProvider.overrideWithValue(_FakeGateway()),
      initialSharedOpmlPathsProvider.overrideWithValue(sharedPaths),
    ],
    child: const MaterialApp(home: OpmlImportScreen()),
  );
}

void main() {
  late MockPodcastRepository repo;
  late Directory tempDir;

  setUp(() async {
    repo = MockPodcastRepository();
    tempDir = await Directory.systemTemp.createTemp('opml_import_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('OpmlImportScreen shared-file queue', () {
    testWidgets('auto-imports a single shared OPML file on entry', (
      tester,
    ) async {
      final file = File('${tempDir.path}/shared.opml');
      await tester.runAsync(
        () => file.writeAsString(_opmlFor(['https://example.com/feed.xml'])),
      );

      when(
        () => repo.subscribe('https://example.com/feed.xml'),
      ).thenAnswer((_) async => _fakePodcast('https://example.com/feed.xml'));

      await tester.runAsync(() async {
        await tester.pumpWidget(_buildApp(repo, [file.path]));
        for (var i = 0; i < 25; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();

      verify(() => repo.subscribe('https://example.com/feed.xml')).called(1);
      expect(
        find.textContaining('Import complete: 1 followed'),
        findsOneWidget,
      );
    });

    testWidgets('processes multiple shared files sequentially', (
      tester,
    ) async {
      final fileA = File('${tempDir.path}/a.opml');
      final fileB = File('${tempDir.path}/b.opml');
      await tester.runAsync(() async {
        await fileA.writeAsString(_opmlFor(['https://example.com/a.xml']));
        await fileB.writeAsString(_opmlFor(['https://example.com/b.xml']));
      });

      when(
        () => repo.subscribe(any()),
      ).thenAnswer(
        (i) async => _fakePodcast(i.positionalArguments.first as String),
      );

      await tester.runAsync(() async {
        await tester.pumpWidget(_buildApp(repo, [fileA.path, fileB.path]));
        for (var i = 0; i < 50; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();

      verify(() => repo.subscribe('https://example.com/a.xml')).called(1);
      verify(() => repo.subscribe('https://example.com/b.xml')).called(1);
      expect(
        find.textContaining('Import complete: 1 followed'),
        findsOneWidget,
      );
    });

    testWidgets('already-subscribed feeds are counted as skipped', (
      tester,
    ) async {
      final file = File('${tempDir.path}/shared.opml');
      await tester.runAsync(
        () => file.writeAsString(_opmlFor(['https://example.com/feed.xml'])),
      );

      when(() => repo.subscribe('https://example.com/feed.xml')).thenThrow(
        const PodcastAlreadySubscribedException('https://example.com/feed.xml'),
      );

      await tester.runAsync(() async {
        await tester.pumpWidget(_buildApp(repo, [file.path]));
        for (var i = 0; i < 25; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();

      expect(
        find.textContaining('1 already following'),
        findsOneWidget,
      );
    });

    testWidgets('does nothing when no shared file is pending', (
      tester,
    ) async {
      await tester.pumpWidget(_buildApp(repo, const []));
      await tester.pumpAndSettle();

      verifyNever(() => repo.subscribe(any()));
      expect(find.text('Choose OPML file'), findsOneWidget);
    });
  });
}
