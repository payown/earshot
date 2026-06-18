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

  testWidgets('every destination meets the 48dp minimum tap height', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(selectedIndex: 0));

    final taps = find.byType(InkWell);
    expect(taps, findsNWidgets(4));
    for (final tap in taps.evaluate()) {
      expect(
        tester.getSize(find.byWidget(tap.widget)).height,
        greaterThanOrEqualTo(48.0),
      );
    }
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
