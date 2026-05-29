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
                itemBuilder: (ctx, index) => _PodcastTileItem(
                  podcast: list[index],
                  podcastActions: podcastActions,
                ),
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
}

class _PodcastTileItem extends ConsumerStatefulWidget {
  const _PodcastTileItem({
    required this.podcast,
    required this.podcastActions,
  });

  final Podcast podcast;
  final List<PodcastAction> podcastActions;

  @override
  ConsumerState<_PodcastTileItem> createState() => _PodcastTileItemState();
}

class _PodcastTileItemState extends ConsumerState<_PodcastTileItem> {
  // Optimistic local state: flips the action label immediately on tap
  // without waiting for the DB round-trip — same pattern as Follow/Unfollow.
  // null = defer to podcast.inboxExcluded; true/false = local override.
  bool? _optimisticExcluded;

  bool get _effectiveExcluded =>
      _optimisticExcluded ?? widget.podcast.inboxExcluded;

  Future<void> _toggleInboxExcluded() async {
    final excluded = !_effectiveExcluded;
    setState(() => _optimisticExcluded = excluded);
    SemanticsService.sendAnnouncement(
      View.of(context),
      excluded
          ? '${widget.podcast.title} excluded from inbox.'
          : '${widget.podcast.title} included in inbox.',
      TextDirection.ltr,
    );
    try {
      await ref
          .read(podcastRepositoryProvider)
          .setInboxExcluded(widget.podcast.id, excluded: excluded);
    } catch (e) {
      _log.warning(
        'Failed to toggle inbox excluded for ${widget.podcast.id}: $e',
      );
      setState(() => _optimisticExcluded = null);
      if (mounted) {
        SemanticsService.sendAnnouncement(
          View.of(context),
          'Could not update inbox setting.',
          TextDirection.ltr,
        );
      }
    }
  }

  Future<void> _unfollow() async {
    try {
      await ref.read(podcastRepositoryProvider).unsubscribe(widget.podcast.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unfollowed ${widget.podcast.title}'),
          duration: const Duration(seconds: 3),
        ),
      );
      SemanticsService.sendAnnouncement(
        View.of(context),
        'Unfollowed ${widget.podcast.title}.',
        TextDirection.ltr,
      );
    } catch (e) {
      _log.warning('Failed to unfollow ${widget.podcast.rssUrl}: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not unfollow. Try again.')),
      );
    }
  }

  List<PodcastQuickActionItem> _buildActions(List<PodcastAction> order) {
    final podcast = widget.podcast;
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
        PodcastAction.toggleInboxExcluded => PodcastQuickActionItem(
          label: _effectiveExcluded
              ? 'Include ${podcast.title} in inbox'
              : 'Exclude ${podcast.title} from inbox',
          onInvoke: _toggleInboxExcluded,
        ),
        PodcastAction.unsubscribe => PodcastQuickActionItem(
          label: action.label,
          onInvoke: _unfollow,
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

  @override
  Widget build(BuildContext context) {
    // Include excluded state in the semantic label to force VoiceOver to
    // refresh the node when the state changes (flutter/flutter#149613).
    final semanticSuffix = _effectiveExcluded ? ', Excluded from inbox' : '';

    return PodcastListTile(
      podcast: widget.podcast,
      onTap: () => context.push(AppRoutes.podcastDetail(widget.podcast.id)),
      quickActions: _buildActions(widget.podcastActions),
      semanticSuffix: semanticSuffix,
    );
  }
}
