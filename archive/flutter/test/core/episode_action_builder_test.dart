import 'package:earshot/core/episode_action_builder.dart';
import 'package:earshot/core/presentation/widgets/episode_actions_sheet.dart';
import 'package:earshot/data/db/enums.dart';
import 'package:earshot/features/settings/domain/quick_action_definition.dart';
import 'package:earshot/features/subscriptions/domain/episode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Episode _episode({String? description, int positionSeconds = 0}) => Episode(
  id: 1,
  podcastId: 1,
  guid: 'g',
  title: 'My Episode',
  audioUrl: 'https://example.com/a.mp3',
  artworkUrl: null,
  status: EpisodeStatus.newEpisode,
  downloadStatus: DownloadStatus.none,
  positionSeconds: positionSeconds,
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

/// Builds episode actions with the given [order]/[actionContext] and returns
/// their labels.
Future<List<String>> _labelsFor(
  WidgetTester tester,
  List<EpisodeAction> order, {
  EpisodeActionContext actionContext = EpisodeActionContext.list,
  int positionSeconds = 0,
}) async {
  late List<String> labels;
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              labels = buildEpisodeActions(
                episode: _episode(positionSeconds: positionSeconds),
                order: order,
                context: context,
                ref: ref,
                onPlay: () {},
                actionContext: actionContext,
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

  testWidgets('queue context offers everything except queue-positioning', (
    tester,
  ) async {
    // The queue gets the full configured set so the user's edits show up here
    // too — only Play next / Add to end of queue are dropped, because the queue
    // has its own dedicated Move/Remove controls for those.
    final labels = await _labelsFor(
      tester,
      defaultEpisodeActions,
      actionContext: EpisodeActionContext.queue,
      positionSeconds: 120,
    );
    expect(labels, [
      'Play now',
      'Mark as played',
      'Open show notes',
      'Bookmark current spot',
      'Download',
      'Share',
      'Export audio file',
    ]);
    expect(labels, isNot(contains('Play next')));
    expect(labels, isNot(contains('Add to end of queue')));
  });

  testWidgets('list context offers Bookmark only when there is a position', (
    tester,
  ) async {
    final atZero = await _labelsFor(tester, const [EpisodeAction.bookmark]);
    expect(atZero, isEmpty);

    final inProgress = await _labelsFor(
      tester,
      const [EpisodeAction.bookmark],
      positionSeconds: 120,
    );
    expect(inProgress, ['Bookmark current spot']);
  });

  test('exportAudio is part of the default episode action set', () {
    expect(defaultEpisodeActions, contains(EpisodeAction.exportAudio));
  });

  test('list and queue share the same relative order for common actions', () {
    // The eligible sets differ by context, but both derive from the one
    // configured order, so shared actions never reorder between screens.
    final ep = _episode(positionSeconds: 120);
    final list = allowedEpisodeActions(EpisodeActionContext.list, ep);
    final queue = allowedEpisodeActions(EpisodeActionContext.queue, ep);
    final listOrder = defaultEpisodeActions.where(list.contains).toList();
    final queueOrder = defaultEpisodeActions.where(queue.contains).toList();
    expect(
      listOrder.where(queue.contains).toList(),
      queueOrder,
      reason: 'shared actions keep the same order across contexts',
    );
  });

  test(
    'rotor labels follow the configured order, variants adjacent, moves last',
    () {
      final labels = episodeActionRotorLabels(const [
        EpisodeAction.openShowNotes,
        EpisodeAction.download,
        EpisodeAction.playNow,
      ]);
      expect(labels, [
        'Open show notes',
        'Download',
        'Remove download',
        'Cancel download',
        'Retry download',
        'Play now',
        'Move to top',
        'Move up',
        'Move down',
        'Move to bottom',
      ]);
    },
  );

  test(
    'every EpisodeAction has rotor variant labels including its base label',
    () {
      for (final a in EpisodeAction.values) {
        final variants = episodeActionVariantLabels[a];
        expect(variants, isNotNull, reason: '$a missing from variant map');
        expect(variants, contains(a.label), reason: '$a base label missing');
      }
    },
  );

  test('rotor seed covers every label an action can emit', () {
    // Every label buildEpisodeActions / _buildItem and the Queue move actions
    // can produce, including dynamic variants. If any is missing from the seed
    // order, that action lands in an arbitrary rotor slot — silently breaking
    // the consistency seedEpisodeActionRotorOrder exists to guarantee.
    final all = episodeActionRotorLabels(EpisodeAction.values.toList());
    final emittable = <String>{
      for (final a in EpisodeAction.values) a.label,
      'Move to play next', // playNext when already queued
      'Remove from queue', // addToEndOfQueue when queued + queue move action
      'Mark as unplayed', // markPlayed when already played
      'Remove download', 'Cancel download', 'Retry download', // download states
      'Move to top', 'Move up', 'Move down', 'Move to bottom', // queue moves
    };
    for (final label in emittable) {
      expect(
        all,
        contains(label),
        reason:
            '"$label" can be emitted but is missing from the rotor seed '
            'order, which silently breaks VoiceOver rotor consistency',
      );
    }
  });

  test('orderEpisodeActionItems honors the configured order', () {
    EpisodeQuickActionItem item(String label) =>
        EpisodeQuickActionItem(label: label, onInvoke: () {});
    final available = {
      EpisodeAction.playNow: item('Play now'),
      EpisodeAction.openShowNotes: item('Open show notes'),
      EpisodeAction.share: item('Share'),
    };

    // Order that moves Share first; markPlayed is absent from `available` and
    // is skipped rather than throwing.
    final ordered = orderEpisodeActionItems(const [
      EpisodeAction.share,
      EpisodeAction.markPlayed,
      EpisodeAction.playNow,
      EpisodeAction.openShowNotes,
    ], available);

    expect(ordered.map((a) => a.label).toList(), [
      'Share',
      'Play now',
      'Open show notes',
    ]);
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
