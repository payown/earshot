import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:logging/logging.dart';

import '../../../../core/router/app_router.dart';
import '../../../../features/folders/presentation/widgets/folder_podcast_picker_sheet.dart';
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
                      context,
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
          onInvoke: () => _unfollow(context, ref, podcast),
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
            barrierLabel: 'Dismiss folder picker',
            builder: (_) => FolderPodcastPickerSheet(
              mode: ManageFoldersForPodcast(podcast.id),
            ),
          ),
        ),
      };
    }).toList();
  }

  Future<void> _unfollow(
    BuildContext context,
    WidgetRef ref,
    Podcast podcast,
  ) async {
    try {
      await ref.read(podcastRepositoryProvider).unsubscribe(podcast.id);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unfollowed ${podcast.title}'),
          duration: const Duration(seconds: 3),
        ),
      );
      SemanticsService.sendAnnouncement(
        View.of(context),
        'Unfollowed ${podcast.title}.',
        TextDirection.ltr,
      );
    } catch (e) {
      _log.warning('Failed to unfollow ${podcast.rssUrl}: $e');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not unfollow. Try again.')),
      );
    }
  }
}
