import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:logging/logging.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../../../core/router/app_router.dart';
import '../../../../features/folders/presentation/widgets/folder_podcast_picker_sheet.dart';
import '../../../../features/settings/domain/quick_action_definition.dart';
import '../../../../features/settings/presentation/providers/settings_providers.dart';
import '../../domain/alphabet_index.dart';
import '../../domain/podcast.dart';
import '../providers/subscriptions_providers.dart';
import '../widgets/alphabet_index_bar.dart';
import '../widgets/podcast_list_tile.dart';

final _log = Logger('AllPodcastsScreen');

class AllPodcastsScreen extends ConsumerStatefulWidget {
  const AllPodcastsScreen({super.key});

  @override
  ConsumerState<AllPodcastsScreen> createState() => _AllPodcastsScreenState();
}

class _AllPodcastsScreenState extends ConsumerState<AllPodcastsScreen> {
  final _itemScrollController = ItemScrollController();

  void _onLetterSelected(AlphabetIndexEntry entry) {
    if (MediaQuery.of(context).disableAnimations) {
      _itemScrollController.jumpTo(index: entry.firstIndex);
    } else {
      unawaited(
        _itemScrollController.scrollTo(
          index: entry.firstIndex,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(subscriptionsProvider, (_, next) {
      if (next case AsyncError(:final error, :final stackTrace)) {
        _log.severe('Failed to load podcasts', error, stackTrace);
        unawaited(Sentry.captureException(error, stackTrace: stackTrace));
      }
    });
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
        data: (list) {
          if (list.isEmpty) {
            return const Center(child: Text('No podcasts yet.'));
          }
          final alphabetIndex = buildAlphabetIndex(list);
          return Row(
            children: [
              Expanded(
                child: ScrollablePositionedList.builder(
                  itemScrollController: _itemScrollController,
                  itemCount: list.length,
                  itemBuilder: (ctx, index) => _PodcastTileItem(
                    podcast: list[index],
                    podcastActions: podcastActions,
                  ),
                ),
              ),
              AlphabetIndexBar(
                index: alphabetIndex,
                onLetterSelected: _onLetterSelected,
              ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => RefreshIndicator(
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
  // Optimistic local state for both inbox flags.
  // null = defer to the podcast's current DB value.
  bool? _optimisticExcluded;
  bool? _optimisticIncluded;

  bool get _effectiveExcluded =>
      _optimisticExcluded ?? widget.podcast.inboxExcluded;

  bool get _effectiveIncluded =>
      _optimisticIncluded ?? widget.podcast.inboxIncluded;

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

  Future<void> _toggleInboxIncluded() async {
    final included = !_effectiveIncluded;
    setState(() => _optimisticIncluded = included);
    SemanticsService.sendAnnouncement(
      View.of(context),
      included
          ? '${widget.podcast.title} included in inbox.'
          : '${widget.podcast.title} removed from inbox.',
      TextDirection.ltr,
    );
    try {
      await ref
          .read(podcastRepositoryProvider)
          .setInboxIncluded(widget.podcast.id, included: included);
    } catch (e) {
      _log.warning(
        'Failed to toggle inbox included for ${widget.podcast.id}: $e',
      );
      setState(() => _optimisticIncluded = null);
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

  List<PodcastQuickActionItem> _buildActions(
    List<PodcastAction> order,
    bool inboxOptInOnly,
  ) {
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
        PodcastAction.toggleInboxExcluded =>
          inboxOptInOnly
              ? PodcastQuickActionItem(
                  label: _effectiveIncluded
                      ? 'Remove ${podcast.title} from inbox'
                      : 'Include ${podcast.title} in inbox',
                  onInvoke: _toggleInboxIncluded,
                )
              : PodcastQuickActionItem(
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
    final inboxOptInOnly = ref.watch(inboxOptInOnlyProvider).value ?? false;

    // Force VoiceOver to refresh the node when inbox state changes
    // (flutter/flutter#149613).
    final semanticSuffix = inboxOptInOnly
        ? (_effectiveIncluded
              ? ', Included in inbox'
              : ', Not included in inbox')
        : (_effectiveExcluded ? ', Excluded from inbox' : '');

    return PodcastListTile(
      podcast: widget.podcast,
      onTap: () => context.push(AppRoutes.podcastDetail(widget.podcast.id)),
      quickActions: _buildActions(widget.podcastActions, inboxOptInOnly),
      semanticSuffix: semanticSuffix,
    );
  }
}
