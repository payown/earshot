import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/podcast.dart';
import '../providers/subscriptions_providers.dart';
import '../widgets/episode_list_tile.dart';

class PodcastDetailScreen extends ConsumerWidget {
  const PodcastDetailScreen({required this.podcast, super.key});

  final Podcast podcast;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final episodes = ref.watch(episodesProvider(podcast.id));

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 200,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(
                podcast.title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              background: _PodcastHeader(podcast: podcast),
            ),
          ),
          if (podcast.description != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  podcast.description!,
                  style: Theme.of(context).textTheme.bodyMedium,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Semantics(
                header: true,
                child: Text(
                  'Episodes',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ),
          ),
          episodes.when(
            data: (list) => list.isEmpty
                ? const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('No episodes yet.'),
                    ),
                  )
                : SliverList.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, index) =>
                        EpisodeListTile(episode: list[index]),
                  ),
            loading: () => const SliverToBoxAdapter(
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Failed to load episodes: $e'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PodcastHeader extends StatelessWidget {
  const _PodcastHeader({required this.podcast});

  final Podcast podcast;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (podcast.artworkUrl == null) {
      return ColoredBox(
        color: colorScheme.surfaceContainerHighest,
        child: Center(
          child: Icon(
            Icons.podcasts,
            size: 80,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Image.network(
      podcast.artworkUrl!,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => ColoredBox(
        color: colorScheme.surfaceContainerHighest,
        child: Center(
          child: Icon(
            Icons.podcasts,
            size: 80,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
