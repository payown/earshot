import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart' hide Column, View;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/providers/core_providers.dart';
import '../../../../core/router/app_router.dart';
import '../../../../data/db/enums.dart';
import '../../../player/presentation/providers/player_providers.dart';
import '../../../subscriptions/domain/episode.dart';
import '../../../subscriptions/presentation/providers/subscriptions_providers.dart';
import '../providers/downloads_providers.dart';

class InboxScreen extends ConsumerWidget {
  const InboxScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // All episodes across all podcasts with newEpisode status, newest first.
    final allEpisodes = ref.watch(_inboxEpisodesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Inbox'),
        actions: [
          if (allEpisodes.asData?.value.isNotEmpty ?? false)
            IconButton(
              icon: const Icon(Icons.done_all),
              tooltip: 'Mark all as played',
              onPressed: () => _confirmMarkAllPlayed(context, ref),
            ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => context.push(AppRoutes.settings),
          ),
        ],
      ),
      body: allEpisodes.when(
        data: (episodes) => episodes.isEmpty
            ? _EmptyInbox()
            : ListView.builder(
                itemCount: episodes.length,
                itemBuilder: (context, index) => _InboxEpisodeTile(
                  episode: episodes[index],
                  onPlay: () => _playEpisode(context, episodes[index], ref),
                  onAddToQueue: () => unawaited(
                    ref
                        .read(queueRepositoryProvider)
                        .addToQueue(episodes[index].id),
                  ),
                  onMarkPlayed: () => unawaited(
                    ref
                        .read(podcastRepositoryProvider)
                        .updateEpisodeStatus(
                          episodes[index].id,
                          EpisodeStatus.played,
                        ),
                  ),
                  onDelete: () => unawaited(
                    _confirmDelete(context, ref, episodes[index]),
                  ),
                ),
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
    );
  }

  void _playEpisode(BuildContext context, Episode episode, WidgetRef ref) {
    final resumePosition =
        episode.positionSeconds > 0 &&
            episode.durationSeconds != null &&
            episode.positionSeconds < (episode.durationSeconds! * 0.95).round()
        ? episode.positionSeconds
        : 0;
    final speedOverride = ref
        .read(podcastProvider(episode.podcastId))
        .value
        ?.speedOverride;
    unawaited(
      ref
          .read(audioHandlerProvider)
          .playEpisode(
            MediaItem(
              id: episode.audioUrl,
              title: episode.title,
              artUri: episode.artworkUrl != null
                  ? Uri.tryParse(episode.artworkUrl!)
                  : null,
              duration: episode.durationSeconds != null
                  ? Duration(seconds: episode.durationSeconds!)
                  : null,
              extras: {
                'episodeId': episode.id,
                'podcastId': episode.podcastId,
                if (speedOverride != null) 'speedOverride': speedOverride,
              },
            ),
            resumePositionSeconds: resumePosition,
          ),
    );
    unawaited(
      ref.read(queueRepositoryProvider).addToQueue(episode.id),
    );
    unawaited(
      ref
          .read(podcastRepositoryProvider)
          .updateEpisodeStatus(episode.id, EpisodeStatus.played),
    );
    SemanticsService.sendAnnouncement(
      View.of(context),
      'Playing ${episode.title}',
      TextDirection.ltr,
    );
  }

  Future<void> _confirmMarkAllPlayed(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final count = ref.read(_inboxEpisodesProvider).asData?.value.length ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Mark all as played?'),
        content: Text(
          'This will clear all $count episodes from your inbox.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Mark all played'),
          ),
        ],
      ),
    );
    if (!context.mounted) return;
    if (confirmed == true) {
      try {
        await ref.read(podcastRepositoryProvider).markAllInboxPlayed();
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not mark all as played. Try again.'),
            ),
          );
        }
      }
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Episode episode,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete episode?'),
        content: Text('Remove "${episode.title}" from Inbox?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!context.mounted) return;
    if (confirmed == true) {
      try {
        await ref.read(downloadManagerProvider).deleteDownload(episode.id);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not delete the download file. Try again.'),
            ),
          );
        }
        return;
      }
      try {
        await ref
            .read(podcastRepositoryProvider)
            .updateEpisodeStatus(episode.id, EpisodeStatus.played);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not mark episode as played. Try again.'),
            ),
          );
        }
      }
    }
  }
}

// Provider for inbox: all newEpisode-status episodes, newest first.
final _inboxEpisodesProvider = StreamProvider<List<Episode>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.episodes)
        ..where((e) => e.status.equals(EpisodeStatus.newEpisode.name))
        ..orderBy([(e) => OrderingTerm.desc(e.pubDate)]))
      .watch()
      .map(
        (rows) => rows
            .map(
              (r) => Episode(
                id: r.id,
                podcastId: r.podcastId,
                guid: r.guid,
                title: r.title,
                description: r.description,
                audioUrl: r.audioUrl,
                durationSeconds: r.durationSeconds,
                pubDate: r.pubDate,
                artworkUrl: r.artworkUrl,
                episodeNumber: r.episodeNumber,
                seasonNumber: r.seasonNumber,
                chapterUrl: r.chapterUrl,
                transcriptUrl: r.transcriptUrl,
                status: r.status,
                downloadStatus: r.downloadStatus,
                downloadPath: r.downloadPath,
                positionSeconds: r.positionSeconds,
                playedAt: r.playedAt,
                createdAt: r.createdAt,
              ),
            )
            .toList(),
      );
});

class _EmptyInbox extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: Icon(
                Icons.inbox,
                size: 64,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Inbox is empty',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'New episodes from your subscriptions appear here.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _InboxEpisodeTile extends StatelessWidget {
  const _InboxEpisodeTile({
    required this.episode,
    required this.onPlay,
    required this.onAddToQueue,
    required this.onMarkPlayed,
    required this.onDelete,
  });

  final Episode episode;
  final VoidCallback onPlay;
  final VoidCallback onAddToQueue;
  final VoidCallback onMarkPlayed;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      onTap: onPlay,
      label: '${episode.title}, New episode',
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Add to queue'): onAddToQueue,
        const CustomSemanticsAction(label: 'Mark as played'): onMarkPlayed,
        const CustomSemanticsAction(label: 'Delete'): onDelete,
      },
      child: ExcludeSemantics(
        child: ListTile(
          onTap: onPlay,
          title: Text(
            episode.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Chip(
                label: const Text('New'),
                visualDensity: VisualDensity.compact,
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.primaryContainer,
                labelStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
                padding: EdgeInsets.zero,
              ),
              if (episode.pubDate != null)
                Text(
                  _formatDate(episode.pubDate!),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.queue_music),
                onPressed: onAddToQueue,
                tooltip: 'Add to queue',
              ),
              IconButton(
                icon: const Icon(Icons.check),
                onPressed: onMarkPlayed,
                tooltip: 'Mark as played',
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final diff = DateTime.now().difference(date);
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays} days ago';
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}
