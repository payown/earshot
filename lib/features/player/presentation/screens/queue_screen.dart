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
                      Icon(
                        Icons.queue_music,
                        size: 64,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        semanticLabel: '',
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
                  // container: false lets our label and custom actions merge UP
                  // into the _ReorderableItem semantic node that Flutter creates
                  // around each item. The list-slot boundary still gives each
                  // episode exactly one VoiceOver focus stop, now carrying the
                  // full label + all reorder and custom actions together.
                  // ExcludeSemantics on the ListTile prevents any residual child
                  // nodes from creating extra focus stops.
                  return Semantics(
                    key: ValueKey(episode.id),
                    container: false,
                    label:
                        '${episode.title}, In queue, position ${index + 1} of ${episodes.length}',
                    customSemanticsActions: {
                      const CustomSemanticsAction(label: 'Play'): () =>
                          _playEpisode(ref, episode),
                      const CustomSemanticsAction(label: 'Move to top'): () =>
                          ref
                              .read(queueRepositoryProvider)
                              .moveToTop(episode.id),
                      const CustomSemanticsAction(
                        label: 'Remove from queue',
                      ): () => ref
                          .read(queueRepositoryProvider)
                          .cancelFromQueue(episode.id),
                    },
                    child: ExcludeSemantics(
                      child: ListTile(
                        leading: Text(
                          '${index + 1}',
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
                                child: Icon(Icons.drag_handle),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
    );
  }
}
