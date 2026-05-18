import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/player/presentation/widgets/now_playing_bar.dart';
import '../../../../features/search/presentation/screens/search_screen.dart';
import '../../../../features/settings/domain/quick_action_definition.dart';
import '../../../../features/settings/presentation/providers/settings_providers.dart';
import '../../../../features/settings/presentation/screens/settings_screen.dart';
import '../../domain/podcast.dart';
import '../providers/subscriptions_providers.dart';
import '../widgets/podcast_list_tile.dart';
import 'add_podcast_screen.dart';
import 'podcast_detail_screen.dart';

class SubscriptionsScreen extends ConsumerWidget {
  const SubscriptionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subscriptions = ref.watch(subscriptionsProvider);
    final podcastActions =
        ref.watch(podcastActionsProvider).asData?.value ??
        defaultPodcastActions;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Earshot'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search podcasts',
            onPressed: () => _openSearch(context),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => _openSettings(context),
          ),
        ],
      ),
      bottomNavigationBar: const NowPlayingBar(),
      body: subscriptions.when(
        data: (podcasts) => podcasts.isEmpty
            ? _EmptyState(onAddTap: () => _openAddPodcast(context))
            : RefreshIndicator(
                onRefresh: () => _refreshAll(ref, podcasts),
                child: ListView.builder(
                  itemCount: podcasts.length,
                  itemBuilder: (ctx, index) {
                    final podcast = podcasts[index];
                    return PodcastListTile(
                      podcast: podcast,
                      onTap: () => _openDetail(context, podcast),
                      quickActions: _buildPodcastActions(
                        context,
                        ref,
                        podcast,
                        podcastActions,
                      ),
                    );
                  },
                ),
              ),
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
        onPressed: () => _openAddPodcast(context),
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
          onInvoke: () => _openDetail(context, podcast),
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
        content: Text(
          'Remove ${podcast.title} and all its episodes?',
        ),
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

  Future<void> _refreshAll(WidgetRef ref, List<Podcast> podcasts) async {
    final repo = ref.read(podcastRepositoryProvider);
    await Future.wait(podcasts.map((p) => repo.refreshFeed(p.id)));
  }

  void _openAddPodcast(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const AddPodcastScreen()),
    );
  }

  void _openDetail(BuildContext context, Podcast podcast) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PodcastDetailScreen(podcast: podcast),
      ),
    );
  }

  void _openSearch(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const SearchScreen()),
    );
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
    );
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
