import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/constants/urls.dart';
import '../../../../data/db/enums.dart';
import '../../../../features/bookmarks/presentation/providers/bookmarks_providers.dart';
import '../../../../features/downloads/data/download_manager.dart';
import '../../../../features/downloads/presentation/providers/downloads_providers.dart';
import '../../../../features/player/presentation/providers/player_providers.dart';
import '../../../../features/settings/domain/quick_action_definition.dart';
import '../../../../features/settings/presentation/providers/settings_providers.dart';
import '../../domain/episode.dart';
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

  Podcast get podcast => widget.podcast;

  @override
  Widget build(BuildContext context) {
    final episodes = ref.watch(episodesProvider(widget.podcast.id));
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
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Semantics(
                header: true,
                child: Text(
                  'Episodes',
                  style: Theme.of(context).textTheme.titleLarge,
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
                  ? list.where((e) => e.status != EpisodeStatus.played).toList()
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
                          quickActions: _buildEpisodeActions(
                            ctx,
                            episode,
                            actions,
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
    );
  }

  List<EpisodeQuickActionItem> _buildEpisodeActions(
    BuildContext context,
    Episode episode,
    List<EpisodeAction> order,
  ) {
    return order.map((action) {
      return switch (action) {
        EpisodeAction.playNow => EpisodeQuickActionItem(
          label: action.label,
          onInvoke: () => _play(episode),
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
          onInvoke: () async {
            final newStatus = episode.status == EpisodeStatus.played
                ? EpisodeStatus.newEpisode
                : EpisodeStatus.played;
            await ref
                .read(podcastRepositoryProvider)
                .updateEpisodeStatus(episode.id, newStatus);
            // When marking an inQueue episode as played, also remove it
            // from the queue (internal removal — status already set above).
            if (newStatus == EpisodeStatus.played &&
                episode.status == EpisodeStatus.inQueue) {
              await ref
                  .read(queueRepositoryProvider)
                  .removeFromQueue(episode.id);
            }
          },
        ),
        EpisodeAction.openShowNotes => EpisodeQuickActionItem(
          label: action.label,
          onInvoke: () => showDialog<void>(
            context: context,
            builder: (_) => AlertDialog(
              title: Text(episode.title),
              content: SingleChildScrollView(
                child: episode.description != null
                    ? Html(
                        data: episode.description!,
                        onLinkTap: (url, _, __) async {
                          if (url == null) return;
                          final uri = Uri.tryParse(url);
                          if (uri != null) await launchUrl(uri);
                        },
                      )
                    : const Text('No show notes available.'),
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
        EpisodeAction.bookmark => EpisodeQuickActionItem(
          label: action.label,
          onInvoke: () async {
            final handler = ref.read(audioHandlerProvider);
            final pos = handler.position.inSeconds;
            await ref
                .read(bookmarkRepositoryProvider)
                .addBookmark(episode.id, pos);
            if (context.mounted) {
              final m = pos ~/ 60;
              final s = (pos % 60).toString().padLeft(2, '0');
              SemanticsService.sendAnnouncement(
                View.of(context),
                'Bookmarked at $m:$s',
                TextDirection.ltr,
              );
            }
          },
        ),
        EpisodeAction.download => EpisodeQuickActionItem(
          label: switch (episode.downloadStatus) {
            DownloadStatus.downloaded => 'Remove download',
            DownloadStatus.downloading ||
            DownloadStatus.pending => 'Cancel download',
            DownloadStatus.failed => 'Retry download',
            DownloadStatus.none => 'Download',
          },
          onInvoke: () async {
            final mgr = ref.read(downloadManagerProvider);
            final view = View.of(context);
            switch (episode.downloadStatus) {
              case DownloadStatus.downloaded:
                await mgr.deleteDownload(episode.id);
                if (context.mounted) {
                  SemanticsService.sendAnnouncement(
                    view,
                    'Download removed',
                    TextDirection.ltr,
                  );
                }
              case DownloadStatus.downloading:
              case DownloadStatus.pending:
                await mgr.cancelDownload(episode.id);
                if (context.mounted) {
                  SemanticsService.sendAnnouncement(
                    view,
                    'Download cancelled',
                    TextDirection.ltr,
                  );
                }
              case DownloadStatus.none:
              case DownloadStatus.failed:
                final result = await mgr.downloadEpisode(
                  episode.id,
                  onComplete: (message) => SemanticsService.sendAnnouncement(
                    view,
                    message,
                    TextDirection.ltr,
                  ),
                );
                if (!context.mounted) return;
                SemanticsService.sendAnnouncement(
                  view,
                  switch (result) {
                    DownloadStartResult.started => 'Download started',
                    DownloadStartResult.skippedNoWifi =>
                      'Download requires Wi-Fi',
                    DownloadStartResult.alreadyDownloaded =>
                      'Already downloaded',
                    DownloadStartResult.alreadyDownloading =>
                      'Already downloading',
                    DownloadStartResult.failed => 'Download failed',
                    DownloadStartResult.notFound => 'Episode unavailable',
                  },
                  TextDirection.ltr,
                );
            }
          },
        ),
        EpisodeAction.share => EpisodeQuickActionItem(
          label: action.label,
          onInvoke: () async {
            final handler = ref.read(audioHandlerProvider);
            final currentEpisodeId =
                handler.mediaItem.value?.extras?['episodeId'] as int?;
            final positionSeconds = currentEpisodeId == episode.id
                ? handler.position.inSeconds
                : episode.positionSeconds;
            final url = '$kEpisodeBaseUrl/${episode.id}?t=$positionSeconds';
            await SharePlus.instance.share(
              ShareParams(text: url, subject: episode.title),
            );
          },
        ),
      };
    }).toList();
  }

  void _play(Episode episode) {
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
        extras: {
          'episodeId': episode.id,
          'podcastId': podcast.id,
          if (podcast.speedOverride != null)
            'speedOverride': podcast.speedOverride!,
        },
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
