import 'package:earshot/core/presentation/widgets/episode_actions_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Pumps a button that opens the shared sheet with [actions] when tapped.
  Future<void> openSheet(
    WidgetTester tester,
    List<EpisodeQuickActionItem> actions, {
    String episodeTitle = 'Episode 1',
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showEpisodeActionsSheet(
                context,
                episodeTitle: episodeTitle,
                actions: actions,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('renders a row for every action', (tester) async {
    await openSheet(tester, [
      EpisodeQuickActionItem(label: 'Play now', onInvoke: () {}),
      EpisodeQuickActionItem(label: 'Download', onInvoke: () {}),
      EpisodeQuickActionItem(
        label: 'Remove from queue',
        onInvoke: () {},
        destructive: true,
      ),
    ]);

    expect(find.text('Play now'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Remove from queue'), findsOneWidget);
  });

  testWidgets('destructive rows render in the error color, others do not', (
    tester,
  ) async {
    await openSheet(tester, [
      EpisodeQuickActionItem(label: 'Play now', onInvoke: () {}),
      EpisodeQuickActionItem(
        label: 'Remove from queue',
        onInvoke: () {},
        destructive: true,
      ),
    ]);

    final destructive = tester.widget<Text>(find.text('Remove from queue'));
    final regular = tester.widget<Text>(find.text('Play now'));
    final errorColor = Theme.of(
      tester.element(find.text('Remove from queue')),
    ).colorScheme.error;

    expect(destructive.style?.color, errorColor);
    expect(regular.style?.color, isNull);
  });

  testWidgets('tapping a row pops the sheet then invokes the action', (
    tester,
  ) async {
    var invoked = false;
    await openSheet(tester, [
      EpisodeQuickActionItem(
        label: 'Remove from queue',
        onInvoke: () => invoked = true,
        destructive: true,
      ),
    ]);

    await tester.tap(find.text('Remove from queue'));
    await tester.pumpAndSettle();

    expect(invoked, isTrue);
    expect(find.text('Remove from queue'), findsNothing);
  });
}
