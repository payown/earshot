import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:logging/logging.dart';

import '../../../../core/router/app_router.dart';
import '../../../../features/folders/presentation/widgets/folder_podcast_picker_sheet.dart';
import '../../../../features/player/presentation/widgets/now_playing_bar.dart';
import '../../../../features/settings/domain/quick_action_definition.dart';
import '../../../../features/settings/presentation/providers/settings_providers.dart';
import '../../domain/podcast.dart';
import '../providers/subscriptions_providers.dart';
import '../widgets/podcast_list_tile.dart';

final _log = Logger('AllPodcastsScreen');

class AllPodcastsScreen extends ConsumerWidget {
  const AllPodcastsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final podcasts = ref.watch(subscriptionsProvider);
    final podcastActions =
        ref.watch(podcastActionsProvider).asData?.value ??
        defaultPodcastActions;

    return Scaffold(
      appBar: AppBar(
        title: const Text('All Podcasts'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => context.push(AppRoutes.settings),
          ),
        ],
      ),
      bottomNavigationBar: const NowPlayingBar(),
      body: podcasts.when(
        data: (list) => list.isEmpty
            ? const Center(child: Text('No podcasts yet.'))
            : ListView.builder(
                itemCount: list.length,
                itemBuilder: (ctx, index) {
                  final podcast = list[index];
                  return PodcastListTile(
                    podcast: podcast,
                    onTap: () =>
                        context.push(AppRoutes.podcastDetail(podcast.id)),
                    quickActions: _buildActions(
                      ctx,
                      ref,
                      podcast,
                      podcastActions,
                    ),
                  );
                },
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, stack) {
          _log.severe('Failed to load podcasts', e, stack);
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Something went wrong. Pull to retry.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        },
      ),
    );
  }

  List<PodcastQuickActionItem> _buildActions(
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
}
