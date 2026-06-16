import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:earshot/core/utils/url_launcher.dart';

import '../data/db/enums.dart';
import '../features/bookmarks/presentation/providers/bookmarks_providers.dart';
import '../features/downloads/data/download_manager.dart';
import '../features/downloads/presentation/providers/downloads_providers.dart';
import '../features/player/data/audio_handler.dart';
import '../features/player/data/queue_repository.dart';
import '../features/player/presentation/providers/player_providers.dart';
import '../features/settings/domain/quick_action_definition.dart';
import '../features/subscriptions/domain/episode.dart';
import '../features/subscriptions/presentation/providers/subscriptions_providers.dart';
import 'constants/urls.dart';
import 'episode_playback.dart';
import 'presentation/widgets/episode_actions_sheet.dart';

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

  // "Export audio file" is intentionally not an [EpisodeAction] enum value (it
  // would clutter the user-configurable Quick Actions list with a row that's
  // hidden for most episodes). Append it directly, only when downloaded, so it
  // shows in the actions sheet and VoiceOver rotor exactly when the file exists.
  if (episode.downloadStatus == DownloadStatus.downloaded) {
    items.add(_buildExportItem(episode, context, ref));
  }

  return items;
}

EpisodeQuickActionItem _buildExportItem(
  Episode episode,
  BuildContext context,
  WidgetRef ref,
) {
  return EpisodeQuickActionItem(
    label: 'Export audio file',
    onInvoke: () async {
      final view = View.of(context);
      // Copying a multi-hour episode to a temp file isn't instant; without this
      // a VoiceOver user gets silence then a sudden jump when the share sheet
      // takes focus. The success path stays silent after — the OS share sheet
      // announces itself.
      SemanticsService.sendAnnouncement(
        view,
        'Preparing export',
        TextDirection.ltr,
      );
      final file = await ref
          .read(downloadManagerProvider)
          .prepareExportFile(episode.id);
      if (file == null) {
        if (context.mounted) {
          SemanticsService.sendAnnouncement(
            view,
            'Export unavailable',
            TextDirection.ltr,
          );
        }
        return;
      }
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile(
              file.path,
              mimeType: _audioMimeForExt(p.extension(file.path)),
            ),
          ],
          subject: episode.title,
        ),
      );
    },
  );
}

String _audioMimeForExt(String ext) => switch (ext.toLowerCase()) {
  '.mp3' => 'audio/mpeg',
  '.m4a' || '.mp4' || '.aac' => 'audio/mp4',
  '.ogg' || '.oga' => 'audio/ogg',
  '.wav' => 'audio/wav',
  '.flac' => 'audio/flac',
  _ => 'audio/mpeg',
};

/// Removes an episode from the queue, choosing the right behavior for the
/// currently-playing episode.
///
/// A plain `cancelFromQueue` on the episode that's playing does nothing visible
/// — the Queue screen pins the now-playing episode from player state, not the
/// queue table — and would mark a playing episode "new". So when [episodeId] is
/// the [currentEpisodeId], finish it instead: mark played, remove, and advance,
/// exactly like the player's "Mark as played" (#316). Returns true when that
/// mark-played path was taken so callers can announce accordingly.
Future<bool> removeEpisodeFromQueue({
  required int episodeId,
  required int? currentEpisodeId,
  required EarshotAudioHandler handler,
  required QueueRepository queueRepo,
}) async {
  if (episodeId == currentEpisodeId) {
    await handler.markCurrentEpisodePlayed();
    return true;
  }
  await queueRepo.cancelFromQueue(episodeId);
  return false;
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
            triggerQueueDownloadIfEnabled(episode, ref, context);
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
            final markedPlayed = await removeEpisodeFromQueue(
              episodeId: episode.id,
              currentEpisodeId:
                  ref.read(mediaItemProvider).value?.extras?['episodeId']
                      as int?,
              handler: ref.read(audioHandlerProvider),
              queueRepo: ref.read(queueRepositoryProvider),
            );
            if (context.mounted) {
              SemanticsService.sendAnnouncement(
                View.of(context),
                markedPlayed
                    ? 'Marked as played and removed from queue'
                    : 'Removed from queue',
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
          triggerQueueDownloadIfEnabled(episode, ref, context);
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
        onInvoke: () {
          // The sheet pops before invoking, so the captured tile context can
          // be defunct by the time this runs (e.g. the row was rebuilt away).
          if (!context.mounted) return;
          showDialog<void>(
            context: context,
            barrierLabel: 'Dismiss show notes',
            builder: (dialogContext) => AlertDialog(
              // Announced by VoiceOver/TalkBack when the dialog opens so the
              // user knows what surfaced.
              semanticLabel: 'Show notes',
              // The episode title heads the dialog so heading navigation lands
              // on it; the open announcement above already says "Show notes".
              title: Semantics(
                header: true,
                label: episode.title,
                child: ExcludeSemantics(child: Text(episode.title)),
              ),
              content: SingleChildScrollView(
                child: episode.description != null
                    ? Html(
                        data: episode.description!,
                        onLinkTap: (url, _, __) async {
                          if (url == null) return;
                          await safeLaunchUrl(url);
                        },
                      )
                    : Text(
                        'No show notes available.',
                        style: Theme.of(dialogContext).textTheme.bodyMedium
                            ?.copyWith(
                              color: Theme.of(
                                dialogContext,
                              ).colorScheme.onSurfaceVariant,
                            ),
                      ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Close'),
                ),
              ],
            ),
          );
        },
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
