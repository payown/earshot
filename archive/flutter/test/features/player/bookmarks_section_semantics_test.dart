import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Mirrors of the private widgets ───────────────────────────────────────────
// These reproduce the semantics-relevant structure of _BookmarksSection and
// _BookmarkRow without requiring Riverpod or the full player setup.

class _BookmarkData {
  const _BookmarkData({required this.positionSeconds});

  final int positionSeconds;
}

class _TestBookmarksSection extends StatefulWidget {
  const _TestBookmarksSection({
    required this.bookmarks,
    required this.onSeek,
    required this.onDelete,
    required this.onShare,
  });

  final List<_BookmarkData> bookmarks;
  final void Function(int positionSeconds) onSeek;
  final void Function(int positionSeconds) onDelete;
  final void Function(int positionSeconds) onShare;

  @override
  State<_TestBookmarksSection> createState() => _TestBookmarksSectionState();
}

class _TestBookmarksSectionState extends State<_TestBookmarksSection> {
  bool _expanded = false;

  String _formatPosition(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = (seconds % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.bookmarks.isEmpty) return const SizedBox.shrink();

    final count = widget.bookmarks.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ExcludeSemantics(child: Divider(height: 1)),
        Semantics(
          button: true,
          expanded: _expanded,
          label: _expanded
              ? 'Bookmarks, $count ${count == 1 ? 'item' : 'items'}, expanded'
              : 'Bookmarks, $count ${count == 1 ? 'item' : 'items'}, collapsed',
          onTap: () => setState(() => _expanded = !_expanded),
          child: ExcludeSemantics(
            child: GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('Bookmarks ($count)'),
              ),
            ),
          ),
        ),
        if (_expanded)
          Column(
            children: [
              for (final b in widget.bookmarks)
                _TestBookmarkRow(
                  positionLabel: _formatPosition(b.positionSeconds),
                  note: '',
                  onSeek: () => widget.onSeek(b.positionSeconds),
                  onDelete: () => widget.onDelete(b.positionSeconds),
                  onShare: () => widget.onShare(b.positionSeconds),
                ),
            ],
          ),
      ],
    );
  }
}

class _TestBookmarkRow extends StatelessWidget {
  const _TestBookmarkRow({
    required this.positionLabel,
    required this.note,
    required this.onSeek,
    required this.onDelete,
    required this.onShare,
  });

  final String positionLabel;
  final String note;
  final VoidCallback onSeek;
  final VoidCallback onDelete;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final trimmedNote = note.trim();
    final semanticLabel = trimmedNote.isNotEmpty
        ? 'Bookmark at $positionLabel: $trimmedNote'
        : 'Bookmark at $positionLabel';

    return Semantics(
      button: true,
      label: semanticLabel,
      hint: 'Jump to this position',
      onTap: onSeek,
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Delete bookmark'): onDelete,
        const CustomSemanticsAction(label: 'Share bookmark'): onShare,
      },
      child: ExcludeSemantics(
        child: GestureDetector(
          onTap: onSeek,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(positionLabel),
          ),
        ),
      ),
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
  // ── _BookmarksSection ─────────────────────────────────────────────────────

  group('_BookmarksSection', () {
    testWidgets('renders nothing when bookmark list is empty', (tester) async {
      await tester.pumpWidget(
        _wrap(
          _TestBookmarksSection(
            bookmarks: const [],
            onSeek: (_) {},
            onDelete: (_) {},
            onShare: (_) {},
          ),
        ),
      );

      expect(find.bySemanticsLabel(RegExp(r'Bookmarks')), findsNothing);
    });

    testWidgets('shows collapsed header label with item count', (tester) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(
        _wrap(
          _TestBookmarksSection(
            bookmarks: const [_BookmarkData(positionSeconds: 272)],
            onSeek: (_) {},
            onDelete: (_) {},
            onShare: (_) {},
          ),
        ),
      );

      expect(
        _findNode(tester, 'Bookmarks, 1 item, collapsed'),
        matchesSemantics(
          label: 'Bookmarks, 1 item, collapsed',
          isButton: true,
          hasExpandedState: true,
          hasTapAction: true,
        ),
      );

      handle.dispose();
    });

    testWidgets('uses plural "items" for more than one bookmark', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(
        _wrap(
          _TestBookmarksSection(
            bookmarks: const [
              _BookmarkData(positionSeconds: 60),
              _BookmarkData(positionSeconds: 120),
            ],
            onSeek: (_) {},
            onDelete: (_) {},
            onShare: (_) {},
          ),
        ),
      );

      expect(
        find.bySemanticsLabel('Bookmarks, 2 items, collapsed'),
        findsOneWidget,
      );

      handle.dispose();
    });

    testWidgets('tapping header expands section and updates label', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(
        _wrap(
          _TestBookmarksSection(
            bookmarks: const [_BookmarkData(positionSeconds: 272)],
            onSeek: (_) {},
            onDelete: (_) {},
            onShare: (_) {},
          ),
        ),
      );

      // Expand via semantics tap action.
      final nodeId = _findNode(tester, 'Bookmarks, 1 item, collapsed').id;
      _performAction(tester, nodeId, SemanticsAction.tap);
      await tester.pump();

      expect(
        find.bySemanticsLabel('Bookmarks, 1 item, expanded'),
        findsOneWidget,
      );
      // Bookmark row now visible.
      expect(find.bySemanticsLabel('Bookmark at 4:32'), findsOneWidget);

      handle.dispose();
    });

    testWidgets('tapping header again collapses section', (tester) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(
        _wrap(
          _TestBookmarksSection(
            bookmarks: const [_BookmarkData(positionSeconds: 272)],
            onSeek: (_) {},
            onDelete: (_) {},
            onShare: (_) {},
          ),
        ),
      );

      // Expand.
      var nodeId = _findNode(tester, 'Bookmarks, 1 item, collapsed').id;
      _performAction(tester, nodeId, SemanticsAction.tap);
      await tester.pump();

      // Collapse.
      nodeId = _findNode(tester, 'Bookmarks, 1 item, expanded').id;
      _performAction(tester, nodeId, SemanticsAction.tap);
      await tester.pump();

      expect(
        find.bySemanticsLabel('Bookmarks, 1 item, collapsed'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Bookmark at 4:32'), findsNothing);

      handle.dispose();
    });
  });

  // ── _BookmarkRow ──────────────────────────────────────────────────────────

  group('_BookmarkRow semantics', () {
    testWidgets('label without note contains only the timestamp', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(
        _wrap(
          _TestBookmarkRow(
            positionLabel: '4:32',
            note: '',
            onSeek: () {},
            onDelete: () {},
            onShare: () {},
          ),
        ),
      );

      expect(
        _findNode(tester, 'Bookmark at 4:32'),
        matchesSemantics(
          label: 'Bookmark at 4:32',
          hint: 'Jump to this position',
          isButton: true,
          hasTapAction: true,
        ),
      );

      handle.dispose();
    });

    testWidgets('label with note includes the note text', (tester) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(
        _wrap(
          _TestBookmarkRow(
            positionLabel: '1:05:00',
            note: 'Great quote',
            onSeek: () {},
            onDelete: () {},
            onShare: () {},
          ),
        ),
      );

      expect(
        find.bySemanticsLabel('Bookmark at 1:05:00: Great quote'),
        findsOneWidget,
      );

      handle.dispose();
    });

    testWidgets('whitespace-only note is trimmed and omitted from label', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(
        _wrap(
          _TestBookmarkRow(
            positionLabel: '2:00',
            note: '   ',
            onSeek: () {},
            onDelete: () {},
            onShare: () {},
          ),
        ),
      );

      expect(
        find.bySemanticsLabel('Bookmark at 2:00'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'Bookmark at 2:00:')),
        findsNothing,
      );

      handle.dispose();
    });

    testWidgets('tap action fires onSeek', (tester) async {
      final handle = tester.ensureSemantics();
      var seekCalled = false;

      await tester.pumpWidget(
        _wrap(
          _TestBookmarkRow(
            positionLabel: '4:32',
            note: '',
            onSeek: () => seekCalled = true,
            onDelete: () {},
            onShare: () {},
          ),
        ),
      );

      final nodeId = _findNode(tester, 'Bookmark at 4:32').id;
      _performAction(tester, nodeId, SemanticsAction.tap);
      await tester.pump();

      expect(seekCalled, isTrue);
      handle.dispose();
    });

    testWidgets('Delete bookmark custom action fires onDelete', (tester) async {
      final handle = tester.ensureSemantics();
      var deleteCalled = false;

      await tester.pumpWidget(
        _wrap(
          _TestBookmarkRow(
            positionLabel: '4:32',
            note: '',
            onSeek: () {},
            onDelete: () => deleteCalled = true,
            onShare: () {},
          ),
        ),
      );

      final nodeId = _findNode(tester, 'Bookmark at 4:32').id;
      _performAction(
        tester,
        nodeId,
        SemanticsAction.customAction,
        CustomSemanticsAction.getIdentifier(
          const CustomSemanticsAction(label: 'Delete bookmark'),
        ),
      );
      await tester.pump();

      expect(deleteCalled, isTrue);
      handle.dispose();
    });

    testWidgets('Share bookmark custom action fires onShare', (tester) async {
      final handle = tester.ensureSemantics();
      var shareCalled = false;

      await tester.pumpWidget(
        _wrap(
          _TestBookmarkRow(
            positionLabel: '4:32',
            note: '',
            onSeek: () {},
            onDelete: () {},
            onShare: () => shareCalled = true,
          ),
        ),
      );

      final nodeId = _findNode(tester, 'Bookmark at 4:32').id;
      _performAction(
        tester,
        nodeId,
        SemanticsAction.customAction,
        CustomSemanticsAction.getIdentifier(
          const CustomSemanticsAction(label: 'Share bookmark'),
        ),
      );
      await tester.pump();

      expect(shareCalled, isTrue);
      handle.dispose();
    });
  });
}
