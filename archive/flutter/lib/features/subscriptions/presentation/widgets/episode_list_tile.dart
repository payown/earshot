import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../../../core/presentation/widgets/episode_actions_sheet.dart';
import '../../../../data/db/enums.dart';
import '../../domain/episode.dart';

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

  void _showActionsSheet(BuildContext context) {
    showEpisodeActionsSheet(
      context,
      episodeTitle: episode.title,
      actions: quickActions,
    );
  }

  @override
  Widget build(BuildContext context) {
    final duration = _formatDuration(episode.durationSeconds);
    final date = _formatDate(episode.pubDate);
    final statusText = _statusLabel(episode.status);
    final semanticDuration = _semanticDuration(episode);

    final semanticParts = [
      statusText,
      if (semanticDuration != null) semanticDuration,
      if (date != null) date,
    ];
    final semanticLabel = '${episode.title}, ${semanticParts.join(', ')}';

    // Always expose rotor actions, matching every other tab; with a single
    // action the rotor entry duplicates the default tap but keeps behavior
    // predictable across screens.
    final semanticActions = <CustomSemanticsAction, VoidCallback>{
      for (final action in quickActions)
        CustomSemanticsAction(label: action.label): action.onInvoke,
    };

    final hasMoreActions = quickActions.length > 1;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Semantics(
            container: true,
            label: semanticLabel,
            button: _defaultTap != null,
            customSemanticsActions: semanticActions,
            child: ExcludeSemantics(
              child: InkWell(
                onTap: _defaultTap,
                child: Padding(
                  padding: EdgeInsets.only(
                    left: 16,
                    top: 12,
                    bottom: 12,
                    right: hasMoreActions ? 4 : 16,
                  ),
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
                            const SizedBox(height: 4),
                            _StatusChip(status: episode.status),
                            if (duration != null || date != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                [
                                  if (duration != null) duration,
                                  if (date != null) date,
                                ].join(' · '),
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
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (hasMoreActions)
          IconButton(
            icon: const Icon(Icons.more_vert),
            tooltip: 'More actions',
            onPressed: () => _showActionsSheet(context),
          ),
      ],
    );
  }

  String _statusLabel(EpisodeStatus status) => switch (status) {
    EpisodeStatus.newEpisode => 'New',
    EpisodeStatus.inQueue => 'In queue',
    EpisodeStatus.played => 'Played',
    EpisodeStatus.expired => 'Expired',
  };

  String? _formatDuration(int? seconds) {
    if (seconds == null) return null;
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return '$h hr ${m > 0 ? "$m min" : ""}'.trim();
    if (m > 0) return '$m min';
    return '${seconds % 60} sec';
  }

  String? _semanticDuration(Episode ep) {
    if (ep.durationSeconds == null) return null;
    final total = ep.durationSeconds!;
    final position = ep.positionSeconds;
    if (position > 0 && position < (total * 0.95).round()) {
      return '${_verboseDuration(total - position)} remaining';
    }
    return _verboseDuration(total);
  }

  String _verboseDuration(int totalSeconds) {
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    final parts = <String>[];
    if (h > 0) parts.add('$h ${h == 1 ? 'hour' : 'hours'}');
    if (m > 0) parts.add('$m ${m == 1 ? 'minute' : 'minutes'}');
    if (s > 0 || parts.isEmpty)
      parts.add('$s ${s == 1 ? 'second' : 'seconds'}');
    return parts.join(', ');
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

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final EpisodeStatus status;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (bg, fg, label) = switch (status) {
      EpisodeStatus.newEpisode => (
        colorScheme.primaryContainer,
        colorScheme.onPrimaryContainer,
        'New',
      ),
      EpisodeStatus.inQueue => (
        colorScheme.secondaryContainer,
        colorScheme.onSecondaryContainer,
        'In queue',
      ),
      EpisodeStatus.played => (
        colorScheme.surfaceContainerHighest,
        colorScheme.onSurfaceVariant,
        'Played',
      ),
      EpisodeStatus.expired => (
        colorScheme.errorContainer,
        colorScheme.onErrorContainer,
        'Expired',
      ),
    };

    return Chip(
      label: Text(label),
      visualDensity: VisualDensity.compact,
      backgroundColor: bg,
      labelStyle: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg),
      padding: EdgeInsets.zero,
    );
  }
}
