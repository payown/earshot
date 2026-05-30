import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../features/subscriptions/domain/episode.dart';
import '../providers/player_providers.dart';

void _playEpisode(WidgetRef ref, Episode episode) {
  final handler = ref.read(audioHandlerProvider);
  final resumePosition =
      episode.positionSeconds > 0 &&
          episode.durationSeconds != null &&
          episode.positionSeconds < (episode.durationSeconds! * 0.95).round()
      ? episode.positionSeconds
      : 0;
  handler.playEpisode(
    MediaItem(
      id: episode.audioUrl,
      title: episode.title,
      artUri: episode.artworkUrl != null
          ? Uri.parse(episode.artworkUrl!)
          : null,
      duration: episode.durationSeconds != null
          ? Duration(seconds: episode.durationSeconds!)
          : null,
      extras: {'episodeId': episode.id, 'podcastId': episode.podcastId},
    ),
    resumePositionSeconds: resumePosition,
  );
}

class QueueScreen extends ConsumerWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(queueProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Queue'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => context.push(AppRoutes.settings),
          ),
        ],
      ),
      body: queue.when(
        data: (episodes) => episodes.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ExcludeSemantics(
                        child: Icon(
                          Icons.queue_music,
                          size: 64,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Queue is empty',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Add episodes to play them in order.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              )
            : ReorderableListView.builder(
                buildDefaultDragHandles: false,
                itemCount: episodes.length,
                onReorderItem: (oldIndex, newIndex) async {
                  await ref
                      .read(queueRepositoryProvider)
                      .reorder(episodes[oldIndex].id, newIndex);
                },
                itemBuilder: (context, index) {
                  final episode = episodes[index];
                  final total = episodes.length;
                  final position = index + 1;
                  final isFirst = index == 0;
                  final isLast = index == total - 1;

                  return Semantics(
                    key: ValueKey(episode.id),
                    container: true,
                    label:
                        '${episode.title}, In queue, position $position of $total',
                    customSemanticsActions: {
                      const CustomSemanticsAction(label: 'Play'): () =>
                          _playEpisode(ref, episode),
                      const CustomSemanticsAction(
                        label: 'Move to top',
                      ): () async {
                        final view = View.of(context);
                        await ref
                            .read(queueRepositoryProvider)
                            .moveToTop(episode.id);
                        SemanticsService.sendAnnouncement(
                          view,
                          'Moved to top, now position 1 of $total',
                          TextDirection.ltr,
                        );
                      },
                      const CustomSemanticsAction(
                        label: 'Move to bottom',
                      ): () async {
                        final view = View.of(context);
                        await ref
                            .read(queueRepositoryProvider)
                            .moveToBottom(episode.id);
                        SemanticsService.sendAnnouncement(
                          view,
                          'Moved to bottom, now position $total of $total',
                          TextDirection.ltr,
                        );
                      },
                      if (!isFirst)
                        const CustomSemanticsAction(
                          label: 'Move up',
                        ): () async {
                          final view = View.of(context);
                          await ref
                              .read(queueRepositoryProvider)
                              .moveUp(episode.id);
                          SemanticsService.sendAnnouncement(
                            view,
                            'Moved up, now position ${position - 1} of $total',
                            TextDirection.ltr,
                          );
                        },
                      if (!isLast)
                        const CustomSemanticsAction(
                          label: 'Move down',
                        ): () async {
                          final view = View.of(context);
                          await ref
                              .read(queueRepositoryProvider)
                              .moveDown(episode.id);
                          SemanticsService.sendAnnouncement(
                            view,
                            'Moved down, now position ${position + 1} of $total',
                            TextDirection.ltr,
                          );
                        },
                      const CustomSemanticsAction(
                        label: 'Remove from queue',
                      ): () => ref
                          .read(queueRepositoryProvider)
                          .cancelFromQueue(episode.id),
                    },
                    child: ExcludeSemantics(
                      child: ListTile(
                        leading: Text(
                          '$position',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        title: Text(
                          episode.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Wrap(
                            children: [
                              Chip(
                                label: const Text('In queue'),
                                visualDensity: VisualDensity.compact,
                                backgroundColor: Theme.of(
                                  context,
                                ).colorScheme.secondaryContainer,
                                labelStyle: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSecondaryContainer,
                                    ),
                                padding: EdgeInsets.zero,
                              ),
                            ],
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.play_arrow),
                              tooltip: 'Play',
                              onPressed: () => _playEpisode(ref, episode),
                            ),
                            IconButton(
                              icon: const Icon(Icons.arrow_upward),
                              tooltip: 'Move up',
                              onPressed: isFirst
                                  ? null
                                  : () async {
                                      final view = View.of(context);
                                      await ref
                                          .read(queueRepositoryProvider)
                                          .moveUp(episode.id);
                                      SemanticsService.sendAnnouncement(
                                        view,
                                        'Moved up, now position ${position - 1} of $total',
                                        TextDirection.ltr,
                                      );
                                    },
                            ),
                            IconButton(
                              icon: const Icon(Icons.arrow_downward),
                              tooltip: 'Move down',
                              onPressed: isLast
                                  ? null
                                  : () async {
                                      final view = View.of(context);
                                      await ref
                                          .read(queueRepositoryProvider)
                                          .moveDown(episode.id);
                                      SemanticsService.sendAnnouncement(
                                        view,
                                        'Moved down, now position ${position + 1} of $total',
                                        TextDirection.ltr,
                                      );
                                    },
                            ),
                            IconButton(
                              icon: const Icon(Icons.remove_circle_outline),
                              tooltip: 'Remove from queue',
                              onPressed: () => ref
                                  .read(queueRepositoryProvider)
                                  .cancelFromQueue(episode.id),
                            ),
                            ReorderableDragStartListener(
                              index: index,
                              child: const Tooltip(
                                message: 'Reorder',
                                child: SizedBox(
                                  width: 44,
                                  height: 44,
                                  child: Icon(Icons.drag_handle),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
        loading: () => Center(
          child: Semantics(
            label: 'Loading queue',
            child: const CircularProgressIndicator(),
          ),
        ),
        error: (_, __) => Center(
          child: Text(
            'Could not load queue. Please try again.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      ),
    );
  }
}
