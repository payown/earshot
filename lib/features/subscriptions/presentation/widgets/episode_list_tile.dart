import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../domain/episode.dart';

class EpisodeQuickActionItem {
  const EpisodeQuickActionItem({required this.label, required this.onInvoke});

  final String label;
  final VoidCallback onInvoke;
}

class EpisodeListTile extends StatelessWidget {
  const EpisodeListTile({
    required this.episode,
    this.quickActions = const [],
    super.key,
  });

  final Episode episode;

  // Ordered list of Quick Actions. Index 0 is the default tap action.
  final List<EpisodeQuickActionItem> quickActions;

  VoidCallback? get _defaultTap =>
      quickActions.isNotEmpty ? quickActions[0].onInvoke : null;

  @override
  Widget build(BuildContext context) {
    final duration = _formatDuration(episode.durationSeconds);
    final date = _formatDate(episode.pubDate);

    final parts = [
      if (duration != null) duration,
      if (date != null) date,
    ];
    final semanticLabel = parts.isEmpty
        ? episode.title
        : '${episode.title}, ${parts.join(', ')}';

    final semanticActions = <CustomSemanticsAction, VoidCallback>{
      for (final action in quickActions)
        CustomSemanticsAction(label: action.label): action.onInvoke,
    };

    return Semantics(
      label: semanticLabel,
      button: _defaultTap != null,
      customSemanticsActions: semanticActions,
      child: ExcludeSemantics(
        child: InkWell(
          onTap: _defaultTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        episode.title,
                        style: Theme.of(context).textTheme.titleSmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (parts.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          parts.join(' · '),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_defaultTap != null)
                  Icon(
                    Icons.play_circle_outline,
                    size: 32,
                    color: Theme.of(context).colorScheme.primary,
                    semanticLabel: '',
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String? _formatDuration(int? seconds) {
    if (seconds == null) return null;
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return '$h hr ${m > 0 ? "$m min" : ""}'.trim();
    if (m > 0) return '$m min';
    return '${seconds % 60} sec';
  }

  String? _formatDate(DateTime? date) {
    if (date == null) return null;
    final now = DateTime.now();
    final diff = now.difference(date);
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays} days ago';
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}
