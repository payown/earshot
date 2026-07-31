import 'package:earshot/core/presentation/widgets/episode_actions_sheet.dart';
import 'package:earshot/data/db/enums.dart';
import 'package:earshot/features/subscriptions/domain/episode.dart';
import 'package:earshot/features/subscriptions/presentation/widgets/episode_list_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

Episode _episode() => Episode(
  id: 1,
  podcastId: 1,
  guid: 'ep-1',
  title: 'Episode 1',
  audioUrl: 'https://example.com/ep1.mp3',
  status: EpisodeStatus.newEpisode,
  downloadStatus: DownloadStatus.none,
  positionSeconds: 0,
  createdAt: DateTime(2024, 6, 1),
  durationSeconds: 3600,
  pubDate: DateTime(2024, 1, 1),
);

/// The labels of every custom (rotor) action exposed on [node].
Set<String> _customActionLabels(SemanticsNode node) {
  final ids = node.getSemanticsData().customSemanticsActionIds;
  if (ids == null) return {};
  return ids
      .map((id) => CustomSemanticsAction.getAction(id)?.label)
      .whereType<String>()
      .toSet();
}

Future<void> _pumpTile(
  WidgetTester tester,
  List<EpisodeQuickActionItem> actions,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: EpisodeListTile(episode: _episode(), quickActions: actions),
      ),
    ),
  );
}

void main() {
  testWidgets('a single action still exposes a rotor custom action', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await _pumpTile(tester, [
      EpisodeQuickActionItem(label: 'Play now', onInvoke: () {}),
    ]);

    final node = tester.getSemantics(
      find.bySemanticsLabel(RegExp('Episode 1')),
    );
    expect(_customActionLabels(node), contains('Play now'));

    handle.dispose();
  });

  testWidgets('a single action hides the more-actions button', (tester) async {
    await _pumpTile(tester, [
      EpisodeQuickActionItem(label: 'Play now', onInvoke: () {}),
    ]);

    expect(find.byTooltip('More actions'), findsNothing);
  });

  testWidgets('multiple actions show the more-actions button and full rotor', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await _pumpTile(tester, [
      EpisodeQuickActionItem(label: 'Play now', onInvoke: () {}),
      EpisodeQuickActionItem(label: 'Download', onInvoke: () {}),
    ]);

    expect(find.byTooltip('More actions'), findsOneWidget);
    final node = tester.getSemantics(
      find.bySemanticsLabel(RegExp('Episode 1')),
    );
    expect(_customActionLabels(node), containsAll(['Play now', 'Download']));

    handle.dispose();
  });
}
