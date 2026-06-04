import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/chapter.dart';
import '../providers/chapter_providers.dart';
import '../providers/player_providers.dart';
import 'chapter_list_sheet.dart';

class ChapterControls extends ConsumerWidget {
  const ChapterControls({super.key});

  void _seek(WidgetRef ref, List<Chapter> chapters, int index, String label) {
    ref
        .read(audioHandlerProvider)
        .seek(
          Duration(milliseconds: (chapters[index].startTime * 1000).round()),
        );
  }

  void _prevChapter(BuildContext context, WidgetRef ref) {
    final chapters = ref.read(chaptersProvider).asData?.value ?? [];
    if (chapters.isEmpty) return;
    final currentIndex = ref.read(currentChapterIndexProvider) ?? 0;
    final position = ref.read(positionProvider).asData?.value ?? Duration.zero;
    final episodeId =
        ref
            .read(mediaItemProvider)
            .asData
            ?.value
            ?.extras?['episodeId']
            ?.toString() ??
        '';
    final skipped = ref.read(skippedChaptersProvider)[episodeId] ?? {};

    final currentStart = chapters[currentIndex].startTime;
    final secondsIn = position.inMilliseconds / 1000.0 - currentStart;

    // If we're ≥3s into a non-skipped chapter, restart the current chapter.
    if (secondsIn >= 3 && !skipped.contains(currentIndex)) {
      _seek(ref, chapters, currentIndex, chapters[currentIndex].title);
      SemanticsService.sendAnnouncement(
        View.of(context),
        'Back to start of ${chapters[currentIndex].title}',
        TextDirection.ltr,
      );
      return;
    }

    // Go to the previous non-skipped chapter.
    for (var i = currentIndex - 1; i >= 0; i--) {
      if (!skipped.contains(i)) {
        _seek(ref, chapters, i, chapters[i].title);
        SemanticsService.sendAnnouncement(
          View.of(context),
          chapters[i].title,
          TextDirection.ltr,
        );
        return;
      }
    }
  }

  void _nextChapter(BuildContext context, WidgetRef ref) {
    final chapters = ref.read(chaptersProvider).asData?.value ?? [];
    if (chapters.isEmpty) return;
    final currentIndex = ref.read(currentChapterIndexProvider);
    final episodeId =
        ref
            .read(mediaItemProvider)
            .asData
            ?.value
            ?.extras?['episodeId']
            ?.toString() ??
        '';
    final skipped = ref.read(skippedChaptersProvider)[episodeId] ?? {};
    final start = currentIndex != null ? currentIndex + 1 : 0;

    for (var i = start; i < chapters.length; i++) {
      if (!skipped.contains(i)) {
        _seek(ref, chapters, i, chapters[i].title);
        SemanticsService.sendAnnouncement(
          View.of(context),
          chapters[i].title,
          TextDirection.ltr,
        );
        return;
      }
    }
  }

  void _openChapterSheet(
    BuildContext context,
    WidgetRef ref,
    List<Chapter> chapters,
    String episodeId,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      barrierLabel: 'Dismiss chapter list',
      builder: (_) => ChapterListSheet(
        chapters: chapters,
        episodeId: episodeId,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chaptersAsync = ref.watch(chaptersProvider);
    final chapters = chaptersAsync.asData?.value ?? [];
    if (chapters.isEmpty) return const SizedBox.shrink();

    final currentIndex = ref.watch(currentChapterIndexProvider);
    final episodeId =
        ref
            .watch(mediaItemProvider)
            .asData
            ?.value
            ?.extras?['episodeId']
            ?.toString() ??
        '';
    final skipped = ref.watch(skippedChaptersProvider)[episodeId] ?? {};

    final chapterName = currentIndex != null
        ? chapters[currentIndex].title
        : '';

    final hasPrev = currentIndex != null && currentIndex > 0;
    final hasNext =
        currentIndex != null &&
        Iterable<int>.generate(
          chapters.length - currentIndex - 1,
          (i) => currentIndex + 1 + i,
        ).any((i) => !skipped.contains(i));

    return Row(
      children: [
        Semantics(
          button: true,
          enabled: hasPrev,
          label: 'Previous chapter',
          child: ExcludeSemantics(
            child: IconButton(
              icon: const Icon(Icons.skip_previous_outlined),
              onPressed: hasPrev ? () => _prevChapter(context, ref) : null,
              tooltip: 'Previous chapter',
            ),
          ),
        ),
        Expanded(
          child: Semantics(
            button: true,
            label: chapterName.isNotEmpty ? chapterName : 'Chapters',
            hint: 'Tap to open chapter list',
            child: ExcludeSemantics(
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () =>
                    _openChapterSheet(context, ref, chapters, episodeId),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    chapterName,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ),
            ),
          ),
        ),
        Semantics(
          button: true,
          enabled: hasNext,
          label: 'Next chapter',
          child: ExcludeSemantics(
            child: IconButton(
              icon: const Icon(Icons.skip_next_outlined),
              onPressed: hasNext ? () => _nextChapter(context, ref) : null,
              tooltip: 'Next chapter',
            ),
          ),
        ),
      ],
    );
  }
}
