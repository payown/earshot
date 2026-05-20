import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/player_providers.dart';
import '../widgets/now_playing_bar.dart';

class QueueScreen extends ConsumerWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(queueProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Queue')),
      bottomNavigationBar: const NowPlayingBar(),
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
                itemCount: episodes.length,
                onReorderItem: (oldIndex, newIndex) async {
                  await ref
                      .read(queueRepositoryProvider)
                      .reorder(episodes[oldIndex].id, newIndex);
                },
                itemBuilder: (context, index) {
                  final episode = episodes[index];
                  return Semantics(
                    key: ValueKey(episode.id),
                    label:
                        '${episode.title}, In queue, position ${index + 1} of ${episodes.length}',
                    customSemanticsActions: {
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
                    child: ListTile(
                      leading: ExcludeSemantics(
                        child: Text(
                          '${index + 1}',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                      ),
                      title: ExcludeSemantics(
                        child: Text(
                          episode.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      subtitle: ExcludeSemantics(
                        child: Padding(
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
                      ),
                      trailing: ExcludeSemantics(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Semantics(
                              button: true,
                              label: 'Remove from queue',
                              child: IconButton(
                                icon: const Icon(Icons.remove_circle_outline),
                                onPressed: () => ref
                                    .read(queueRepositoryProvider)
                                    .cancelFromQueue(episode.id),
                                tooltip: 'Remove from queue',
                              ),
                            ),
                            const Icon(Icons.drag_handle),
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
