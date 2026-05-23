import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../features/folders/domain/podcast_folder.dart';
import '../../../../features/folders/presentation/providers/folders_providers.dart';
import '../../../../features/folders/presentation/widgets/create_folder_dialog.dart';
import '../../../../features/folders/presentation/widgets/folder_list_tile.dart';
import '../../../../features/player/presentation/widgets/now_playing_bar.dart';
import '../../domain/podcast.dart';
import '../providers/subscriptions_providers.dart';

class SubscriptionsScreen extends ConsumerWidget {
  const SubscriptionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allPodcasts = ref.watch(subscriptionsProvider);
    final folders = ref.watch(foldersProvider);
    final podcastsInFolders = {
      for (final folder in folders.asData?.value ?? <PodcastFolder>[])
        folder.id: ref.watch(podcastsInFolderProvider(folder.id)),
    };

    final totalCount = allPodcasts.asData?.value.length ?? 0;
    final folderList = folders.asData?.value ?? [];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          IconButton(
            icon: const Icon(Icons.create_new_folder_outlined),
            tooltip: 'Create folder',
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const CreateFolderDialog(),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => context.push(AppRoutes.settings),
          ),
        ],
      ),
      bottomNavigationBar: const NowPlayingBar(),
      body: allPodcasts.when(
        data: (podcasts) {
          if (podcasts.isEmpty) {
            return _EmptyState(
              onAddTap: () => context.push(AppRoutes.addPodcast),
            );
          }

          return RefreshIndicator(
            onRefresh: () => _refreshAll(ref, podcasts),
            child: CustomScrollView(
              slivers: [
                // ── All Podcasts entry ───────────────────────────────────────
                SliverToBoxAdapter(
                  child: Semantics(
                    button: true,
                    label:
                        'All Podcasts, $totalCount podcast${totalCount == 1 ? '' : 's'}',
                    child: ExcludeSemantics(
                      child: ListTile(
                        leading: Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            Icons.podcasts,
                            color: Theme.of(
                              context,
                            ).colorScheme.onPrimaryContainer,
                          ),
                        ),
                        title: Text(
                          'All Podcasts',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        subtitle: Text(
                          '$totalCount podcast${totalCount == 1 ? '' : 's'}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.push(AppRoutes.allPodcasts),
                      ),
                    ),
                  ),
                ),

                // ── Folders section ──────────────────────────────────────────
                if (folderList.isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: Semantics(
                      header: true,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                        child: Text(
                          'Folders',
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                              ),
                        ),
                      ),
                    ),
                  ),
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (ctx, index) {
                        final folder = folderList[index];
                        final count =
                            podcastsInFolders[folder.id]
                                ?.asData
                                ?.value
                                .length ??
                            0;
                        return FolderListTile(
                          folder: folder,
                          podcastCount: count,
                          onTap: () => context.push(
                            AppRoutes.folderDetail(folder.id),
                          ),
                          quickActions: [
                            FolderQuickActionItem(
                              label: 'Delete folder',
                              onInvoke: () =>
                                  _confirmDeleteFolder(context, ref, folder),
                            ),
                          ],
                        );
                      },
                      childCount: folderList.length,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Something went wrong. Pull to retry.',
              style: Theme.of(context).textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'fab_search',
            onPressed: () => context.push(AppRoutes.search),
            tooltip: 'Search podcasts',
            child: const Icon(Icons.search),
          ),
          const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'fab_add',
            onPressed: () => context.push(AppRoutes.addPodcast),
            tooltip: 'Add podcast by URL',
            child: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDeleteFolder(
    BuildContext context,
    WidgetRef ref,
    PodcastFolder folder,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Folder?'),
        content: Text(
          'Delete "${folder.name}"? Your podcasts will not be affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(folderRepositoryProvider).deleteFolder(folder.id);
    }
  }

  Future<void> _refreshAll(WidgetRef ref, List<Podcast> podcasts) async {
    final repo = ref.read(podcastRepositoryProvider);
    await Future.wait(podcasts.map((p) => repo.refreshFeed(p.id)));
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAddTap});

  final VoidCallback onAddTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.podcasts,
              size: 64,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              semanticLabel: '',
            ),
            const SizedBox(height: 16),
            Text(
              'No podcasts yet',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Add a podcast to get started.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: onAddTap,
              child: const Text('Add your first podcast'),
            ),
          ],
        ),
      ),
    );
  }
}
