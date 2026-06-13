import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Mirror of the private widget ─────────────────────────────────────────────
// Reproduces the semantics-relevant structure of _ShowNotesSection without
// requiring flutter_html or the full player setup.

class _TestShowNotesSection extends StatefulWidget {
  const _TestShowNotesSection();

  @override
  State<_TestShowNotesSection> createState() => _TestShowNotesSectionState();
}

class _TestShowNotesSectionState extends State<_TestShowNotesSection> {
  bool _expanded = false;

  void _toggle() {
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ExcludeSemantics(child: Divider(height: 1)),
        Semantics(
          button: true,
          expanded: _expanded,
          label: _expanded ? 'Show notes, expanded' : 'Show notes, collapsed',
          onTap: _toggle,
          child: ExcludeSemantics(
            child: GestureDetector(
              onTap: _toggle,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Show notes'),
              ),
            ),
          ),
        ),
        if (_expanded) const Text('Episode description goes here'),
      ],
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

SemanticsNode _findNode(WidgetTester tester, String label) =>
    tester.getSemantics(find.bySemanticsLabel(label));

void _performAction(
  WidgetTester tester,
  int nodeId,
  SemanticsAction action, [
  Object? args,
]) {
  RendererBinding.instance.renderViews.first.owner!.semanticsOwner!
      .performAction(nodeId, action, args);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('_ShowNotesSection', () {
    testWidgets('shows collapsed header label', (tester) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(_wrap(const _TestShowNotesSection()));

      expect(
        _findNode(tester, 'Show notes, collapsed'),
        matchesSemantics(
          label: 'Show notes, collapsed',
          isButton: true,
          hasExpandedState: true,
          hasTapAction: true,
        ),
      );

      handle.dispose();
    });

    testWidgets('tapping header expands section and updates label', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(_wrap(const _TestShowNotesSection()));

      final nodeId = _findNode(tester, 'Show notes, collapsed').id;
      _performAction(tester, nodeId, SemanticsAction.tap);
      await tester.pump();

      expect(
        _findNode(tester, 'Show notes, expanded'),
        matchesSemantics(
          label: 'Show notes, expanded',
          isButton: true,
          hasExpandedState: true,
          isExpanded: true,
          hasTapAction: true,
        ),
      );
      expect(find.text('Episode description goes here'), findsOneWidget);

      handle.dispose();
    });

    testWidgets('tapping header again collapses section', (tester) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(_wrap(const _TestShowNotesSection()));

      // Expand.
      var nodeId = _findNode(tester, 'Show notes, collapsed').id;
      _performAction(tester, nodeId, SemanticsAction.tap);
      await tester.pump();

      // Collapse.
      nodeId = _findNode(tester, 'Show notes, expanded').id;
      _performAction(tester, nodeId, SemanticsAction.tap);
      await tester.pump();

      expect(
        find.bySemanticsLabel('Show notes, collapsed'),
        findsOneWidget,
      );
      expect(find.text('Episode description goes here'), findsNothing);

      handle.dispose();
    });
  });
}
