import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart' hide Column, View;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/episode_action_builder.dart';
import '../../../../core/providers/core_providers.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/utils/time_format.dart';
import '../../../../data/db/enums.dart';
import '../../../player/presentation/providers/player_providers.dart';
import '../../../settings/domain/quick_action_definition.dart';
import '../../../settings/presentation/providers/settings_providers.dart';
import '../../../subscriptions/domain/episode.dart';
import '../../../subscriptions/domain/podcast.dart';
import '../../../subscriptions/presentation/providers/subscriptions_providers.dart';
import '../../../subscriptions/presentation/widgets/episode_list_tile.dart';
import '../providers/downloads_providers.dart';

// Inbox does not expose bookmark (requires active playback).
const _inboxAllowedActions = {
  EpisodeAction.playNow,
  EpisodeAction.playNext,
  EpisodeAction.addToEndOfQueue,
  EpisodeAction.markPlayed,
  EpisodeAction.openShowNotes,
  EpisodeAction.download,
  EpisodeAction.share,
};

class InboxScreen extends ConsumerStatefulWidget {
  const InboxScreen({super.key});

  @override
  ConsumerState<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends ConsumerState<InboxScreen> {
  bool _tipAnnouncementPosted = false;
  Timer? _tipAnnounceTimer;
  Timer? _tipDismissTimer;

  @override
  void dispose() {
    _tipAnnounceTimer?.cancel();
    _tipDismissTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // All episodes across all podcasts with newEpisode status, newest first.
    final allEpisodes = ref.watch(_inboxEpisodesProvider);
    final subs = ref.watch(subscriptionsProvider).asData?.value;
    final podcastTitles = <int, String>{
      if (subs != null)
        for (final p in subs) p.id: p.title,
    };
    final actionOrder =
        ref.watch(episodeActionsProvider).asData?.value ??
        defaultEpisodeActions;
    final autoDownload = ref.watch(autoDownloadInboxProvider).value ?? false;
    final podcastNameFirst = ref.watch(podcastNameFirstProvider).value ?? false;
    final tipSeen = ref.watch(podcastNameTipSeenProvider).value ?? false;
    final auditEnabled = ref.watch(downloadAuditEnabledProvider).value ?? false;

    // Announce the tip once and auto-dismiss so neither sighted nor VoiceOver
    // users have to manually interact with the card.
    if (!tipSeen && !_tipAnnouncementPosted) {
      _tipAnnouncementPosted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _tipAnnounceTimer = Timer(const Duration(milliseconds: 2500), () {
          if (mounted &&
              !(ref.read(podcastNameTipSeenProvider).value ?? false)) {
            SemanticsService.sendAnnouncement(
              View.of(context),
              'Tip: VoiceOver can announce the podcast name before the episode '
              'title in this list. Find this setting in Settings under Inbox.',
              TextDirection.ltr,
            );
          }
        });
        // Auto-dismiss after 5 seconds — enough for a sighted user to read
        // and tap 'Go to Settings', no action needed from VoiceOver users.
        _tipDismissTimer = Timer(const Duration(seconds: 5), () {
          if (mounted) {
            ref.read(podcastNameTipSeenProvider.notifier).set(true);
          }
        });
      });
    }

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        leading: (allEpisodes.asData?.value.isNotEmpty ?? false)
            ? IconButton(
                icon: const Icon(Icons.clear_all),
                tooltip: 'Clear inbox',
                onPressed: () => _confirmClearInbox(context, ref),
              )
            : null,
        title: Semantics(
          header: true,
          enabled: true,
          label: autoDownload
              ? 'Inbox, auto-download on'
              : 'Inbox, auto-download off',
          hint: 'Double-tap to toggle auto-download',
          onTap: () => _toggleAutoDownload(context, ref, !autoDownload),
          customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
            CustomSemanticsAction(
              label: autoDownload
                  ? 'Turn off auto-download'
                  : 'Turn on auto-download',
            ): () =>
                _toggleAutoDownload(context, ref, !autoDownload),
          },
          child: const ExcludeSemantics(child: Text('Inbox')),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh inbox',
            onPressed: () => _refreshInbox(context, ref),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => context.push(AppRoutes.settings),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _refreshInbox(context, ref),
        child: CustomScrollView(
          slivers: [
            if (auditEnabled)
              SliverToBoxAdapter(
                child: _FeedStatusCard(podcasts: subs ?? []),
              ),
            if (!tipSeen)
              SliverToBoxAdapter(
                child: _InboxTipCard(
                  onDismiss: () => unawaited(
                    ref.read(podcastNameTipSeenProvider.notifier).set(true),
                  ),
                  onGoToSettings: () => context.push(AppRoutes.settings),
                ),
              ),
            allEpisodes.when(
              data: (episodes) => episodes.isEmpty
                  ? SliverToBoxAdapter(child: _EmptyInbox())
                  : SliverList.builder(
                      itemCount: episodes.length,
                      itemBuilder: (context, index) {
                        final episode = episodes[index];
                        final actions = buildEpisodeActions(
                          episode: episode,
                          order: actionOrder,
                          context: context,
                          ref: ref,
                          onPlay: () => _playEpisode(context, episode, ref),
                          allowedActions: _inboxAllowedActions,
                        );
                        return _InboxEpisodeTile(
                          episode: episode,
                          podcastTitle: podcastTitles[episode.podcastId],
                          podcastNameFirst: podcastNameFirst,
                          quickActions: actions,
                          onClear: () => unawaited(
                            _clearFromInbox(context, ref, episode),
                          ),
                        );
                      },
                    ),
              loading: () => const SliverToBoxAdapter(
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => SliverToBoxAdapter(
                child: Center(child: Text('Error: $e')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _toggleAutoDownload(BuildContext context, WidgetRef ref, bool val) {
    unawaited(
      ref
          .read(autoDownloadInboxProvider.notifier)
          .set(val)
          .then((_) {
            if (val) {
              unawaited(
                ref.read(downloadManagerProvider).downloadInboxEpisodes(),
              );
            }
            if (context.mounted) {
              SemanticsService.sendAnnouncement(
                View.of(context),
                val ? 'Auto-download enabled' : 'Auto-download disabled',
                TextDirection.ltr,
              );
            }
          })
          .catchError((_) {
            if (context.mounted) {
              SemanticsService.sendAnnouncement(
                View.of(context),
                'Could not update auto-download setting',
                TextDirection.ltr,
              );
            }
          }),
    );
  }

  Future<void> _refreshInbox(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(podcastRepositoryProvider).refreshAllFeeds();
      if (context.mounted) {
        SemanticsService.sendAnnouncement(
          View.of(context),
          'Inbox refreshed',
          TextDirection.ltr,
        );
      }
    } catch (_) {
      if (context.mounted) {
        SemanticsService.sendAnnouncement(
          View.of(context),
          'Could not refresh inbox. Try again.',
          TextDirection.ltr,
        );
      }
    }
  }

  void _playEpisode(BuildContext context, Episode episode, WidgetRef ref) {
    final resumePosition =
        episode.positionSeconds > 0 &&
            episode.durationSeconds != null &&
            episode.positionSeconds < (episode.durationSeconds! * 0.95).round()
        ? episode.positionSeconds
        : 0;
    final podcast = ref.read(podcastProvider(episode.podcastId)).value;
    unawaited(
      ref
          .read(audioHandlerProvider)
          .playEpisode(
            MediaItem(
              id: episode.audioUrl,
              title: podcast?.title ?? episode.title,
              artist: episode.title,
              album: podcast?.title,
              artUri: episode.artworkUrl != null
                  ? Uri.tryParse(episode.artworkUrl!)
                  : null,
              duration: episode.durationSeconds != null
                  ? Duration(seconds: episode.durationSeconds!)
                  : null,
              extras: {
                'episodeId': episode.id,
                'podcastId': episode.podcastId,
                if (podcast?.speedOverride != null)
                  'speedOverride': podcast!.speedOverride!,
                if (podcast?.trimSilenceOverride != null)
                  'trimSilenceOverride': podcast!.trimSilenceOverride!,
                if (episode.downloadPath != null)
                  'downloadPath': episode.downloadPath!,
              },
            ),
            resumePositionSeconds: resumePosition,
          ),
    );
    unawaited(
      ref.read(queueRepositoryProvider).addToQueue(episode.id),
    );
    // Trigger queue auto-download if enabled and episode is not already
    // downloaded or in progress.
    final autoDownloadQueue =
        ref.read(autoDownloadQueueProvider).value ?? false;
    if (autoDownloadQueue &&
        (episode.downloadStatus == DownloadStatus.none ||
            episode.downloadStatus == DownloadStatus.failed)) {
      unawaited(ref.read(downloadManagerProvider).downloadEpisode(episode.id));
    }
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

  Future<void> _confirmClearInbox(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final count = ref.read(_inboxEpisodesProvider).asData?.value.length ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierLabel: 'Dismiss clear inbox dialog',
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear inbox?'),
        content: Text(
          'This will remove all $count episodes from your inbox. Their play status will not change.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Clear inbox'),
          ),
        ],
      ),
    );
    if (!context.mounted) return;
    if (confirmed == true) {
      try {
        await ref.read(podcastRepositoryProvider).clearInbox();
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not clear inbox. Try again.'),
            ),
          );
          SemanticsService.sendAnnouncement(
            View.of(context),
            'Could not clear inbox. Try again.',
            TextDirection.ltr,
          );
        }
      }
    }
  }

  Future<void> _clearFromInbox(
    BuildContext context,
    WidgetRef ref,
    Episode episode,
  ) async {
    final alsoMarkPlayed =
        ref.read(clearFromInboxAlsoMarksPlayedProvider).value ?? false;
    try {
      await ref
          .read(podcastRepositoryProvider)
          .dismissFromInbox(episode.id, alsoMarkPlayed: alsoMarkPlayed);
      if (context.mounted) {
        final message = alsoMarkPlayed
            ? 'Cleared "${episode.title}" from inbox. Marked as played.'
            : 'Cleared "${episode.title}" from inbox.';
        // Defer one frame so the list has updated before VoiceOver reads the
        // announcement — avoids a ghost-focus on the tile as it unmounts.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) {
            SemanticsService.sendAnnouncement(
              View.of(context),
              message,
              TextDirection.ltr,
            );
          }
        });
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not clear episode from inbox. Try again.'),
          ),
        );
        SemanticsService.sendAnnouncement(
          View.of(context),
          'Could not clear episode from inbox. Try again.',
          TextDirection.ltr,
        );
      }
    }
  }
}

// Provider for inbox: all non-dismissed newEpisode-status episodes, newest first.
final _inboxEpisodesProvider = StreamProvider<List<Episode>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.episodes)
        ..where(
          (e) =>
              e.status.equals(EpisodeStatus.newEpisode.name) &
              e.inboxDismissed.equals(false),
        )
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
    required this.quickActions,
    required this.onClear,
    this.podcastTitle,
    this.podcastNameFirst = false,
  });

  final Episode episode;
  final String? podcastTitle;
  final bool podcastNameFirst;
  final List<EpisodeQuickActionItem> quickActions;
  final VoidCallback onClear;

  VoidCallback? get _defaultTap =>
      quickActions.isNotEmpty ? quickActions[0].onInvoke : null;

  void _showActions(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      barrierLabel: 'Dismiss episode actions',
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Semantics(
              header: true,
              label: episode.title,
              child: ExcludeSemantics(
                child: Text(
                  episode.title,
                  style: textTheme.titleMedium,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          ...quickActions.map(
            (action) => ListTile(
              title: Text(action.label),
              onTap: () {
                Navigator.of(sheetContext).pop();
                action.onInvoke();
              },
            ),
          ),
          ListTile(
            title: const Text('Clear from inbox'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              onClear();
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final durationLabel = _semanticDuration(episode);
    final downloadLabel = _downloadStatusLabel(episode.downloadStatus);
    final parts = [
      if (podcastNameFirst && podcastTitle != null) podcastTitle!,
      episode.title,
      if (!podcastNameFirst && podcastTitle != null) podcastTitle!,
      'New episode',
      if (durationLabel != null) durationLabel,
      if (downloadLabel != null) downloadLabel,
    ];
    final label = parts.join(', ');

    final semanticActions = <CustomSemanticsAction, VoidCallback>{
      for (final a in quickActions)
        CustomSemanticsAction(label: a.label): a.onInvoke,
      const CustomSemanticsAction(label: 'Clear from inbox'): onClear,
    };

    return Semantics(
      button: _defaultTap != null,
      onTap: _defaultTap,
      label: label,
      customSemanticsActions: semanticActions,
      child: ExcludeSemantics(
        child: ListTile(
          onTap: _defaultTap,
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
              Wrap(
                spacing: 4,
                runSpacing: 0,
                children: [
                  Chip(
                    label: const Text('New'),
                    visualDensity: VisualDensity.compact,
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.primaryContainer,
                    labelStyle:
                        Theme.of(
                          context,
                        ).textTheme.labelSmall?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onPrimaryContainer,
                        ),
                    padding: EdgeInsets.zero,
                  ),
                  if (episode.downloadStatus == DownloadStatus.downloaded)
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
                      labelStyle:
                          Theme.of(
                            context,
                          ).textTheme.labelSmall?.copyWith(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSecondaryContainer,
                          ),
                      padding: EdgeInsets.zero,
                    )
                  else if (episode.downloadStatus ==
                          DownloadStatus.downloading ||
                      episode.downloadStatus == DownloadStatus.pending)
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
                      labelStyle:
                          Theme.of(
                            context,
                          ).textTheme.labelSmall?.copyWith(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSecondaryContainer,
                          ),
                      padding: EdgeInsets.zero,
                    ),
                ],
              ),
              if (episode.pubDate != null)
                Text(
                  _formatDate(episode.pubDate!),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
          trailing: IconButton(
            icon: const Icon(Icons.more_vert),
            tooltip: 'Episode actions',
            onPressed: () => _showActions(context),
          ),
        ),
      ),
    );
  }

  String? _downloadStatusLabel(DownloadStatus status) => switch (status) {
    DownloadStatus.downloaded => 'downloaded',
    DownloadStatus.downloading || DownloadStatus.pending => 'downloading',
    DownloadStatus.failed => 'download failed',
    DownloadStatus.none => null,
  };

  String _formatDate(DateTime date) {
    final diff = DateTime.now().difference(date);
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays} days ago';
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

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
    if (s > 0 || parts.isEmpty)
      parts.add('$s ${s == 1 ? 'second' : 'seconds'}');
    return parts.join(', ');
  }
}

class _FeedStatusCard extends StatelessWidget {
  const _FeedStatusCard({required this.podcasts});

  final List<Podcast> podcasts;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final labelStyle = textTheme.bodySmall?.copyWith(
      color: colorScheme.onTertiaryContainer,
    );

    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Card(
          color: colorScheme.tertiaryContainer,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  label: 'Feed status, developer info',
                  child: ExcludeSemantics(
                    child: Text(
                      'Feed status',
                      style: textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onTertiaryContainer,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                if (podcasts.isEmpty)
                  Text('No subscriptions', style: labelStyle)
                else
                  ...podcasts.map(
                    (p) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Semantics(
                        label:
                            '${p.title}, last checked ${formatRefreshTimestamp(p.refreshedAt)}',
                        excludeSemantics: true,
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                p.title,
                                style: labelStyle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              formatRefreshTimestamp(p.refreshedAt),
                              style: labelStyle,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InboxTipCard extends StatelessWidget {
  const _InboxTipCard({
    required this.onDismiss,
    required this.onGoToSettings,
  });

  final VoidCallback onDismiss;
  final VoidCallback onGoToSettings;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Card(
        color: colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: ExcludeSemantics(
                  child: Icon(
                    Icons.tips_and_updates_outlined,
                    size: 20,
                    color: colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      label:
                          'Tip: VoiceOver can announce the podcast name '
                          'before the episode title in this list. '
                          'Turn it on in Settings, Inbox.',
                      child: ExcludeSemantics(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'VoiceOver tip',
                              style: textTheme.labelMedium?.copyWith(
                                color: colorScheme.onSecondaryContainer,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'VoiceOver can announce the podcast name before the episode title in this list. Turn it on in Settings › Inbox.',
                              style: textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSecondaryContainer,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: onGoToSettings,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        minimumSize: const Size(0, 44),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        foregroundColor: colorScheme.onSecondaryContainer,
                      ),
                      child: const Text('Go to Settings'),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Dismiss tip',
                color: colorScheme.onSecondaryContainer,
                onPressed: onDismiss,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
