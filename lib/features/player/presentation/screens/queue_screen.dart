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
import '../../domain/queue_group.dart';
import '../providers/player_providers.dart';

void _toggleQueueAutoDownload(BuildContext context, WidgetRef ref, bool val) {
  unawaited(
    ref
        .read(autoDownloadQueueProvider.notifier)
        .set(val)
        .then((_) {
          if (val) {
            unawaited(
              ref.read(downloadManagerProvider).downloadQueueEpisodes(),
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
  final podcast = ref.read(podcastProvider(episode.podcastId)).value;
  final resumePosition =
      episode.positionSeconds > 0 &&
          episode.durationSeconds != null &&
          episode.positionSeconds < (episode.durationSeconds! * 0.95).round()
      ? episode.positionSeconds
      : 0;
  handler.playEpisode(
    MediaItem(
      id: episode.audioUrl,
      title: podcast?.title ?? episode.title,
      artist: episode.title,
      album: podcast?.title,
      artUri: episode.artworkUrl != null
          ? Uri.parse(episode.artworkUrl!)
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
        if (episode.downloadPath != null) 'downloadPath': episode.downloadPath!,
      },
    ),
    resumePositionSeconds: resumePosition,
  );
}

Future<void> _shuffleGroup(WidgetRef ref, List<Episode> episodes) async {
  final shuffled = [...episodes]..shuffle();
  await ref
      .read(queueRepositoryProvider)
      .sortGroup(shuffled.map((e) => e.id).toList());
}

Future<void> _playNewestFirst(WidgetRef ref, List<Episode> episodes) async {
  final sorted = [...episodes]
    ..sort((a, b) {
      final aDate = a.pubDate ?? DateTime(0);
      final bDate = b.pubDate ?? DateTime(0);
      return bDate.compareTo(aDate);
    });
  await ref
      .read(queueRepositoryProvider)
      .sortGroup(sorted.map((e) => e.id).toList());
}

Future<void> _playOldestFirst(WidgetRef ref, List<Episode> episodes) async {
  final sorted = [...episodes]
    ..sort((a, b) {
      final aDate = a.pubDate ?? DateTime(0);
      final bDate = b.pubDate ?? DateTime(0);
      return aDate.compareTo(bDate);
    });
  await ref
      .read(queueRepositoryProvider)
      .sortGroup(sorted.map((e) => e.id).toList());
}

class QueueScreen extends ConsumerStatefulWidget {
  const QueueScreen({super.key});

  @override
  ConsumerState<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends ConsumerState<QueueScreen> {
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
    final queue = ref.watch(queueProvider);
    final groupingEnabled =
        ref.watch(groupQueueEpisodesProvider).value ?? false;
    final autoDownload = ref.watch(autoDownloadQueueProvider).value ?? false;
    final currentEpisodeId =
        ref.watch(mediaItemProvider).value?.extras?['episodeId'] as int?;
    final tipSeen = ref.watch(gaplessTipSeenProvider).value ?? false;

    // Announce the tip once and auto-dismiss so VoiceOver users hear it
    // without having to find or dismiss the card.
    if (!tipSeen && !_tipAnnouncementPosted) {
      _tipAnnouncementPosted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _tipAnnounceTimer = Timer(const Duration(milliseconds: 2500), () {
          if (mounted && !(ref.read(gaplessTipSeenProvider).value ?? false)) {
            SemanticsService.sendAnnouncement(
              View.of(context),
              'Tip: Earshot supports gapless playback between episodes. '
              'Find this setting in Settings under Queue.',
              TextDirection.ltr,
            );
          }
        });
        _tipDismissTimer = Timer(const Duration(seconds: 5), () {
          if (mounted) {
            ref.read(gaplessTipSeenProvider.notifier).set(true);
          }
        });
      });
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(
            groupingEnabled ? Icons.dynamic_feed : Icons.view_list,
          ),
          tooltip: groupingEnabled
              ? 'Group by podcast: on'
              : 'Group by podcast: off',
          onPressed: () async {
            final view = View.of(context);
            final newValue = !groupingEnabled;
            await ref.read(groupQueueEpisodesProvider.notifier).set(newValue);
            SemanticsService.sendAnnouncement(
              view,
              newValue ? 'Queue grouped by podcast' : 'Queue ungrouped',
              TextDirection.ltr,
            );
          },
        ),
        title: Semantics(
          header: true,
          button: true,
          enabled: true,
          label: autoDownload
              ? 'Queue, auto-download on'
              : 'Queue, auto-download off',
          hint: 'Double-tap to toggle auto-download',
          onTap: () => _toggleQueueAutoDownload(context, ref, !autoDownload),
          customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
            CustomSemanticsAction(
              label: autoDownload
                  ? 'Turn off auto-download'
                  : 'Turn on auto-download',
            ): () =>
                _toggleQueueAutoDownload(context, ref, !autoDownload),
          },
          child: const ExcludeSemantics(child: Text('Queue')),
        ),
        centerTitle: true,
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
          if (!tipSeen)
            SliverToBoxAdapter(
              child: _QueueTipCard(
                onDismiss: () => unawaited(
                  ref.read(gaplessTipSeenProvider.notifier).set(true),
                ),
                onGoToSettings: () => context.push(AppRoutes.settings),
              ),
            ),
          if (groupingEnabled)
            _buildGroupedBody(context, ref, currentEpisodeId)
          else
            _buildFlatBody(context, ref, queue, currentEpisodeId),
        ],
      ),
    );
  }

  Widget _buildFlatBody(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<Episode>> queue,
    int? currentEpisodeId,
  ) {
    final subs = ref.watch(subscriptionsProvider).asData?.value;
    final podcastTitles = <int, String>{
      if (subs != null)
        for (final p in subs) p.id: p.title,
    };

    return queue.when(
      data: (episodes) {
        if (episodes.isEmpty) {
          return SliverToBoxAdapter(child: _emptyState(context));
        }

        // Pin the now-playing episode to the top of the display list.
        Episode? nowPlaying;
        if (currentEpisodeId != null) {
          for (final ep in episodes) {
            if (ep.id == currentEpisodeId) {
              nowPlaying = ep;
              break;
            }
          }
        }

        final displayEpisodes = [
          if (nowPlaying != null) nowPlaying,
          for (final ep in episodes)
            if (ep.id != currentEpisodeId) ep,
        ];
        final total = episodes.length;

        return SliverList.builder(
          itemCount: displayEpisodes.length,
          itemBuilder: (context, displayIndex) {
            final episode = displayEpisodes[displayIndex];
            final isNowPlaying =
                nowPlaying != null && episode.id == currentEpisodeId;
            final queueIndex = episodes.indexOf(episode);
            final position = queueIndex + 1;
            final isFirst = queueIndex == 0;
            final isLast = queueIndex == total - 1;

            final durationLabel = _semanticDuration(episode);
            final downloadLabel = _downloadStatusLabel(episode.downloadStatus);
            final podcastTitle = podcastTitles[episode.podcastId];

            final labelParts = isNowPlaying
                ? [
                    'Now playing',
                    episode.title,
                    if (podcastTitle != null) podcastTitle,
                    if (durationLabel != null) durationLabel,
                    if (downloadLabel != null) downloadLabel,
                  ]
                : [
                    episode.title,
                    if (podcastTitle != null) podcastTitle,
                    'In queue, position $position of $total',
                    if (durationLabel != null) durationLabel,
                    if (downloadLabel != null) downloadLabel,
                  ];

            return _buildEpisodeRow(
              context: context,
              ref: ref,
              episode: episode,
              semanticLabel: labelParts.join(', '),
              isFirst: isFirst,
              isLast: isLast,
              total: total,
              position: position,
              isNowPlaying: isNowPlaying,
            );
          },
        );
      },
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
    );
  }

  Widget _buildGroupedBody(
    BuildContext context,
    WidgetRef ref,
    int? currentEpisodeId,
  ) {
    final grouped = ref.watch(groupedQueueProvider);

    return grouped.when(
      data: (groups) {
        if (groups.isEmpty) {
          return SliverToBoxAdapter(child: _emptyState(context));
        }

        // Locate the now-playing episode across all groups.
        Episode? nowPlayingEp;
        String nowPlayingPodcastName = '';
        if (currentEpisodeId != null) {
          outer:
          for (final group in groups) {
            for (final ep in group.episodes) {
              if (ep.id == currentEpisodeId) {
                nowPlayingEp = ep;
                nowPlayingPodcastName = group.podcastName;
                break outer;
              }
            }
          }
        }

        // Remove the now-playing episode from its group; drop the group if
        // it becomes empty so sighted users don't see an orphaned header.
        final adjustedGroups = nowPlayingEp != null
            ? groups
                  .map(
                    (g) => QueueGroup(
                      podcastId: g.podcastId,
                      podcastName: g.podcastName,
                      episodes: g.episodes
                          .where((e) => e.id != nowPlayingEp!.id)
                          .toList(),
                    ),
                  )
                  .where((g) => g.episodes.isNotEmpty)
                  .toList()
            : groups;

        // Non-lazy list so all Semantics(header: true) nodes are in the tree
        // immediately, ensuring the VoiceOver headings rotor is populated on
        // first focus without requiring scroll.
        final items = <Widget>[];

        // Pin now-playing to the top, above all group headers.
        if (nowPlayingEp != null) {
          final allEps = groups.expand((g) => g.episodes).toList();
          final queueIndex = allEps.indexWhere((e) => e.id == nowPlayingEp!.id);
          final total = allEps.length;
          final durationLabel = _semanticDuration(nowPlayingEp);
          final downloadLabel = _downloadStatusLabel(
            nowPlayingEp.downloadStatus,
          );
          final labelParts = [
            'Now playing',
            nowPlayingEp.title,
            nowPlayingPodcastName,
            if (durationLabel != null) durationLabel,
            if (downloadLabel != null) downloadLabel,
          ];
          items.add(
            _buildEpisodeRow(
              context: context,
              ref: ref,
              episode: nowPlayingEp,
              semanticLabel: labelParts.join(', '),
              isFirst: queueIndex <= 0,
              isLast: queueIndex == total - 1,
              total: total,
              position: queueIndex + 1,
              isNowPlaying: true,
            ),
          );
        }

        final collapsed = ref.watch(collapsedQueueGroupsProvider);

        for (final group in adjustedGroups) {
          final isCollapsed = collapsed.contains(group.podcastId);
          items.add(_buildGroupHeader(context, ref, group, isCollapsed));
          // When collapsed, episodes are not rendered at all so neither
          // sighted users nor VoiceOver encounter them. The headings rotor
          // still finds the group header.
          if (isCollapsed) continue;
          for (var i = 0; i < group.episodes.length; i++) {
            final ep = group.episodes[i];
            final posInGroup = i + 1;
            final durationLabel = _semanticDuration(ep);
            final downloadLabel = _downloadStatusLabel(ep.downloadStatus);
            final labelParts = [
              ep.title,
              group.podcastName,
              'episode $posInGroup of ${group.episodes.length} in this group',
              if (durationLabel != null) durationLabel,
              if (downloadLabel != null) downloadLabel,
            ];
            items.add(
              _buildEpisodeRow(
                context: context,
                ref: ref,
                episode: ep,
                semanticLabel: labelParts.join(', '),
                isFirst: posInGroup == 1,
                isLast: posInGroup == group.episodes.length,
                total: group.episodes.length,
                position: posInGroup,
              ),
            );
          }
        }

        return SliverList(
          delegate: SliverChildListDelegate(items),
        );
      },
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
    );
  }

  Widget _buildGroupHeader(
    BuildContext context,
    WidgetRef ref,
    QueueGroup group,
    bool isCollapsed,
  ) {
    Future<void> playFirst() async {
      if (group.episodes.isEmpty) return;
      final view = View.of(context);
      // Bring all group episodes to the front of the flat queue (in the
      // user's current sorted order) before starting playback. Without this,
      // auto-advance uses flat-queue order and may jump to a different podcast
      // when the first episode completes.
      await ref
          .read(queueRepositoryProvider)
          .bringGroupToFront(group.episodes.map((e) => e.id).toList());
      ref
          .read<ActiveGroupNotifier>(activeGroupPodcastIdProvider.notifier)
          .set(group.podcastId);
      _playEpisode(ref, group.episodes.first);
      SemanticsService.sendAnnouncement(
        view,
        'Playing ${group.podcastName}',
        TextDirection.ltr,
      );
    }

    void toggleCollapsed() {
      final view = View.of(context);
      final willCollapse = !isCollapsed;
      ref.read(collapsedQueueGroupsProvider.notifier).toggle(group.podcastId);
      SemanticsService.sendAnnouncement(
        view,
        willCollapse
            ? '${group.podcastName} collapsed'
            : '${group.podcastName} expanded',
        TextDirection.ltr,
      );
    }

    Future<void> shuffle() async {
      final view = View.of(context);
      await _shuffleGroup(ref, group.episodes);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        SemanticsService.sendAnnouncement(
          view,
          '${group.podcastName} shuffled',
          TextDirection.ltr,
        );
      });
    }

    Future<void> sortNewest() async {
      final view = View.of(context);
      await _playNewestFirst(ref, group.episodes);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        SemanticsService.sendAnnouncement(
          view,
          '${group.podcastName} sorted newest first',
          TextDirection.ltr,
        );
      });
    }

    Future<void> sortOldest() async {
      final view = View.of(context);
      await _playOldestFirst(ref, group.episodes);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        SemanticsService.sendAnnouncement(
          view,
          '${group.podcastName} sorted oldest first',
          TextDirection.ltr,
        );
      });
    }

    final episodeCount = group.episodes.length;
    final episodeCountLabel =
        '$episodeCount ${episodeCount == 1 ? 'episode' : 'episodes'}';
    final stateLabel = isCollapsed ? 'collapsed' : 'expanded';

    // Single Semantics node owns the header. No nested InkWell — a second
    // tap node next to the outer Semantics creates an unlabeled VoiceOver
    // stop AND can swallow customSemanticsActions. GestureDetector inside
    // ExcludeSemantics gives sighted users a tap surface without adding a
    // sibling semantics node.
    //
    // Default action (onTap / "Activate" / double-tap) toggles expand/collapse.
    // Custom actions (rotor flick) are listed Play first so a single flick
    // down lands on Play group.
    return Semantics(
      container: true,
      header: true,
      button: true,
      enabled: true,
      label: '${group.podcastName}, $episodeCountLabel, $stateLabel',
      hint:
          'Double tap to ${isCollapsed ? 'expand' : 'collapse'}. '
          'Use the actions rotor for play, shuffle, or sort.',
      onTap: toggleCollapsed,
      customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
        const CustomSemanticsAction(label: 'Play group'): () {
          unawaited(playFirst());
        },
        const CustomSemanticsAction(label: 'Shuffle group'): () {
          unawaited(shuffle());
        },
        const CustomSemanticsAction(label: 'Sort newest first'): () {
          unawaited(sortNewest());
        },
        const CustomSemanticsAction(label: 'Sort oldest first'): () {
          unawaited(sortOldest());
        },
      },
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: toggleCollapsed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                const Padding(
                  padding: EdgeInsets.only(right: 16),
                  child: Icon(Icons.podcasts),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        group.podcastName,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        episodeCountLabel,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Icon(
                  isCollapsed ? Icons.expand_more : Icons.expand_less,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEpisodeRow({
    required BuildContext context,
    required WidgetRef ref,
    required Episode episode,
    required String semanticLabel,
    required bool isFirst,
    required bool isLast,
    required int total,
    required int position,
    bool isNowPlaying = false,
  }) {
    final downloadAction = _buildDownloadAction(episode, ref, context);

    // Named closures shared by the actions rotor and the bottom sheet.
    void play() => _playEpisode(ref, episode);
    void moveToTop() => unawaited(
      ref.read(queueRepositoryProvider).moveToTop(episode.id).then((_) {
        if (context.mounted) {
          SemanticsService.sendAnnouncement(
            View.of(context),
            'Moved to top, now position 1 of $total',
            TextDirection.ltr,
          );
        }
      }),
    );
    void moveToBottom() => unawaited(
      ref.read(queueRepositoryProvider).moveToBottom(episode.id).then((_) {
        if (context.mounted) {
          SemanticsService.sendAnnouncement(
            View.of(context),
            'Moved to bottom, now position $total of $total',
            TextDirection.ltr,
          );
        }
      }),
    );
    void moveUp() => unawaited(
      ref.read(queueRepositoryProvider).moveUp(episode.id).then((_) {
        if (context.mounted) {
          SemanticsService.sendAnnouncement(
            View.of(context),
            'Moved up, now position ${position - 1} of $total',
            TextDirection.ltr,
          );
        }
      }),
    );
    void moveDown() => unawaited(
      ref.read(queueRepositoryProvider).moveDown(episode.id).then((_) {
        if (context.mounted) {
          SemanticsService.sendAnnouncement(
            View.of(context),
            'Moved down, now position ${position + 1} of $total',
            TextDirection.ltr,
          );
        }
      }),
    );
    void removeFromQueue() => unawaited(
      ref.read(queueRepositoryProvider).cancelFromQueue(episode.id).then((_) {
        if (context.mounted) {
          SemanticsService.sendAnnouncement(
            View.of(context),
            '${episode.title} removed from queue',
            TextDirection.ltr,
          );
        }
      }),
    );

    void showActions() {
      final textTheme = Theme.of(context).textTheme;
      final colorScheme = Theme.of(context).colorScheme;
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
            ListTile(
              title: const Text('Play'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                play();
              },
            ),
            ListTile(
              title: const Text('Move to top'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                moveToTop();
              },
            ),
            if (!isFirst)
              ListTile(
                title: const Text('Move up'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  moveUp();
                },
              ),
            if (!isLast)
              ListTile(
                title: const Text('Move down'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  moveDown();
                },
              ),
            ListTile(
              title: const Text('Move to bottom'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                moveToBottom();
              },
            ),
            if (downloadAction != null)
              ListTile(
                title: Text(downloadAction.label),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  downloadAction.onInvoke();
                },
              ),
            ListTile(
              title: Text(
                'Remove from queue',
                style: TextStyle(color: colorScheme.error),
              ),
              onTap: () {
                Navigator.of(sheetContext).pop();
                removeFromQueue();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    }

    return Semantics(
      key: ValueKey(episode.id),
      container: true,
      button: true,
      label: semanticLabel,
      hint: 'Double tap to play. Use the actions rotor for more options.',
      onTap: play,
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Play'): play,
        const CustomSemanticsAction(label: 'Move to top'): moveToTop,
        const CustomSemanticsAction(label: 'Move to bottom'): moveToBottom,
        if (!isFirst) const CustomSemanticsAction(label: 'Move up'): moveUp,
        if (!isLast) const CustomSemanticsAction(label: 'Move down'): moveDown,
        const CustomSemanticsAction(label: 'Remove from queue'):
            removeFromQueue,
        if (downloadAction != null)
          CustomSemanticsAction(label: downloadAction.label):
              downloadAction.onInvoke,
      },
      child: ExcludeSemantics(
        child: ListTile(
          leading: isNowPlaying
              ? Icon(
                  Icons.graphic_eq,
                  color: Theme.of(context).colorScheme.primary,
                )
              : Text(
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
                  label: Text(isNowPlaying ? 'Now Playing' : 'In queue'),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: isNowPlaying
                      ? Theme.of(context).colorScheme.primaryContainer
                      : Theme.of(context).colorScheme.secondaryContainer,
                  labelStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: isNowPlaying
                        ? Theme.of(context).colorScheme.onPrimaryContainer
                        : Theme.of(context).colorScheme.onSecondaryContainer,
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
                    labelStyle: Theme.of(context).textTheme.labelSmall
                        ?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSecondaryContainer,
                        ),
                    padding: EdgeInsets.zero,
                  )
                else if (episode.downloadStatus == DownloadStatus.downloading ||
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
                    labelStyle: Theme.of(context).textTheme.labelSmall
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
          trailing: IconButton(
            icon: const Icon(Icons.more_vert),
            tooltip: 'Episode actions',
            onPressed: showActions,
          ),
        ),
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: Icon(
                Icons.queue_music,
                size: 64,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
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

  _DownloadActionItem? _buildDownloadAction(
    Episode episode,
    WidgetRef ref,
    BuildContext context,
  ) {
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
                  onComplete: (msg) {
                    if (context.mounted) {
                      SemanticsService.sendAnnouncement(
                        View.of(context),
                        msg,
                        TextDirection.ltr,
                      );
                    }
                  },
                );
            if (!context.mounted) return;
            SemanticsService.sendAnnouncement(
              View.of(context),
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

class _QueueTipCard extends StatelessWidget {
  const _QueueTipCard({
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
                          'Tip: Earshot supports gapless playback so '
                          'episodes flow seamlessly back to back. '
                          'Turn it on or off in Settings, Queue.',
                      child: ExcludeSemantics(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Playback tip',
                              style: textTheme.labelMedium?.copyWith(
                                color: colorScheme.onSecondaryContainer,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Earshot supports gapless playback so episodes flow seamlessly back to back. Turn it on or off in Settings › Queue.',
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
