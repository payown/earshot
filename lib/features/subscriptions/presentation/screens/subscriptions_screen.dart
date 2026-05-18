import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/player/presentation/widgets/now_playing_bar.dart';
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Earshot'),
      ),
      bottomNavigationBar: const NowPlayingBar(),
      body: subscriptions.when(
        data: (podcasts) => podcasts.isEmpty
            ? _EmptyState(
                onAddTap: () => _openAddPodcast(context),
              )
            : RefreshIndicator(
                onRefresh: () => _refreshAll(ref, podcasts),
                child: ListView.builder(
                  itemCount: podcasts.length,
                  itemBuilder: (context, index) => PodcastListTile(
                    podcast: podcasts[index],
                    onTap: () => _openDetail(context, podcasts[index]),
                  ),
                ),
              ),
        loading: () => const Center(
          child: CircularProgressIndicator(),
        ),
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
