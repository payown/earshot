import 'package:earshot/core/episode_action_builder.dart';
import 'package:earshot/data/db/enums.dart';
import 'package:earshot/features/settings/domain/quick_action_definition.dart';
import 'package:earshot/features/subscriptions/domain/episode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Episode _episode({String? description}) => Episode(
  id: 1,
  podcastId: 1,
  guid: 'g',
  title: 'My Episode',
  audioUrl: 'https://example.com/a.mp3',
  artworkUrl: null,
  status: EpisodeStatus.newEpisode,
  downloadStatus: DownloadStatus.none,
  positionSeconds: 0,
  createdAt: DateTime(2024, 1, 1),
  durationSeconds: 60,
  pubDate: DateTime(2024, 1, 1),
  description: description,
);

// Pumps a widget that builds the openShowNotes action and exposes it on a
// button, so tapping it invokes the real action with a live context.
Future<void> _pumpWithShowNotes(WidgetTester tester, Episode episode) {
  return tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              final actions = buildEpisodeActions(
                episode: episode,
                order: const [EpisodeAction.openShowNotes],
                context: context,
                ref: ref,
                onPlay: () {},
              );
              return ElevatedButton(
                onPressed: actions.first.onInvoke,
                child: const Text('open'),
              );
            },
          ),
        ),
      ),
    ),
  );
}

/// Builds episode actions with the given [order] and returns their labels.
Future<List<String>> _labelsFor(
  WidgetTester tester,
  List<EpisodeAction> order, {
  Set<EpisodeAction>? allowedActions,
}) async {
  late List<String> labels;
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              labels = buildEpisodeActions(
                episode: _episode(),
                order: order,
                context: context,
                ref: ref,
                onPlay: () {},
                allowedActions: allowedActions,
              ).map((a) => a.label).toList();
              return const SizedBox();
            },
          ),
        ),
      ),
    ),
  );
  return labels;
}

void main() {
  testWidgets('Export is a configurable action, surfaced via the enum order', (
    tester,
  ) async {
    final labels = await _labelsFor(tester, const [EpisodeAction.exportAudio]);
    expect(labels, ['Export audio file']);
  });

  testWidgets('Export is not force-appended when absent from the order', (
    tester,
  ) async {
    final labels = await _labelsFor(tester, const [EpisodeAction.playNow]);
    expect(labels, isNot(contains('Export audio file')));
  });

  testWidgets('Export obeys allowedActions like every other action', (
    tester,
  ) async {
    final labels = await _labelsFor(
      tester,
      const [EpisodeAction.playNow, EpisodeAction.exportAudio],
      allowedActions: const {EpisodeAction.playNow},
    );
    expect(labels, isNot(contains('Export audio file')));
  });

  test('exportAudio is part of the default episode action set', () {
    expect(defaultEpisodeActions, contains(EpisodeAction.exportAudio));
  });

  testWidgets('Open show notes opens an accessible dialog (#305)', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    try {
      await _pumpWithShowNotes(
        tester,
        _episode(description: '<p>The notes body</p>'),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // The description renders in the dialog.
      expect(find.textContaining('The notes body'), findsOneWidget);
      // The dialog carries the open-announcement label.
      expect(find.bySemanticsLabel('Show notes'), findsWidgets);
      // The episode title is exposed as a heading for heading navigation.
      expect(
        tester.getSemantics(find.bySemanticsLabel('My Episode')),
        matchesSemantics(isHeader: true, label: 'My Episode'),
      );
    } finally {
      handle.dispose();
    }
  });

  testWidgets('Open show notes handles a missing description', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await _pumpWithShowNotes(tester, _episode(description: null));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('No show notes available.'), findsOneWidget);
    } finally {
      handle.dispose();
    }
  });
}
