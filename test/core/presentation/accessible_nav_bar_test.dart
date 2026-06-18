import 'package:earshot/core/presentation/widgets/accessible_nav_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const destinations = <AccessibleNavDestination>[
    AccessibleNavDestination(
      icon: Icons.inbox_outlined,
      selectedIcon: Icons.inbox,
      label: 'Inbox',
      semanticLabel: 'Inbox, 3 new',
      badgeCount: 3,
    ),
    AccessibleNavDestination(
      icon: Icons.queue_music_outlined,
      selectedIcon: Icons.queue_music,
      label: 'Queue',
    ),
    AccessibleNavDestination(
      icon: Icons.podcasts_outlined,
      selectedIcon: Icons.podcasts,
      label: 'Library',
    ),
    AccessibleNavDestination(
      icon: Icons.download_outlined,
      selectedIcon: Icons.download,
      label: 'Downloads',
    ),
  ];

  Widget wrap({
    required int selectedIndex,
    ValueChanged<int>? onSelected,
    List<AccessibleNavDestination> items = destinations,
  }) {
    return MaterialApp(
      home: Scaffold(
        bottomNavigationBar: AccessibleNavBar(
          selectedIndex: selectedIndex,
          destinations: items,
          onDestinationSelected: onSelected ?? (_) {},
        ),
      ),
    );
  }

  testWidgets('inbox tab speaks "Inbox, N new" and never the bare count', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(wrap(selectedIndex: 0));

    expect(find.bySemanticsLabel('Inbox, 3 new'), findsOneWidget);
    // The visible badge count must not be a separately spoken node.
    expect(find.bySemanticsLabel('3'), findsNothing);

    handle.dispose();
  });

  testWidgets('no destination injects the literal "Tab N of M" string', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(wrap(selectedIndex: 0));

    expect(find.bySemanticsLabel(RegExp('Tab')), findsNothing);

    handle.dispose();
  });

  testWidgets('selected destination carries the isSelected semantics flag', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(wrap(selectedIndex: 1));

    expect(
      tester.getSemantics(find.bySemanticsLabel('Queue')),
      isSemantics(isSelected: true),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Inbox, 3 new')),
      isSemantics(isSelected: false),
    );

    handle.dispose();
  });

  testWidgets('destinations are not exposed with the button trait', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(wrap(selectedIndex: 0));

    expect(
      tester.getSemantics(find.bySemanticsLabel('Inbox, 3 new')),
      isSemantics(isButton: false),
    );

    handle.dispose();
  });

  testWidgets('each destination carries the tab role', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(wrap(selectedIndex: 0));

    expect(
      tester.getSemantics(find.bySemanticsLabel('Inbox, 3 new')).role,
      SemanticsRole.tab,
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Queue')).role,
      SemanticsRole.tab,
    );

    handle.dispose();
  });

  testWidgets('the bar container carries the tabBar role', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(wrap(selectedIndex: 0));

    expect(
      tester.getSemantics(find.byType(AccessibleNavBar)).role,
      SemanticsRole.tabBar,
    );

    handle.dispose();
  });

  testWidgets(
    'every destination holds the 48dp floor even at tiny text scale',
    (
      tester,
    ) async {
      // A small text scale shrinks the natural content below 48dp, so the test
      // genuinely exercises the minHeight floor rather than incidental height.
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(0.1)),
            child: Scaffold(
              bottomNavigationBar: AccessibleNavBar(
                selectedIndex: 0,
                destinations: destinations,
                onDestinationSelected: (_) {},
              ),
            ),
          ),
        ),
      );

      final taps = find.byType(InkWell);
      expect(taps, findsNWidgets(4));
      for (final tap in taps.evaluate()) {
        expect(
          tester.getSize(find.byWidget(tap.widget)).height,
          greaterThanOrEqualTo(48.0),
        );
      }
    },
  );

  testWidgets('the semantics tap action fires the callback exactly once', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var calls = 0;
    await tester.pumpWidget(
      wrap(selectedIndex: 0, onSelected: (_) => calls++),
    );

    tester.semantics.tap(find.semantics.byLabel('Library'));
    await tester.pump();

    expect(calls, 1);
    handle.dispose();
  });

  testWidgets('a large badge count collapses the visible badge to "99+"', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        selectedIndex: 0,
        items: const [
          AccessibleNavDestination(
            icon: Icons.inbox_outlined,
            selectedIcon: Icons.inbox,
            label: 'Inbox',
            semanticLabel: 'Inbox, 247 new',
            badgeCount: 247,
          ),
        ],
      ),
    );

    expect(find.text('99+'), findsOneWidget);
    expect(find.text('247'), findsNothing);
  });

  testWidgets('tapping a destination reports its index', (tester) async {
    int? selected;
    await tester.pumpWidget(
      wrap(selectedIndex: 0, onSelected: (i) => selected = i),
    );

    await tester.tap(find.text('Library'));
    expect(selected, 2);
  });

  testWidgets('a zero badge count shows the plain label', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      wrap(
        selectedIndex: 0,
        items: const [
          AccessibleNavDestination(
            icon: Icons.inbox_outlined,
            selectedIcon: Icons.inbox,
            label: 'Inbox',
            semanticLabel: 'Inbox',
          ),
        ],
      ),
    );

    expect(find.bySemanticsLabel('Inbox'), findsOneWidget);

    handle.dispose();
  });
}
