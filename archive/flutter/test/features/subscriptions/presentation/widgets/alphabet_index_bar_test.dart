import 'package:earshot/features/subscriptions/domain/alphabet_index.dart';
import 'package:earshot/features/subscriptions/presentation/widgets/alphabet_index_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _entryA = AlphabetIndexEntry(firstIndex: 0, count: 2);
const _entryB = AlphabetIndexEntry(firstIndex: 2, count: 1);
const _entryC = AlphabetIndexEntry(firstIndex: 3, count: 1);
const _entryHash = AlphabetIndexEntry(firstIndex: 0, count: 3);

void main() {
  group('AlphabetIndexBar', () {
    testWidgets('renders nothing when index is empty', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AlphabetIndexBar(index: const {}, onLetterSelected: (_) {}),
          ),
        ),
      );

      expect(find.bySemanticsLabel('Alphabet index'), findsNothing);
    });

    testWidgets('exposes a single adjustable node with the current letter', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AlphabetIndexBar(
              index: const {'A': _entryA, 'B': _entryB},
              onLetterSelected: (_) {},
            ),
          ),
        ),
      );

      final node = tester.getSemantics(find.bySemanticsLabel('Alphabet index'));
      expect(node.value, 'A, 2 podcasts');
      final data = node.getSemanticsData();
      expect(data.hasAction(SemanticsAction.increase), isTrue);
      expect(data.hasAction(SemanticsAction.decrease), isTrue);

      handle.dispose();
    });

    testWidgets(
      'increase moves to the next letter and notifies onLetterSelected',
      (tester) async {
        final handle = tester.ensureSemantics();

        AlphabetIndexEntry? selected;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AlphabetIndexBar(
                index: const {'A': _entryA, 'B': _entryB},
                onLetterSelected: (entry) => selected = entry,
              ),
            ),
          ),
        );

        final node = tester.getSemantics(
          find.bySemanticsLabel('Alphabet index'),
        );
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
        expect(selected, _entryB);

        handle.dispose();
      },
    );

    testWidgets('decrease at the first letter is a no-op', (tester) async {
      final handle = tester.ensureSemantics();

      var callCount = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AlphabetIndexBar(
              index: const {'A': _entryA, 'B': _entryB},
              onLetterSelected: (_) => callCount++,
            ),
          ),
        ),
      );

      final node = tester.getSemantics(find.bySemanticsLabel('Alphabet index'));
      RendererBinding.instance.renderViews.first.owner!.semanticsOwner!
          .performAction(
            node.id,
            SemanticsAction.decrease,
          );
      await tester.pump();

      final updated = tester.getSemantics(
        find.bySemanticsLabel('Alphabet index'),
      );
      expect(updated.value, 'A, 2 podcasts');
      expect(callCount, 0);
      expect(
        tester.takeAnnouncements(),
        contains(
          isAccessibilityAnnouncement('At the first letter, A, 2 podcasts.'),
        ),
      );

      handle.dispose();
    });

    testWidgets(
      'increase at the last letter is a no-op and announces the boundary',
      (tester) async {
        final handle = tester.ensureSemantics();

        var callCount = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AlphabetIndexBar(
                index: const {'A': _entryA, 'B': _entryB},
                onLetterSelected: (_) => callCount++,
              ),
            ),
          ),
        );

        final node = tester.getSemantics(
          find.bySemanticsLabel('Alphabet index'),
        );
        final semanticsOwner =
            RendererBinding.instance.renderViews.first.owner!.semanticsOwner!;

        // First increase moves from 'A' to the last letter, 'B'.
        semanticsOwner.performAction(node.id, SemanticsAction.increase);
        await tester.pump();
        expect(callCount, 1);
        tester.takeAnnouncements();

        // Second increase is a no-op at the last letter.
        semanticsOwner.performAction(node.id, SemanticsAction.increase);
        await tester.pump();

        final updated = tester.getSemantics(
          find.bySemanticsLabel('Alphabet index'),
        );
        expect(updated.value, 'B, 1 podcast');
        expect(callCount, 1);
        expect(
          tester.takeAnnouncements(),
          contains(
            isAccessibilityAnnouncement('At the last letter, B, 1 podcast.'),
          ),
        );

        handle.dispose();
      },
    );

    testWidgets(
      'announces when the focused letter is removed from the index',
      (tester) async {
        final handle = tester.ensureSemantics();

        var index = const {'A': _entryA, 'B': _entryB, 'C': _entryC};

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => Column(
                  children: [
                    Expanded(
                      child: AlphabetIndexBar(
                        index: index,
                        onLetterSelected: (_) {},
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(
                        () => index = const {'A': _entryA, 'B': _entryB},
                      ),
                      child: const Text('shrink'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        final node = tester.getSemantics(
          find.bySemanticsLabel('Alphabet index'),
        );
        final semanticsOwner =
            RendererBinding.instance.renderViews.first.owner!.semanticsOwner!;

        // Move focus to the last letter, 'C'.
        semanticsOwner.performAction(node.id, SemanticsAction.increase);
        await tester.pump();
        semanticsOwner.performAction(node.id, SemanticsAction.increase);
        await tester.pump();
        expect(
          tester.getSemantics(find.bySemanticsLabel('Alphabet index')).value,
          'C, 1 podcast',
        );
        tester.takeAnnouncements();

        await tester.tap(find.text('shrink'));
        await tester.pump();

        final updated = tester.getSemantics(
          find.bySemanticsLabel('Alphabet index'),
        );
        expect(updated.value, 'B, 1 podcast');
        expect(
          tester.takeAnnouncements(),
          contains(
            isAccessibilityAnnouncement('List updated. Now at B, 1 podcast.'),
          ),
        );

        handle.dispose();
      },
    );

    testWidgets(
      'collapses to a single semantics node even when the letter list is '
      'virtualized',
      (tester) async {
        final handle = tester.ensureSemantics();

        final index = <String, AlphabetIndexEntry>{
          '#': const AlphabetIndexEntry(firstIndex: 0, count: 1),
          for (var i = 0; i < 26; i++)
            String.fromCharCode(65 + i): AlphabetIndexEntry(
              firstIndex: i + 1,
              count: 1,
            ),
        };

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                height: 200,
                child: AlphabetIndexBar(index: index, onLetterSelected: (_) {}),
              ),
            ),
          ),
        );

        final node = tester.getSemantics(
          find.bySemanticsLabel('Alphabet index'),
        );
        final data = node.getSemanticsData();
        expect(data.hasAction(SemanticsAction.increase), isTrue);
        expect(data.hasAction(SemanticsAction.decrease), isTrue);
        expect(node.childrenCount, 0);

        handle.dispose();
      },
    );

    testWidgets('describes the # group as a number or symbol', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AlphabetIndexBar(
              index: const {'#': _entryHash, 'A': _entryA},
              onLetterSelected: (_) {},
            ),
          ),
        ),
      );

      final node = tester.getSemantics(find.bySemanticsLabel('Alphabet index'));
      expect(node.value, 'number or symbol, 3 podcasts');

      handle.dispose();
    });

    testWidgets('tapping a letter directly selects it', (tester) async {
      final handle = tester.ensureSemantics();

      AlphabetIndexEntry? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AlphabetIndexBar(
              index: const {'A': _entryA, 'B': _entryB},
              onLetterSelected: (entry) => selected = entry,
            ),
          ),
        ),
      );

      await tester.tap(find.text('B'));
      await tester.pump();

      expect(selected, _entryB);
      final node = tester.getSemantics(find.bySemanticsLabel('Alphabet index'));
      expect(node.value, 'B, 1 podcast');

      handle.dispose();
    });
  });
}
