import 'package:earshot/core/presentation/widgets/episode_actions_sheet.dart';
import 'package:earshot/core/theme/app_theme.dart';
import 'package:earshot/data/db/enums.dart';
import 'package:earshot/features/subscriptions/domain/episode.dart';
import 'package:earshot/features/subscriptions/presentation/widgets/episode_list_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Automated accessibility-guideline coverage for the shared episode tile used
// across the Inbox, Queue, and Library. These assertions guard tap-target size,
// tappable-node labeling, and text contrast against the real app themes so a
// future change that shrinks a target, drops a label, or lowers contrast fails
// CI instead of silently regressing (#299).

Episode _episode({EpisodeStatus status = EpisodeStatus.newEpisode}) => Episode(
  id: 1,
  podcastId: 1,
  guid: 'ep-1',
  title: 'A reasonably long episode title that wraps to two lines on screen',
  audioUrl: 'https://example.com/ep1.mp3',
  artworkUrl: null,
  status: status,
  downloadStatus: DownloadStatus.none,
  positionSeconds: 0,
  createdAt: DateTime(2024, 6, 1),
  durationSeconds: 3600,
  pubDate: DateTime(2024, 1, 1),
);

Widget _wrap(ThemeData theme, {required List<EpisodeQuickActionItem> actions}) {
  return MaterialApp(
    theme: theme,
    home: Scaffold(
      body: ListView(
        children: [EpisodeListTile(episode: _episode(), quickActions: actions)],
      ),
    ),
  );
}

void main() {
  final themes = <String, ThemeData>{
    'light': AppTheme.light(),
    'dark': AppTheme.dark(),
    'high contrast light': AppTheme.highContrastLight(),
    'high contrast dark': AppTheme.highContrastDark(),
  };

  group('EpisodeListTile meets accessibility guidelines', () {
    for (final entry in themes.entries) {
      testWidgets('${entry.key} theme — single action (default tap)', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(
          _wrap(
            entry.value,
            actions: [
              EpisodeQuickActionItem(label: 'Play now', onInvoke: () {}),
            ],
          ),
        );

        await expectLater(tester, meetsGuideline(textContrastGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));

        handle.dispose();
      });

      testWidgets('${entry.key} theme — multiple actions (more button)', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(
          _wrap(
            entry.value,
            actions: [
              EpisodeQuickActionItem(label: 'Play now', onInvoke: () {}),
              EpisodeQuickActionItem(label: 'Add to queue', onInvoke: () {}),
            ],
          ),
        );

        await expectLater(tester, meetsGuideline(textContrastGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));

        handle.dispose();
      });
    }
  });
}
