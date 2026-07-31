import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/spacing.dart';
import '../../domain/chapter.dart';
import '../providers/chapter_providers.dart';
import '../providers/player_providers.dart';

class ChapterListSheet extends ConsumerWidget {
  const ChapterListSheet({
    super.key,
    required this.chapters,
    required this.episodeId,
  });

  final List<Chapter> chapters;
  final String episodeId;

  String _formatTime(double seconds) {
    final total = seconds.round();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = (total % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final skipped = ref.watch(skippedChaptersProvider)[episodeId] ?? {};
    final currentIndex = ref.watch(currentChapterIndexProvider);
    final theme = Theme.of(context);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.lg,
              Spacing.md,
              Spacing.lg,
              Spacing.sm,
            ),
            child: Semantics(
              header: true,
              label: 'Chapters',
              child: const ExcludeSemantics(
                child: Text(
                  'Chapters',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.6,
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: chapters.length,
              itemBuilder: (context, i) {
                final chapter = chapters[i];
                final isSkipped = skipped.contains(i);
                final isCurrent = currentIndex == i;
                final timeLabel = _formatTime(chapter.startTime);
                final semanticLabel =
                    '${chapter.title}, starts at $timeLabel'
                    '${isCurrent ? ', currently playing' : ''}'
                    '${isSkipped ? ', skipped' : ''}';

                return Semantics(
                  label: semanticLabel,
                  child: ExcludeSemantics(
                    child: ListTile(
                      onTap: () {
                        ref
                            .read(audioHandlerProvider)
                            .seek(
                              Duration(
                                milliseconds: (chapter.startTime * 1000)
                                    .round(),
                              ),
                            );
                        SemanticsService.sendAnnouncement(
                          View.of(context),
                          'Jumped to ${chapter.title}',
                          TextDirection.ltr,
                        );
                        Navigator.of(context).pop();
                      },
                      leading: isCurrent
                          ? Icon(
                              Icons.play_arrow,
                              color: theme.colorScheme.primary,
                              size: 20,
                            )
                          : const SizedBox(width: 20),
                      title: Text(
                        chapter.title,
                        style: TextStyle(
                          color: isSkipped
                              ? theme.colorScheme.onSurface.withValues(
                                  alpha: 0.4,
                                )
                              : null,
                          fontWeight: isCurrent
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        timeLabel,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      trailing: Semantics(
                        label: isSkipped
                            ? 'Include ${chapter.title}'
                            : 'Skip ${chapter.title}',
                        child: ExcludeSemantics(
                          child: Checkbox(
                            value: !isSkipped,
                            onChanged: (_) => ref
                                .read(skippedChaptersProvider.notifier)
                                .toggle(episodeId, i),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: Spacing.sm),
        ],
      ),
    );
  }
}
