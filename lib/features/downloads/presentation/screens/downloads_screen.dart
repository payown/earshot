import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/episode_action_builder.dart';
import '../../../../core/episode_playback.dart';
import '../../../../core/presentation/widgets/episode_actions_sheet.dart';
import '../../../../core/providers/core_providers.dart';
import '../../../../core/router/app_router.dart';
import '../../../../data/db/app_database.dart';
import '../../../../data/db/enums.dart';
import '../../../settings/domain/quick_action_definition.dart';
import '../../../settings/presentation/providers/settings_providers.dart';
import '../../../subscriptions/domain/episode.dart';
import '../../../subscriptions/presentation/providers/subscriptions_providers.dart';
import '../providers/downloads_providers.dart';

// Bookmark excluded — requires active playback.
const _downloadsAllowedActions = {
  EpisodeAction.playNow,
  EpisodeAction.playNext,
  EpisodeAction.addToEndOfQueue,
  EpisodeAction.markPlayed,
  EpisodeAction.openShowNotes,
  EpisodeAction.download,
  EpisodeAction.share,
  EpisodeAction.exportAudio,
};

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inboxDownloads = ref.watch(_inboxDownloadsProvider);
    final queueDownloads = ref.watch(_queueDownloadsProvider);
    final libraryDownloads = ref.watch(_libraryDownloadsProvider);
    final recentlyExpired = ref.watch(recentlyExpiredProvider);

    final actionOrder =
        ref.watch(episodeActionsProvider).asData?.value ??
        defaultEpisodeActions;
    final subs = ref.watch(subscriptionsProvider).asData?.value;
    final podcastTitles = <int, String>{
      if (subs != null)
        for (final p in subs) p.id: p.title,
    };

    final anyLoading =
        inboxDownloads.isLoading ||
        queueDownloads.isLoading ||
        libraryDownloads.isLoading;
    final allEmpty =
        !anyLoading &&
        (inboxDownloads.value?.isEmpty ?? true) &&
        (queueDownloads.value?.isEmpty ?? true) &&
        (libraryDownloads.value?.isEmpty ?? true);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloads'),
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
          if (anyLoading)
            const SliverToBoxAdapter(child: LinearProgressIndicator()),
          if (allEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('No downloaded episodes.')),
              ),
            ),
          ..._buildSection(
            context: context,
            ref: ref,
            label: 'Inbox',
            data: inboxDownloads,
            actionOrder: actionOrder,
            podcastTitles: podcastTitles,
          ),
          ..._buildSection(
            context: context,
            ref: ref,
            label: 'Queue',
            data: queueDownloads,
            actionOrder: actionOrder,
            podcastTitles: podcastTitles,
          ),
          ..._buildSection(
            context: context,
            ref: ref,
            label: 'Library',
            data: libraryDownloads,
            actionOrder: actionOrder,
            podcastTitles: podcastTitles,
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Semantics(
                header: true,
                label: 'Recently Expired',
                child: ExcludeSemantics(
                  child: Text(
                    'Recently Expired',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
            ),
          ),
          recentlyExpired.when(
            data: (rows) => rows.isEmpty
                ? const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Text('No recently expired episodes.'),
                    ),
                  )
                : SliverList.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, index) => _RecentlyExpiredTile(
                      row: rows[index],
                      onRestore: () => ref
                          .read(queueExpirationServiceProvider)
                          .restoreFromExpired(rows[index].episodeId),
                    ),
                  ),
            loading: () => const SliverToBoxAdapter(child: SizedBox.shrink()),
            error: (e, _) => const SliverToBoxAdapter(child: SizedBox.shrink()),
          ),
        ],
      ),
    );
  }
}

List<Widget> _buildSection({
  required BuildContext context,
  required WidgetRef ref,
  required String label,
  required AsyncValue<List<Episode>> data,
  required List<EpisodeAction> actionOrder,
  required Map<int, String> podcastTitles,
}) {
  final episodes = data.value;
  if (episodes == null || episodes.isEmpty) return const [];
  return [
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Semantics(
          header: true,
          label: label,
          child: ExcludeSemantics(
            child: Text(
              label,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ),
      ),
    ),
    SliverList.builder(
      itemCount: episodes.length,
      itemBuilder: (context, index) {
        final episode = episodes[index];
        final actions = buildEpisodeActions(
          episode: episode,
          order: actionOrder,
          context: context,
          ref: ref,
          onPlay: () =>
              playEpisodeNow(context: context, ref: ref, episode: episode),
          allowedActions: _downloadsAllowedActions,
        );
        return _DownloadTile(
          episode: episode,
          sectionLabel: label,
          podcastTitle: podcastTitles[episode.podcastId],
          quickActions: actions,
          onDelete: () => ref
              .read(downloadManagerProvider)
              .deleteDownload(episodes[index].id),
        );
      },
    ),
  ];
}

// Three stream providers split by where the downloaded episode lives.
// Inbox: new, not dismissed, downloaded.
// Queue: in queue, downloaded.
// Library: downloaded, played (or any other status).

final _inboxDownloadsProvider = StreamProvider<List<Episode>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.episodes)
        ..where(
          (e) =>
              e.downloadStatus.equals(DownloadStatus.downloaded.name) &
              e.status.equals(EpisodeStatus.newEpisode.name) &
              e.inboxDismissed.equals(false),
        )
        ..orderBy([(e) => OrderingTerm.desc(e.pubDate)]))
      .watch()
      .map((rows) => rows.map(_toEpisode).toList());
});

final _queueDownloadsProvider = StreamProvider<List<Episode>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.episodes)
        ..where(
          (e) =>
              e.downloadStatus.equals(DownloadStatus.downloaded.name) &
              e.status.equals(EpisodeStatus.inQueue.name),
        )
        ..orderBy([(e) => OrderingTerm.desc(e.pubDate)]))
      .watch()
      .map((rows) => rows.map(_toEpisode).toList());
});

final _libraryDownloadsProvider = StreamProvider<List<Episode>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.episodes)
        ..where(
          (e) =>
              e.downloadStatus.equals(DownloadStatus.downloaded.name) &
              e.status.isNotIn([
                EpisodeStatus.newEpisode.name,
                EpisodeStatus.inQueue.name,
              ]),
        )
        ..orderBy([(e) => OrderingTerm.desc(e.pubDate)]))
      .watch()
      .map((rows) => rows.map(_toEpisode).toList());
});

Episode _toEpisode(EpisodeRow r) => Episode(
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
);

class _DownloadTile extends StatelessWidget {
  const _DownloadTile({
    required this.episode,
    required this.sectionLabel,
    required this.onDelete,
    this.podcastTitle,
    this.quickActions = const [],
  });

  final Episode episode;
  final String sectionLabel;
  final String? podcastTitle;
  final List<EpisodeQuickActionItem> quickActions;
  final VoidCallback onDelete;

  VoidCallback? get _defaultTap =>
      quickActions.isNotEmpty ? quickActions[0].onInvoke : null;

  void _showActions(BuildContext context) {
    showEpisodeActionsSheet(
      context,
      episodeTitle: episode.title,
      actions: [
        ...quickActions,
        EpisodeQuickActionItem(
          label: 'Delete download',
          onInvoke: onDelete,
          destructive: true,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final labelParts = [
      episode.title,
      if (podcastTitle != null) podcastTitle!,
      '$sectionLabel download',
    ];

    return Semantics(
      button: _defaultTap != null,
      onTap: _defaultTap,
      label: labelParts.join(', '),
      customSemanticsActions: {
        for (final a in quickActions)
          CustomSemanticsAction(label: a.label): a.onInvoke,
        const CustomSemanticsAction(label: 'Delete download'): onDelete,
      },
      child: ExcludeSemantics(
        child: ListTile(
          onTap: _defaultTap,
          leading: Icon(
            Icons.download_done,
            color: Theme.of(context).colorScheme.primary,
          ),
          title: Text(
            episode.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          trailing: IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () => _showActions(context),
            tooltip: 'Episode actions',
          ),
        ),
      ),
    );
  }
}

class _RecentlyExpiredTile extends StatelessWidget {
  const _RecentlyExpiredTile({required this.row, required this.onRestore});

  final RecentlyExpiredRow row;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'Expired episode, episode ID ${row.episodeId}',
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Restore to queue'): onRestore,
      },
      child: ExcludeSemantics(
        child: ListTile(
          leading: Icon(
            Icons.history,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          title: Text(
            'Episode ${row.episodeId}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          subtitle: Text(
            'Expired ${_daysAgo(row.expiredAt)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          trailing: TextButton(
            onPressed: onRestore,
            child: const Text('Restore'),
          ),
        ),
      ),
    );
  }

  String _daysAgo(DateTime date) {
    final diff = DateTime.now().difference(date).inDays;
    if (diff == 0) return 'today';
    if (diff == 1) return 'yesterday';
    return '$diff days ago';
  }
}
