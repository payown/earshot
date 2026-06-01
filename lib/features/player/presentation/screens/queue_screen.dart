import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../data/db/enums.dart';
import '../../../../features/downloads/data/download_manager.dart';
import '../../../../features/downloads/presentation/providers/downloads_providers.dart';
import '../../../../features/settings/presentation/providers/settings_providers.dart';
import '../../../../features/subscriptions/domain/episode.dart';
import '../../../../features/subscriptions/presentation/providers/subscriptions_providers.dart';
import '../providers/player_providers.dart';

String? _semanticDuration(Episode ep) {
  if (ep.durationSeconds == null) return null;
  final total = ep.durationSeconds!;
  final position = ep.positionSeconds;
  if (position > 0 && position < (total * 0.95).round()) {
    return '${_verboseDuration(total - position)} remaining';
  }
  return _verboseDuration(total);
}

String _verboseDuration(int totalSeconds) {
  final h = totalSeconds ~/ 3600;
  final m = (totalSeconds % 3600) ~/ 60;
  final s = totalSeconds % 60;
  final parts = <String>[];
  if (h > 0) parts.add('$h ${h == 1 ? 'hour' : 'hours'}');
  if (m > 0) parts.add('$m ${m == 1 ? 'minute' : 'minutes'}');
  if (s > 0 || parts.isEmpty) parts.add('$s ${s == 1 ? 'second' : 'seconds'}');
  return parts.join(', ');
}

String? _downloadStatusLabel(DownloadStatus status) => switch (status) {
  DownloadStatus.downloaded => 'downloaded',
  DownloadStatus.downloading || DownloadStatus.pending => 'downloading',
  DownloadStatus.failed => 'download failed',
  DownloadStatus.none => null,
};

void _playEpisode(WidgetRef ref, Episode episode) {
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
      artUri: episode.artworkUrl != null
          ? Uri.parse(episode.artworkUrl!)
          : null,
      duration: episode.durationSeconds != null
          ? Duration(seconds: episode.durationSeconds!)
          : null,
      extras: {'episodeId': episode.id, 'podcastId': episode.podcastId},
    ),
    resumePositionSeconds: resumePosition,
  );
}

class QueueScreen extends ConsumerWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(queueProvider);
    final subs = ref.watch(subscriptionsProvider).asData?.value;
    final podcastTitles = <int, String>{
      if (subs != null)
        for (final p in subs) p.id: p.title,
    };
    final autoDownload = ref.watch(autoDownloadQueueProvider).value ?? false;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Queue'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => context.push(AppRoutes.settings),
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: SwitchListTile(
              title: const Text('Auto-download new episodes'),
              subtitle: const Text(
                'Episodes are downloaded when you add them to your queue',
              ),
              value: autoDownload,
              onChanged: ref.watch(autoDownloadQueueProvider).isLoading
                  ? null
                  : (val) async {
                      try {
                        await ref
                            .read(autoDownloadQueueProvider.notifier)
                            .set(val);
                        if (val) {
                          unawaited(
                            ref
                                .read(downloadManagerProvider)
                                .downloadQueueEpisodes(),
                          );
                        }
                        if (context.mounted) {
                          SemanticsService.sendAnnouncement(
                            View.of(context),
                            val
                                ? 'Auto-download enabled'
                                : 'Auto-download disabled',
                            TextDirection.ltr,
                          );
                        }
                      } catch (_) {
                        if (context.mounted) {
                          SemanticsService.sendAnnouncement(
                            View.of(context),
                            'Could not update auto-download setting',
                            TextDirection.ltr,
                          );
                        }
                      }
                    },
            ),
          ),
          queue.when(
            data: (episodes) => episodes.isEmpty
                ? SliverToBoxAdapter(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ExcludeSemantics(
                              child: Icon(
                                Icons.queue_music,
                                size: 64,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'Queue is empty',
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Add episodes to play them in order.',
                              style:
                                  Theme.of(
                                    context,
                                  ).textTheme.bodyMedium?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                : SliverList.builder(
                    itemCount: episodes.length,
                    itemBuilder: (context, index) {
                      final episode = episodes[index];
                      final total = episodes.length;
                      final position = index + 1;
                      final isFirst = index == 0;
                      final isLast = index == total - 1;

                      final durationLabel = _semanticDuration(episode);
                      final downloadLabel = _downloadStatusLabel(
                        episode.downloadStatus,
                      );
                      final podcastTitle = podcastTitles[episode.podcastId];
                      final labelParts = [
                        episode.title,
                        if (podcastTitle != null) podcastTitle,
                        'In queue, position $position of $total',
                        if (durationLabel != null) durationLabel,
                        if (downloadLabel != null) downloadLabel,
                      ];
                      final queueLabel = labelParts.join(', ');

                      final downloadAction = _buildDownloadAction(
                        episode,
                        ref,
                        context,
                      );

                      return Semantics(
                        key: ValueKey(episode.id),
                        container: true,
                        label: queueLabel,
                        customSemanticsActions: {
                          const CustomSemanticsAction(label: 'Play'): () =>
                              _playEpisode(ref, episode),
                          const CustomSemanticsAction(
                            label: 'Move to top',
                          ): () async {
                            final view = View.of(context);
                            await ref
                                .read(queueRepositoryProvider)
                                .moveToTop(episode.id);
                            SemanticsService.sendAnnouncement(
                              view,
                              'Moved to top, now position 1 of $total',
                              TextDirection.ltr,
                            );
                          },
                          const CustomSemanticsAction(
                            label: 'Move to bottom',
                          ): () async {
                            final view = View.of(context);
                            await ref
                                .read(queueRepositoryProvider)
                                .moveToBottom(episode.id);
                            SemanticsService.sendAnnouncement(
                              view,
                              'Moved to bottom, now position $total of $total',
                              TextDirection.ltr,
                            );
                          },
                          if (!isFirst)
                            const CustomSemanticsAction(
                              label: 'Move up',
                            ): () async {
                              final view = View.of(context);
                              await ref
                                  .read(queueRepositoryProvider)
                                  .moveUp(episode.id);
                              SemanticsService.sendAnnouncement(
                                view,
                                'Moved up, now position ${position - 1} of $total',
                                TextDirection.ltr,
                              );
                            },
                          if (!isLast)
                            const CustomSemanticsAction(
                              label: 'Move down',
                            ): () async {
                              final view = View.of(context);
                              await ref
                                  .read(queueRepositoryProvider)
                                  .moveDown(episode.id);
                              SemanticsService.sendAnnouncement(
                                view,
                                'Moved down, now position ${position + 1} of $total',
                                TextDirection.ltr,
                              );
                            },
                          const CustomSemanticsAction(
                            label: 'Remove from queue',
                          ): () => ref
                              .read(queueRepositoryProvider)
                              .cancelFromQueue(episode.id),
                          if (downloadAction != null)
                            CustomSemanticsAction(
                              label: downloadAction.label,
                            ): downloadAction.onInvoke,
                        },
                        child: ExcludeSemantics(
                          child: ListTile(
                            leading: Text(
                              '$position',
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                            title: Text(
                              episode.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Wrap(
                                spacing: 4,
                                children: [
                                  Chip(
                                    label: const Text('In queue'),
                                    visualDensity: VisualDensity.compact,
                                    backgroundColor: Theme.of(
                                      context,
                                    ).colorScheme.secondaryContainer,
                                    labelStyle: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSecondaryContainer,
                                        ),
                                    padding: EdgeInsets.zero,
                                  ),
                                  if (episode.downloadStatus ==
                                      DownloadStatus.downloaded)
                                    Chip(
                                      avatar: ExcludeSemantics(
                                        child: Icon(
                                          Icons.download_done,
                                          size: 14,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSecondaryContainer,
                                        ),
                                      ),
                                      label: const Text('Downloaded'),
                                      visualDensity: VisualDensity.compact,
                                      backgroundColor: Theme.of(
                                        context,
                                      ).colorScheme.secondaryContainer,
                                      labelStyle: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSecondaryContainer,
                                          ),
                                      padding: EdgeInsets.zero,
                                    )
                                  else if (episode.downloadStatus ==
                                          DownloadStatus.downloading ||
                                      episode.downloadStatus ==
                                          DownloadStatus.pending)
                                    Chip(
                                      avatar: ExcludeSemantics(
                                        child: Icon(
                                          Icons.downloading,
                                          size: 14,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSecondaryContainer,
                                        ),
                                      ),
                                      label: const Text('Downloading'),
                                      visualDensity: VisualDensity.compact,
                                      backgroundColor: Theme.of(
                                        context,
                                      ).colorScheme.secondaryContainer,
                                      labelStyle: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSecondaryContainer,
                                          ),
                                      padding: EdgeInsets.zero,
                                    ),
                                ],
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.play_arrow),
                                  tooltip: 'Play',
                                  onPressed: () => _playEpisode(ref, episode),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.arrow_upward),
                                  tooltip: 'Move up',
                                  onPressed: isFirst
                                      ? null
                                      : () async {
                                          final view = View.of(context);
                                          await ref
                                              .read(queueRepositoryProvider)
                                              .moveUp(episode.id);
                                          SemanticsService.sendAnnouncement(
                                            view,
                                            'Moved up, now position ${position - 1} of $total',
                                            TextDirection.ltr,
                                          );
                                        },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.arrow_downward),
                                  tooltip: 'Move down',
                                  onPressed: isLast
                                      ? null
                                      : () async {
                                          final view = View.of(context);
                                          await ref
                                              .read(queueRepositoryProvider)
                                              .moveDown(episode.id);
                                          SemanticsService.sendAnnouncement(
                                            view,
                                            'Moved down, now position ${position + 1} of $total',
                                            TextDirection.ltr,
                                          );
                                        },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.remove_circle_outline),
                                  tooltip: 'Remove from queue',
                                  onPressed: () => ref
                                      .read(queueRepositoryProvider)
                                      .cancelFromQueue(episode.id),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
            loading: () => SliverToBoxAdapter(
              child: Center(
                child: Semantics(
                  label: 'Loading queue',
                  child: const CircularProgressIndicator(),
                ),
              ),
            ),
            error: (_, __) => SliverToBoxAdapter(
              child: Center(
                child: Text(
                  'Could not load queue. Please try again.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  _DownloadActionItem? _buildDownloadAction(
    Episode episode,
    WidgetRef ref,
    BuildContext context,
  ) {
    final view = View.of(context);
    switch (episode.downloadStatus) {
      case DownloadStatus.none:
      case DownloadStatus.failed:
        return _DownloadActionItem(
          label: episode.downloadStatus == DownloadStatus.failed
              ? 'Retry download'
              : 'Download',
          onInvoke: () async {
            final result = await ref
                .read(downloadManagerProvider)
                .downloadEpisode(
                  episode.id,
                  onComplete: (msg) => SemanticsService.sendAnnouncement(
                    view,
                    msg,
                    TextDirection.ltr,
                  ),
                );
            if (!context.mounted) return;
            SemanticsService.sendAnnouncement(
              view,
              switch (result) {
                DownloadStartResult.started => 'Download started',
                DownloadStartResult.skippedNoWifi => 'Download requires Wi-Fi',
                DownloadStartResult.alreadyDownloaded => 'Already downloaded',
                DownloadStartResult.alreadyDownloading => 'Already downloading',
                DownloadStartResult.failed => 'Download failed',
                DownloadStartResult.notFound => 'Episode unavailable',
              },
              TextDirection.ltr,
            );
          },
        );
      case DownloadStatus.downloading:
      case DownloadStatus.pending:
        return _DownloadActionItem(
          label: 'Cancel download',
          onInvoke: () =>
              ref.read(downloadManagerProvider).cancelDownload(episode.id),
        );
      case DownloadStatus.downloaded:
        return _DownloadActionItem(
          label: 'Remove download',
          onInvoke: () =>
              ref.read(downloadManagerProvider).deleteDownload(episode.id),
        );
    }
  }
}

class _DownloadActionItem {
  const _DownloadActionItem({required this.label, required this.onInvoke});

  final String label;
  final VoidCallback onInvoke;
}
