import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../data/db/enums.dart';
import '../features/bookmarks/presentation/providers/bookmarks_providers.dart';
import '../features/downloads/data/download_manager.dart';
import '../features/downloads/data/export_coordinator.dart';
import '../features/downloads/presentation/providers/downloads_providers.dart';
import '../features/player/data/audio_handler.dart';
import '../features/player/data/queue_repository.dart';
import '../features/player/presentation/providers/player_providers.dart';
import '../features/settings/domain/quick_action_definition.dart';
import '../features/settings/presentation/providers/settings_providers.dart';
import '../features/subscriptions/domain/episode.dart';
import '../features/subscriptions/presentation/providers/subscriptions_providers.dart';
import 'audio_export.dart';
import 'constants/urls.dart';
import 'episode_playback.dart';
import 'presentation/widgets/episode_actions_sheet.dart';
import 'presentation/widgets/show_notes_dialog.dart';

/// Where an episode's action list is being shown.
///
/// This is the single source of truth for *which* actions an episode offers.
/// The goal is that a user's configured action list is honored everywhere: when
/// they edit it in Settings, those edits show up on every screen. So eligibility
/// is **capability-based**, not screen-based — an action is hidden only when the
/// episode itself can't support it (its state) or a dedicated visible control
/// already covers it. The user's configured [order] controls ordering and the
/// default (first) action.
enum EpisodeActionContext {
  /// General browse lists — inbox, library, podcast detail, downloads. Offers
  /// every core action, filtered only by the episode's own state.
  list,

  /// The queue screen. Same as [list], minus the two queue-positioning actions
  /// (play next, add to end of queue): the queue has its own dedicated, visible
  /// Move-to-top/up/down/bottom + Remove controls, which the caller appends, so
  /// emitting the generic versions here would just duplicate them.
  queue,
}

/// The actions eligible for [episode] in [actionContext]. Capability-based, not
/// screen-based, so the same episode offers the same actions wherever it's shown
/// — with the only differences tied to the episode's state or to a screen's
/// dedicated controls, never to screen preference.
Set<EpisodeAction> allowedEpisodeActions(
  EpisodeActionContext actionContext,
  Episode episode,
) {
  // The full state-filtered set. Bookmark only when there's a real position to
  // bookmark, so it's never a dead "bookmark at 0:00".
  final standard = <EpisodeAction>{
    EpisodeAction.playNow,
    EpisodeAction.playNext,
    EpisodeAction.addToEndOfQueue,
    EpisodeAction.markPlayed,
    EpisodeAction.openShowNotes,
    EpisodeAction.download,
    EpisodeAction.share,
    EpisodeAction.exportAudio,
    if (episode.positionSeconds > 0) EpisodeAction.bookmark,
  };

  switch (actionContext) {
    case EpisodeActionContext.list:
      return standard;
    case EpisodeActionContext.queue:
      // Drop the two queue-positioning actions — the queue's own Move/Remove
      // block (appended by the caller) is the single source for those.
      return standard
        ..remove(EpisodeAction.playNext)
        ..remove(EpisodeAction.addToEndOfQueue);
  }
}

/// Returns the [available] action items in the user's configured [order],
/// skipping any action that isn't present. Keeps ordering logic in one place so
/// every screen — including ones that can't use [buildEpisodeActions] (e.g.
/// search previews, which aren't persisted episodes) — honors the same order.
List<EpisodeQuickActionItem> orderEpisodeActionItems(
  List<EpisodeAction> order,
  Map<EpisodeAction, EpisodeQuickActionItem> available,
) {
  return [
    for (final action in order)
      if (available[action] != null) available[action]!,
  ];
}

/// The state-variant labels each configurable [EpisodeAction] can present in a
/// row's VoiceOver Actions rotor, in a stable sub-order. Only one variant shows
/// per row at a time (see [_buildItem]); seeding all of them adjacently keeps a
/// logical action's rotor slot stable as the episode's state changes. MUST stay
/// in sync with every label [_buildItem] can emit (a test asserts this).
const episodeActionVariantLabels = <EpisodeAction, List<String>>{
  EpisodeAction.playNow: ['Play now'],
  EpisodeAction.playNext: ['Play next', 'Move to play next'],
  EpisodeAction.addToEndOfQueue: ['Add to end of queue', 'Remove from queue'],
  EpisodeAction.markPlayed: ['Mark as played', 'Mark as unplayed'],
  EpisodeAction.openShowNotes: ['Open show notes'],
  EpisodeAction.bookmark: ['Bookmark current spot'],
  EpisodeAction.download: [
    'Download',
    'Remove download',
    'Cancel download',
    'Retry download',
  ],
  EpisodeAction.share: ['Share'],
  EpisodeAction.exportAudio: ['Export audio file'],
};

/// The queue-screen-only move actions, appended after the configured episode
/// actions so they always sort last on queue rows. Not user-configurable.
const queueMoveRotorLabels = <String>[
  'Move to top',
  'Move up',
  'Move down',
  'Move to bottom',
];

/// The ordered rotor labels for [order]: each action's variant labels (adjacent)
/// in the user's configured order, then the queue move block.
///
/// iOS VoiceOver orders the Actions rotor by an internal id Flutter assigns the
/// first time each distinct label is seen, then sorts on it (see
/// [CustomSemanticsAction.getIdentifier] and the `customSemanticsActionIds
/// ..sort()` in the framework's semantics.dart). Insertion order in
/// `customSemanticsActions` cannot change the rotor; only id (first-seen) order
/// can. So seeding the ids once at startup in this order makes the rotor follow
/// the user's configuration. See [seedEpisodeActionRotorOrder].
List<String> episodeActionRotorLabels(List<EpisodeAction> order) {
  return [
    for (final action in order) ...?episodeActionVariantLabels[action],
    ...queueMoveRotorLabels,
  ];
}

/// Seeds the VoiceOver Actions rotor order from the user's configured [order].
/// MUST be called once in `main()` before `runApp` and before any episode row
/// builds, or the rotor falls back to arbitrary first-seen order. The id cache
/// cannot be reset in a release build, so a configuration change takes effect on
/// the next app launch. See [episodeActionRotorLabels].
void seedEpisodeActionRotorOrder(List<EpisodeAction> order) {
  for (final label in episodeActionRotorLabels(order)) {
    CustomSemanticsAction.getIdentifier(CustomSemanticsAction(label: label));
  }
}

/// Builds the ordered list of [EpisodeQuickActionItem]s for a given episode.
///
/// [onPlay] is caller-supplied because play logic differs per screen
/// (the podcast detail screen passes podcast artwork/speed; the inbox has its
/// own resume logic). All other actions are handled here.
///
/// [actionContext] selects the eligible action set (see [allowedEpisodeActions]);
/// the actions appear in the user's configured [order].
///
/// Keep the order stable across every row on purpose: iOS VoiceOver remembers
/// the Actions rotor by *position*, not by label, and exposes no API to reset
/// the rotor cursor per row. Because the same index maps to the same action on
/// every episode, a user who arms a rotor slot never double-flicks "the same
/// slot" and hits a different action on the next episode. Do NOT reorder actions
/// per-row based on episode state — that reintroduces exactly that hazard.
List<EpisodeQuickActionItem> buildEpisodeActions({
  required Episode episode,
  required List<EpisodeAction> order,
  required BuildContext context,
  required WidgetRef ref,
  required VoidCallback onPlay,
  EpisodeActionContext actionContext = EpisodeActionContext.list,
}) {
  final allowed = allowedEpisodeActions(actionContext, episode);
  final items = <EpisodeQuickActionItem>[];

  for (final action in order) {
    if (!allowed.contains(action)) continue;

    final item = _buildItem(action, episode, context, ref, onPlay);
    if (item != null) items.add(item);
  }

  return items;
}

/// "Export audio file" — a first-class, user-configurable [EpisodeAction]
/// like any other. If the episode isn't downloaded yet, tapping it downloads
/// in the background and shares when ready (see [exportEpisodeAudio]).
EpisodeQuickActionItem _buildExportItem(
  Episode episode,
  BuildContext context,
  WidgetRef ref,
) {
  return EpisodeQuickActionItem(
    label: EpisodeAction.exportAudio.label,
    onInvoke: () => exportEpisodeAudio(
      episodeId: episode.id,
      ref: ref,
      context: context,
      subject: episode.title,
    ),
  );
}

/// Exports an episode's audio via the OS share sheet (Save to Files, AirDrop,
/// open-in another app), downloading it first if needed.
///
/// Shared by the episode actions list/rotor and the Now Playing player.
/// - Already downloaded → announce "Preparing export" and share immediately.
/// - Not downloaded → if on cellular, confirm once (overriding Wi-Fi-only),
///   then hand off to [ExportCoordinator], which downloads in the background and
///   opens the share sheet when ready (surfacing progress/errors app-wide).
Future<void> exportEpisodeAudio({
  required int episodeId,
  required WidgetRef ref,
  required BuildContext context,
  String? subject,
}) async {
  final view = View.of(context);
  final manager = ref.read(downloadManagerProvider);

  // Already downloaded → share now (prepareExportFile returns null otherwise).
  final ready = await manager.prepareExportFile(episodeId);
  if (ready != null) {
    SemanticsService.sendAnnouncement(
      view,
      'Preparing export',
      TextDirection.ltr,
    );
    await shareExportedAudioFile(ready, subject: subject);
    return;
  }

  // Needs a download. An explicit Export tap overrides Wi-Fi-only, but confirm
  // cellular use once.
  if (await manager.isOnCellularConnection()) {
    final confirmed = await ref.read(cellularExportConfirmedProvider.future);
    if (!confirmed) {
      if (!context.mounted) return;
      final ok = await _confirmCellularExport(context);
      if (ok != true) {
        SemanticsService.sendAnnouncement(
          view,
          'Export cancelled',
          TextDirection.ltr,
        );
        return;
      }
      await ref.read(cellularExportConfirmedProvider.notifier).set(true);
    }
  }

  await ref
      .read(exportCoordinatorProvider)
      .requestExport(episodeId, subject: subject);
}

/// One-time "download on cellular?" confirmation. Mirrors the project's
/// confirm-dialog pattern (showDialog<bool> + AlertDialog + barrierLabel).
Future<bool?> _confirmCellularExport(BuildContext context) {
  return showDialog<bool>(
    context: context,
    barrierLabel: 'Dismiss cellular download confirmation',
    builder: (dialogContext) => AlertDialog(
      title: const Text('Download on cellular?'),
      content: const Text(
        'Exporting this episode will download it now using cellular data.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Continue'),
        ),
      ],
    ),
  );
}

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
          showEpisodeShowNotesDialog(
            context,
            title: episode.title,
            descriptionHtml: episode.description,
          );
        },
      );

    case EpisodeAction.bookmark:
      return EpisodeQuickActionItem(
        label: action.label,
        onInvoke: () async {
          final handler = ref.read(audioHandlerProvider);
          // Bookmark THIS episode's spot: the live player position only when
          // it's the one playing, otherwise its saved position. Mirrors the
          // share action so a bookmark from a list row never records the
          // currently-playing episode's position by mistake.
          final currentEpisodeId =
              handler.mediaItem.value?.extras?['episodeId'] as int?;
          final pos = currentEpisodeId == episode.id
              ? handler.position.inSeconds
              : episode.positionSeconds;
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

    case EpisodeAction.exportAudio:
      return _buildExportItem(episode, context, ref);
  }
}
