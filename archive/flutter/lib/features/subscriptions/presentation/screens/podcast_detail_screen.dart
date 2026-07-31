import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/episode_action_builder.dart';
import '../../../../core/episode_playback.dart';
import '../../../../core/router/app_router.dart';
import '../../../../data/db/enums.dart';
import '../../../../features/settings/domain/quick_action_definition.dart';
import '../../../../features/settings/presentation/providers/settings_providers.dart';
import '../../domain/podcast.dart';
import '../providers/subscriptions_providers.dart';
import '../widgets/episode_list_tile.dart';

class PodcastDetailScreen extends ConsumerWidget {
  const PodcastDetailScreen({required this.podcastId, super.key});

  final int podcastId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final podcastAsync = ref.watch(podcastProvider(podcastId));

    return podcastAsync.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text('Error: $e')),
      ),
      data: (podcast) {
        if (podcast == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Podcast not found.')),
          );
        }
        return _PodcastDetailView(podcast: podcast);
      },
    );
  }
}

class _PodcastDetailView extends ConsumerStatefulWidget {
  const _PodcastDetailView({required this.podcast});

  final Podcast podcast;

  @override
  ConsumerState<_PodcastDetailView> createState() => _PodcastDetailViewState();
}

class _PodcastDetailViewState extends ConsumerState<_PodcastDetailView> {
  bool _showUnplayedOnly = false;
  final _refreshKey = GlobalKey<RefreshIndicatorState>();
  final _scrollController = ScrollController();

  Podcast get podcast => widget.podcast;

  @override
  void initState() {
    super.initState();
    // Route pushes don't reliably trigger a VoiceOver announcement of the new
    // screen, so announce the podcast name explicitly once the first frame
    // is up.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      SemanticsService.sendAnnouncement(
        View.of(context),
        podcast.title,
        TextDirection.ltr,
      );
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final episodes = ref.watch(episodesProvider(widget.podcast.id));
    return Scaffold(
      body: RefreshIndicator(
        key: _refreshKey,
        onRefresh: () async {
          await ref.read(podcastRepositoryProvider).refreshFeed(podcast.id);
          if (context.mounted) {
            SemanticsService.sendAnnouncement(
              View.of(context),
              '${podcast.title} refreshed',
              TextDirection.ltr,
            );
          }
        },
        child: CustomScrollView(
          controller: _scrollController,
          slivers: [
            SliverAppBar(
              expandedHeight: 200,
              pinned: true,
              actions: [
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh podcast',
                  onPressed: () => _refreshKey.currentState?.show(),
                ),
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: 'Podcast settings',
                  onPressed: () =>
                      context.push(AppRoutes.podcastSettings(podcast.id)),
                ),
              ],
              flexibleSpace: FlexibleSpaceBar(
                title: Semantics(
                  header: true,
                  label: podcast.title,
                  child: ExcludeSemantics(
                    child: Text(
                      podcast.title,
                      style:
                          Theme.of(
                            context,
                          ).textTheme.titleMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                    ),
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
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Semantics(
                  header: true,
                  label: 'Episodes',
                  child: ExcludeSemantics(
                    child: Text(
                      'Episodes',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Semantics(
                  label: 'Filter episodes',
                  child: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('All')),
                      ButtonSegment(value: true, label: Text('Unplayed')),
                    ],
                    selected: {_showUnplayedOnly},
                    onSelectionChanged: (selection) =>
                        setState(() => _showUnplayedOnly = selection.first),
                  ),
                ),
              ),
            ),
            episodes.when(
              data: (list) {
                final displayed = _showUnplayedOnly
                    ? list
                          .where((e) => e.status != EpisodeStatus.played)
                          .toList()
                    : list;
                return displayed.isEmpty
                    ? const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('No episodes yet.'),
                        ),
                      )
                    : SliverList.separated(
                        itemCount: displayed.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (ctx, index) {
                          final episode = displayed[index];
                          final actions =
                              ref.watch(episodeActionsProvider).asData?.value ??
                              defaultEpisodeActions;
                          return EpisodeListTile(
                            episode: episode,
                            quickActions: buildEpisodeActions(
                              episode: episode,
                              order: actions,
                              context: ctx,
                              ref: ref,
                              onPlay: () => playEpisodeNow(
                                context: ctx,
                                ref: ref,
                                episode: episode,
                              ),
                            ),
                          );
                        },
                      );
              },
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
