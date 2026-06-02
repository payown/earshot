import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/db/enums.dart';
import '../features/bookmarks/presentation/providers/bookmarks_providers.dart';
import '../features/downloads/data/download_manager.dart';
import '../features/downloads/presentation/providers/downloads_providers.dart';
import '../features/player/presentation/providers/player_providers.dart';
import '../features/settings/domain/quick_action_definition.dart';
import '../features/settings/presentation/providers/settings_providers.dart';
import '../features/subscriptions/domain/episode.dart';
import '../features/subscriptions/presentation/providers/subscriptions_providers.dart';
import '../features/subscriptions/presentation/widgets/episode_list_tile.dart';
import 'constants/urls.dart';

/// Builds the ordered list of [EpisodeQuickActionItem]s for a given episode.
///
/// [onPlay] is caller-supplied because play logic differs per screen
/// (the podcast detail screen passes podcast artwork/speed; the inbox has its
/// own resume logic). All other actions are handled here.
///
/// Pass [allowedActions] to restrict which actions appear in a given context.
/// When null every action in [order] is included.
List<EpisodeQuickActionItem> buildEpisodeActions({
  required Episode episode,
  required List<EpisodeAction> order,
  required BuildContext context,
  required WidgetRef ref,
  required VoidCallback onPlay,
  Set<EpisodeAction>? allowedActions,
}) {
  final items = <EpisodeQuickActionItem>[];

  for (final action in order) {
    if (allowedActions != null && !allowedActions.contains(action)) continue;

    final item = _buildItem(action, episode, context, ref, onPlay);
    if (item != null) items.add(item);
  }

  return items;
}

EpisodeQuickActionItem? _buildItem(
  EpisodeAction action,
  Episode episode,
  BuildContext context,
  WidgetRef ref,
  VoidCallback onPlay,
) {
  switch (action) {
    case EpisodeAction.playNow:
      return EpisodeQuickActionItem(label: action.label, onInvoke: onPlay);

    case EpisodeAction.playNext:
      final alreadyQueued = episode.status == EpisodeStatus.inQueue;
      return EpisodeQuickActionItem(
        label: alreadyQueued ? 'Move to play next' : action.label,
        onInvoke: () async {
          await ref.read(queueRepositoryProvider).addAfterCurrent(episode.id);
          if (!alreadyQueued) {
            _triggerQueueDownloadIfEnabled(episode, ref, context);
          }
          if (context.mounted) {
            SemanticsService.sendAnnouncement(
              View.of(context),
              alreadyQueued ? 'Moved to play next' : 'Will play next',
              TextDirection.ltr,
            );
          }
        },
      );

    case EpisodeAction.addToEndOfQueue:
      if (episode.status == EpisodeStatus.inQueue) {
        return EpisodeQuickActionItem(
          label: 'Remove from queue',
          onInvoke: () async {
            await ref.read(queueRepositoryProvider).cancelFromQueue(episode.id);
            if (context.mounted) {
              SemanticsService.sendAnnouncement(
                View.of(context),
                'Removed from queue',
                TextDirection.ltr,
              );
            }
          },
        );
      }
      return EpisodeQuickActionItem(
        label: action.label,
        onInvoke: () async {
          await ref.read(queueRepositoryProvider).addToQueue(episode.id);
          _triggerQueueDownloadIfEnabled(episode, ref, context);
          if (context.mounted) {
            SemanticsService.sendAnnouncement(
              View.of(context),
              'Added to end of queue',
              TextDirection.ltr,
            );
          }
        },
      );

    case EpisodeAction.markPlayed:
      final isPlayed = episode.status == EpisodeStatus.played;
      return EpisodeQuickActionItem(
        label: isPlayed ? 'Mark as unplayed' : 'Mark as played',
        onInvoke: () async {
          final newStatus = isPlayed
              ? EpisodeStatus.newEpisode
              : EpisodeStatus.played;
          await ref
              .read(podcastRepositoryProvider)
              .updateEpisodeStatus(episode.id, newStatus);
          if (newStatus == EpisodeStatus.played &&
              episode.status == EpisodeStatus.inQueue) {
            await ref.read(queueRepositoryProvider).removeFromQueue(episode.id);
          }
        },
      );

    case EpisodeAction.openShowNotes:
      return EpisodeQuickActionItem(
        label: action.label,
        onInvoke: () => showDialog<void>(
          context: context,
          barrierLabel: 'Dismiss show notes',
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
      );

    case EpisodeAction.bookmark:
      return EpisodeQuickActionItem(
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
      );

    case EpisodeAction.download:
      return EpisodeQuickActionItem(
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
                  DownloadStartResult.alreadyDownloaded => 'Already downloaded',
                  DownloadStartResult.alreadyDownloading =>
                    'Already downloading',
                  DownloadStartResult.failed => 'Download failed',
                  DownloadStartResult.notFound => 'Episode unavailable',
                },
                TextDirection.ltr,
              );
          }
        },
      );

    case EpisodeAction.share:
      return EpisodeQuickActionItem(
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
      );
  }
}

// Downloads the episode if auto-download-queue is on and the episode is not
// already downloaded or actively downloading.
void _triggerQueueDownloadIfEnabled(
  Episode episode,
  WidgetRef ref,
  BuildContext context,
) {
  final autoDownload = ref.read(autoDownloadQueueProvider).value ?? false;
  if (!autoDownload) return;
  final status = episode.downloadStatus;
  if (status == DownloadStatus.downloaded ||
      status == DownloadStatus.downloading ||
      status == DownloadStatus.pending) {
    return;
  }
  unawaited(
    ref
        .read(downloadManagerProvider)
        .downloadEpisode(
          episode.id,
          onComplete: (message) {
            if (context.mounted) {
              SemanticsService.sendAnnouncement(
                View.of(context),
                message == 'Download complete'
                    ? '${episode.title} downloaded'
                    : 'Download failed for ${episode.title}',
                TextDirection.ltr,
              );
            }
          },
        ),
  );
}
