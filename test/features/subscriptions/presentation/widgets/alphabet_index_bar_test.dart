import 'package:earshot/features/subscriptions/presentation/widgets/alphabet_index_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AlphabetIndexBar', () {
    testWidgets('renders no jump buttons when letters is empty', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AlphabetIndexBar(
              letters: const [],
              onLetterSelected: (_) {},
            ),
          ),
        ),
      );

      expect(find.bySemanticsLabel(RegExp('^Jump to')), findsNothing);
    });

    testWidgets('shows a Jump to <letter> button for each letter', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AlphabetIndexBar(
              letters: const ['A', 'B', 'Z'],
              onLetterSelected: (_) {},
            ),
          ),
        ),
      );

      expect(find.bySemanticsLabel('Jump to A'), findsOneWidget);
      expect(find.bySemanticsLabel('Jump to B'), findsOneWidget);
      expect(find.bySemanticsLabel('Jump to Z'), findsOneWidget);
    });

    testWidgets('tapping a letter invokes onLetterSelected', (tester) async {
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AlphabetIndexBar(
              letters: const ['A', 'B'],
              onLetterSelected: (letter) => selected = letter,
            ),
          ),
        ),
      );

      await tester.tap(find.bySemanticsLabel('Jump to B'));
      await tester.pump();

      expect(selected, 'B');
    });

    testWidgets('uses a friendly label for the # group', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AlphabetIndexBar(
              letters: const ['#', 'A'],
              onLetterSelected: (_) {},
            ),
          ),
        ),
      );

      expect(
        find.bySemanticsLabel(
          'Jump to podcasts starting with a number or symbol',
        ),
        findsOneWidget,
      );
    });

    testWidgets('does not require a Material ancestor', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(),
            child: AlphabetIndexBar(
              letters: const ['A', 'B'],
              onLetterSelected: (_) {},
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.bySemanticsLabel('Jump to A'), findsOneWidget);
    });
  });
}
