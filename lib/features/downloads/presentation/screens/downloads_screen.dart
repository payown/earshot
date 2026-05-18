import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/core_providers.dart';
import '../../../../data/db/app_database.dart';
import '../../../../data/db/enums.dart';
import '../../../subscriptions/domain/episode.dart';
import '../providers/downloads_providers.dart';

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloads = ref.watch(_downloadedEpisodesProvider);
    final recentlyExpired = ref.watch(recentlyExpiredProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: CustomScrollView(
        slivers: [
          downloads.when(
            data: (episodes) => episodes.isEmpty
                ? const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: Text('No downloaded episodes.')),
                    ),
                  )
                : SliverList.builder(
                    itemCount: episodes.length,
                    itemBuilder: (context, index) => _DownloadTile(
                      episode: episodes[index],
                      onDelete: () => ref
                          .read(downloadManagerProvider)
                          .deleteDownload(episodes[index].id),
                    ),
                  ),
            loading: () =>
                const SliverToBoxAdapter(child: LinearProgressIndicator()),
            error: (e, _) => SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Error: $e'),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Semantics(
                header: true,
                child: Text(
                  'Recently Expired',
                  style: Theme.of(context).textTheme.titleMedium,
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

final _downloadedEpisodesProvider = StreamProvider<List<Episode>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.episodes)
        ..where((e) => e.downloadStatus.equals(DownloadStatus.downloaded.name))
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
  const _DownloadTile({required this.episode, required this.onDelete});

  final Episode episode;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '${episode.title}, downloaded',
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Delete download'): onDelete,
      },
      child: ListTile(
        leading: ExcludeSemantics(
          child: Icon(
            Icons.download_done,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        title: ExcludeSemantics(
          child: Text(
            episode.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        trailing: Semantics(
          button: true,
          label: 'Delete download',
          child: ExcludeSemantics(
            child: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: onDelete,
              tooltip: 'Delete download',
            ),
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
      label: 'Expired episode, episode ID ${row.episodeId}',
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Restore to queue'): onRestore,
      },
      child: ListTile(
        leading: ExcludeSemantics(
          child: Icon(
            Icons.history,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        title: ExcludeSemantics(
          child: Text(
            'Episode ${row.episodeId}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        subtitle: ExcludeSemantics(
          child: Text(
            'Expired ${_daysAgo(row.expiredAt)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        trailing: Semantics(
          button: true,
          label: 'Restore to queue',
          child: ExcludeSemantics(
            child: TextButton(
              onPressed: onRestore,
              child: const Text('Restore'),
            ),
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
