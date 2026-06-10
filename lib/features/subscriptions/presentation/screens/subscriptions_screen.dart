import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:logging/logging.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../../../core/router/app_router.dart';
import '../../../../features/folders/domain/podcast_folder.dart';
import '../../../../features/folders/presentation/providers/folders_providers.dart';
import '../../../../features/folders/presentation/widgets/create_folder_dialog.dart';
import '../../../../features/folders/presentation/widgets/folder_list_tile.dart';
import '../../domain/podcast.dart';
import '../providers/subscriptions_providers.dart';

final _log = Logger('SubscriptionsScreen');

class SubscriptionsScreen extends ConsumerStatefulWidget {
  const SubscriptionsScreen({super.key});

  @override
  ConsumerState<SubscriptionsScreen> createState() =>
      _SubscriptionsScreenState();
}

class _SubscriptionsScreenState extends ConsumerState<SubscriptionsScreen> {
  final _refreshKey = GlobalKey<RefreshIndicatorState>();
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(subscriptionsProvider, (_, next) {
      if (next case AsyncError(:final error, :final stackTrace)) {
        _log.severe('subscriptionsProvider error', error, stackTrace);
        unawaited(Sentry.captureException(error, stackTrace: stackTrace));
      }
    });
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
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: const Icon(Icons.create_new_folder_outlined),
          tooltip: 'Create folder',
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => const CreateFolderDialog(),
          ),
        ),
        title: Semantics(
          // VoiceOver: focus the 'Library' heading, swipe down in the actions
          // rotor to invoke 'Refresh library'. Sighted users still have pull-
          // to-refresh on the list below.
          customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
            const CustomSemanticsAction(label: 'Refresh library'):
                _triggerRefresh,
          },
          child: const Text('Library'),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => context.push(AppRoutes.settings),
          ),
        ],
      ),
      body: allPodcasts.when(
        data: (podcasts) {
          if (podcasts.isEmpty) {
            return _EmptyState(
              onAddTap: () => _showAddPodcastSheet(context),
            );
          }

          return RefreshIndicator(
            key: _refreshKey,
            onRefresh: () => _refreshAll(podcasts),
            child: CustomScrollView(
              controller: _scrollController,
              slivers: [
                // ── All Podcasts entry ───────────────────────────────────────
                SliverToBoxAdapter(
                  child: Semantics(
                    button: true,
                    label:
                        'All Podcasts, $totalCount podcast${totalCount == 1 ? '' : 's'}',
                    onTap: () => context.push(AppRoutes.allPodcasts),
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
                      label: 'Folders',
                      child: ExcludeSemantics(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                          child: Text(
                            'Folders',
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.primary,
                                ),
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
                                  _confirmDeleteFolder(context, folder),
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
        error: (error, _) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(subscriptionsProvider),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              SizedBox(
                height: MediaQuery.of(context).size.height * 0.5,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ExcludeSemantics(
                          child: Icon(
                            Icons.error_outline,
                            size: 48,
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Something went wrong.',
                          style: Theme.of(context).textTheme.bodyLarge,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        FilledButton.tonal(
                          onPressed: () =>
                              ref.invalidate(subscriptionsProvider),
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddPodcastSheet(context),
        tooltip: 'Add podcast',
        child: const Icon(Icons.add),
      ),
    );
  }

  void _showAddPodcastSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      barrierLabel: 'Dismiss Add Podcast options',
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              header: true,
              label: 'Add Podcast',
              child: ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Add Podcast',
                      style: Theme.of(sheetContext).textTheme.titleLarge,
                    ),
                  ),
                ),
              ),
            ),
            ListTile(
              leading: const ExcludeSemantics(child: Icon(Icons.search)),
              title: const Text('Search podcasts'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                if (context.mounted) context.push(AppRoutes.search);
              },
            ),
            ListTile(
              leading: const ExcludeSemantics(child: Icon(Icons.link)),
              title: const Text('Add by URL'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                if (context.mounted) context.push(AppRoutes.addPodcast);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteFolder(
    BuildContext context,
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

  void _triggerRefresh() {
    // Check key presence rather than hasValue: hasValue is true even in an
    // AsyncError-with-cached-value state, where _refreshKey.currentState is
    // null because the error branch's RefreshIndicator is mounted instead.
    if (_refreshKey.currentState != null) {
      _refreshKey.currentState!.show();
    } else {
      ref.invalidate(subscriptionsProvider);
    }
  }

  Future<void> _refreshAll(List<Podcast> podcasts) async {
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
