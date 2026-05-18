import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/db/enums.dart';
import '../../../../features/player/presentation/providers/player_providers.dart';
import '../../../../features/player/presentation/widgets/now_playing_bar.dart';
import '../../../../features/settings/domain/quick_action_definition.dart';
import '../../../../features/settings/presentation/providers/settings_providers.dart';
import '../../domain/episode.dart';
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
      bottomNavigationBar: const NowPlayingBar(),
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
                    itemBuilder: (ctx, index) {
                      final episode = list[index];
                      final actions =
                          ref.watch(episodeActionsProvider).asData?.value ??
                          defaultEpisodeActions;
                      return EpisodeListTile(
                        episode: episode,
                        quickActions: _buildEpisodeActions(
                          ctx,
                          ref,
                          episode,
                          podcast,
                          actions,
                        ),
                      );
                    },
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

  List<EpisodeQuickActionItem> _buildEpisodeActions(
    BuildContext context,
    WidgetRef ref,
    Episode episode,
    Podcast podcast,
    List<EpisodeAction> order,
  ) {
    return order.map((action) {
      return switch (action) {
        EpisodeAction.playNow => EpisodeQuickActionItem(
          label: action.label,
          onInvoke: () => _play(ref, episode, podcast),
        ),
        EpisodeAction.addToQueue => EpisodeQuickActionItem(
          label: action.label,
          onInvoke: () async {
            await ref.read(queueRepositoryProvider).addToQueue(episode.id);
            if (context.mounted) {
              SemanticsService.sendAnnouncement(
                View.of(context),
                'Added to queue',
                TextDirection.ltr,
              );
            }
          },
        ),
        EpisodeAction.markPlayed => EpisodeQuickActionItem(
          label: episode.status == EpisodeStatus.played
              ? 'Mark as unplayed'
              : 'Mark as played',
          onInvoke: () {
            final newStatus = episode.status == EpisodeStatus.played
                ? EpisodeStatus.newEpisode
                : EpisodeStatus.played;
            ref
                .read(podcastRepositoryProvider)
                .updateEpisodeStatus(episode.id, newStatus);
          },
        ),
        EpisodeAction.openShowNotes => EpisodeQuickActionItem(
          label: action.label,
          onInvoke: () => showDialog<void>(
            context: context,
            builder: (_) => AlertDialog(
              title: Text(episode.title),
              content: SingleChildScrollView(
                child: Text(
                  episode.description ?? 'No show notes available.',
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ],
            ),
          ),
        ),
        EpisodeAction.download => EpisodeQuickActionItem(
          label: action.label,
          onInvoke: () {},
        ),
        EpisodeAction.share => EpisodeQuickActionItem(
          label: action.label,
          onInvoke: () {},
        ),
      };
    }).toList();
  }

  void _play(WidgetRef ref, Episode episode, Podcast podcast) {
    final handler = ref.read(audioHandlerProvider);
    final resumePosition =
        episode.positionSeconds > 0 &&
            episode.durationSeconds != null &&
            episode.positionSeconds < (episode.durationSeconds! * 0.95).round()
        ? episode.positionSeconds
        : 0;
    handler.playEpisode(
      MediaItem(
        id: episode.audioUrl,
        title: episode.title,
        album: podcast.title,
        artUri: podcast.artworkUrl != null
            ? Uri.parse(podcast.artworkUrl!)
            : null,
        duration: episode.durationSeconds != null
            ? Duration(seconds: episode.durationSeconds!)
            : null,
        extras: {'episodeId': episode.id},
      ),
      resumePositionSeconds: resumePosition,
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
