import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../features/folders/domain/podcast_folder.dart';
import '../../../../features/folders/presentation/providers/folders_providers.dart';
import '../../../../features/folders/presentation/widgets/create_folder_dialog.dart';
import '../../../../features/folders/presentation/widgets/folder_list_tile.dart';
import '../../../../features/folders/presentation/widgets/folder_podcast_picker_sheet.dart';
import '../../../../features/player/presentation/widgets/now_playing_bar.dart';
import '../../../../features/settings/domain/quick_action_definition.dart';
import '../../../../features/settings/presentation/providers/settings_providers.dart';
import '../../domain/podcast.dart';
import '../providers/subscriptions_providers.dart';
import '../widgets/podcast_list_tile.dart';

class SubscriptionsScreen extends ConsumerWidget {
  const SubscriptionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folders = ref.watch(foldersProvider);
    final unfiledPodcasts = ref.watch(unfiledPodcastsProvider);
    final allPodcasts = ref.watch(subscriptionsProvider);
    final podcastActions =
        ref.watch(podcastActionsProvider).asData?.value ??
        defaultPodcastActions;
    final podcastsInFolders = {
      for (final folder in folders.asData?.value ?? <PodcastFolder>[])
        folder.id: ref.watch(podcastsInFolderProvider(folder.id)),
    };

    final hasFolders = folders.asData?.value.isNotEmpty ?? false;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Earshot'),
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
            icon: const Icon(Icons.search),
            tooltip: 'Search podcasts',
            onPressed: () => context.push(AppRoutes.search),
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

          final folderList = folders.asData?.value ?? [];
          final unfiledList = unfiledPodcasts.asData?.value ?? podcasts;

          return RefreshIndicator(
            onRefresh: () => _refreshAll(ref, podcasts),
            child: CustomScrollView(
              slivers: [
                // ── Folders section ─────────────────────────────────────────
                if (hasFolders) ...[
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

                // ── Podcasts section ─────────────────────────────────────────
                if (unfiledList.isNotEmpty) ...[
                  if (hasFolders)
                    SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Divider(height: 1),
                          Semantics(
                            header: true,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                              child: Text(
                                'Podcasts',
                                style:
                                    Theme.of(
                                      context,
                                    ).textTheme.labelLarge?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (ctx, index) {
                        final podcast = unfiledList[index];
                        return PodcastListTile(
                          podcast: podcast,
                          onTap: () => context.push(
                            AppRoutes.podcastDetail(podcast.id),
                          ),
                          quickActions: _buildPodcastActions(
                            context,
                            ref,
                            podcast,
                            podcastActions,
                          ),
                        );
                      },
                      childCount: unfiledList.length,
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
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push(AppRoutes.addPodcast),
        tooltip: 'Add podcast',
        child: const Icon(Icons.add),
      ),
    );
  }

  List<PodcastQuickActionItem> _buildPodcastActions(
    BuildContext context,
    WidgetRef ref,
    Podcast podcast,
    List<PodcastAction> order,
  ) {
    return order.map((action) {
      return switch (action) {
        PodcastAction.open => PodcastQuickActionItem(
          label: action.label,
          onInvoke: () => context.push(AppRoutes.podcastDetail(podcast.id)),
        ),
        PodcastAction.toggleNotifications => PodcastQuickActionItem(
          label: podcast.notificationEnabled
              ? 'Disable notifications'
              : 'Enable notifications',
          onInvoke: () {},
        ),
        PodcastAction.toggleAutoQueue => PodcastQuickActionItem(
          label: podcast.autoQueue ? 'Disable auto-queue' : 'Enable auto-queue',
          onInvoke: () {},
        ),
        PodcastAction.unsubscribe => PodcastQuickActionItem(
          label: action.label,
          onInvoke: () => _confirmUnsubscribe(context, ref, podcast),
        ),
        PodcastAction.share => PodcastQuickActionItem(
          label: action.label,
          onInvoke: () {},
        ),
        PodcastAction.manageFolders => PodcastQuickActionItem(
          label: action.label,
          onInvoke: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            builder: (_) => FolderPodcastPickerSheet(
              mode: ManageFoldersForPodcast(podcast.id),
            ),
          ),
        ),
      };
    }).toList();
  }

  Future<void> _confirmUnsubscribe(
    BuildContext context,
    WidgetRef ref,
    Podcast podcast,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Unsubscribe?'),
        content: Text('Remove ${podcast.title} and all its episodes?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Unsubscribe'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(podcastRepositoryProvider).unsubscribe(podcast.id);
    }
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
