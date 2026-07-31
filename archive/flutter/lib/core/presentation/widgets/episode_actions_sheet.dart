import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

/// A single entry in an episode's quick actions: rotor action, sheet row,
/// or default tap (index 0 of a tile's action list).
class EpisodeQuickActionItem {
  const EpisodeQuickActionItem({
    required this.label,
    required this.onInvoke,
    this.destructive = false,
  });

  final String label;
  final VoidCallback onInvoke;

  /// Destructive rows (Remove from queue, Delete download) render in the
  /// error color inside [EpisodeActionsSheet].
  final bool destructive;
}

/// Opens the shared episode actions bottom sheet. Every screen that offers a
/// "more actions" affordance for an episode uses this so the modal config
/// (safe area, barrier label) and sheet semantics stay identical app-wide.
void showEpisodeActionsSheet(
  BuildContext context, {
  required String episodeTitle,
  required List<EpisodeQuickActionItem> actions,
}) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    barrierLabel: 'Dismiss episode actions',
    builder: (_) =>
        EpisodeActionsSheet(episodeTitle: episodeTitle, actions: actions),
  );
}

/// Bottom sheet listing an episode's actions. Announces the episode title on
/// open so VoiceOver users know whose actions they're looking at.
class EpisodeActionsSheet extends StatefulWidget {
  const EpisodeActionsSheet({
    required this.episodeTitle,
    required this.actions,
    super.key,
  });

  final String episodeTitle;
  final List<EpisodeQuickActionItem> actions;

  @override
  State<EpisodeActionsSheet> createState() => _EpisodeActionsSheetState();
}

class _EpisodeActionsSheetState extends State<EpisodeActionsSheet> {
  bool _announced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_announced) {
      _announced = true;
      final view = View.of(context);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          SemanticsService.sendAnnouncement(
            view,
            widget.episodeTitle,
            TextDirection.ltr,
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      child: SafeArea(
        // Scrollable so the sheet survives the largest Dynamic Type sizes with
        // a long title plus the full action set (Queue can show 8+ rows).
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Semantics(
                  header: true,
                  label: widget.episodeTitle,
                  child: ExcludeSemantics(
                    child: Text(
                      widget.episodeTitle,
                      style: Theme.of(context).textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              const Divider(height: 1),
              for (final action in widget.actions)
                _ActionRow(
                  action: action,
                  onInvoke: () {
                    Navigator.of(context).pop();
                    action.onInvoke();
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// A single tappable row in [EpisodeActionsSheet].
///
/// The outer [Semantics] is the only node VoiceOver/TalkBack sees: it carries
/// the button role, the label, and the activation, while the [ListTile] is
/// hidden with [ExcludeSemantics] so it never adds a second, unlabeled node
/// (the documented project pattern for overriding built-in widget semantics).
/// Destructive rows add a leading icon so danger is signaled by more than the
/// error color alone.
class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.action, required this.onInvoke});

  final EpisodeQuickActionItem action;
  final VoidCallback onInvoke;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: action.label,
      onTap: onInvoke,
      child: ExcludeSemantics(
        child: ListTile(
          leading: action.destructive
              ? Icon(Icons.remove_circle_outline, color: colorScheme.error)
              : null,
          title: Text(
            action.label,
            style: action.destructive
                ? TextStyle(color: colorScheme.error)
                : null,
          ),
          onTap: onInvoke,
        ),
      ),
    );
  }
}
