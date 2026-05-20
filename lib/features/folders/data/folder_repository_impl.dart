import 'package:drift/drift.dart';
import 'package:logging/logging.dart';

import '../../../data/db/app_database.dart';
import '../../../data/db/enums.dart';
import '../../subscriptions/domain/episode.dart';
import '../../subscriptions/domain/podcast.dart';
import '../domain/podcast_folder.dart';
import 'folder_repository.dart';

final _log = Logger('FolderRepository');

class FolderRepositoryImpl implements FolderRepository {
  const FolderRepositoryImpl({required AppDatabase database}) : _db = database;

  final AppDatabase _db;

  @override
  Stream<List<PodcastFolder>> watchFolders() {
    return (_db.select(_db.podcastFolders)..orderBy([
          (f) => OrderingTerm.asc(f.sortOrder),
          (f) => OrderingTerm.asc(f.name),
        ]))
        .watch()
        .map((rows) => rows.map(_folderFromRow).toList());
  }

  @override
  Stream<PodcastFolder?> watchFolder(int folderId) {
    return (_db.select(_db.podcastFolders)..where((f) => f.id.equals(folderId)))
        .watchSingleOrNull()
        .map((row) => row == null ? null : _folderFromRow(row));
  }

  @override
  Stream<List<Podcast>> watchPodcastsInFolder(int folderId) {
    final query =
        _db.select(_db.podcasts).join([
            innerJoin(
              _db.podcastFolderMemberships,
              _db.podcastFolderMemberships.podcastId.equalsExp(_db.podcasts.id),
            ),
          ])
          ..where(_db.podcastFolderMemberships.folderId.equals(folderId))
          ..orderBy([
            OrderingTerm.asc(_db.podcastFolderMemberships.sortOrder),
            OrderingTerm.asc(_db.podcasts.title),
          ]);

    return query.watch().map(
      (rows) =>
          rows.map((r) => _podcastFromRow(r.readTable(_db.podcasts))).toList(),
    );
  }

  @override
  Stream<List<int>> watchFolderIdsForPodcast(int podcastId) {
    return (_db.select(_db.podcastFolderMemberships)
          ..where((m) => m.podcastId.equals(podcastId)))
        .watch()
        .map((rows) => rows.map((r) => r.folderId).toList());
  }

  @override
  Stream<List<Podcast>> watchUnfiledPodcasts() {
    // Podcasts that have no membership in any folder.
    final subquery = _db.selectOnly(_db.podcastFolderMemberships)
      ..addColumns([_db.podcastFolderMemberships.podcastId]);

    final query = _db.select(_db.podcasts)
      ..where((p) => p.id.isNotInQuery(subquery))
      ..orderBy([(p) => OrderingTerm.asc(p.title)]);

    return query.watch().map((rows) => rows.map(_podcastFromRow).toList());
  }

  @override
  Future<PodcastFolder> createFolder(String name) async {
    final maxSortOrder = await _db
        .customSelect(
          'SELECT COALESCE(MAX(sort_order), -1) AS max_order FROM podcast_folders',
        )
        .getSingle()
        .then((row) => row.read<int>('max_order'));

    final id = await _db
        .into(_db.podcastFolders)
        .insert(
          PodcastFoldersCompanion.insert(
            name: name,
            sortOrder: Value(maxSortOrder + 1),
          ),
        );

    final row = await (_db.select(
      _db.podcastFolders,
    )..where((f) => f.id.equals(id))).getSingle();

    _log.info('Created folder: $name (id=$id)');
    return _folderFromRow(row);
  }

  @override
  Future<void> renameFolder(int folderId, String name) async {
    await (_db.update(_db.podcastFolders)..where((f) => f.id.equals(folderId)))
        .write(PodcastFoldersCompanion(name: Value(name)));
    _log.fine('Renamed folder $folderId to $name');
  }

  @override
  Future<void> deleteFolder(int folderId) async {
    await (_db.delete(
      _db.podcastFolders,
    )..where((f) => f.id.equals(folderId))).go();
    _log.info('Deleted folder $folderId');
  }

  @override
  Future<void> setFolderQueueAgeLimit(int folderId, int? days) async {
    await (_db.update(_db.podcastFolders)..where((f) => f.id.equals(folderId)))
        .write(PodcastFoldersCompanion(queueAgeLimitDays: Value(days)));
  }

  @override
  Future<void> addPodcastToFolder(int folderId, int podcastId) async {
    final maxOrder =
        await (_db.select(
          _db.podcastFolderMemberships,
        )..where((m) => m.folderId.equals(folderId))).get().then(
          (rows) => rows.isEmpty
              ? -1
              : rows.map((r) => r.sortOrder).reduce((a, b) => a > b ? a : b),
        );

    await _db
        .into(_db.podcastFolderMemberships)
        .insert(
          PodcastFolderMembershipsCompanion.insert(
            folderId: folderId,
            podcastId: podcastId,
            sortOrder: Value(maxOrder + 1),
          ),
          mode: InsertMode.insertOrIgnore,
        );
  }

  @override
  Future<void> removePodcastFromFolder(int folderId, int podcastId) async {
    await (_db.delete(_db.podcastFolderMemberships)..where(
          (m) => m.folderId.equals(folderId) & m.podcastId.equals(podcastId),
        ))
        .go();
  }

  @override
  Future<void> setMemberships(int podcastId, List<int> folderIds) async {
    await _db.transaction(() async {
      await (_db.delete(
        _db.podcastFolderMemberships,
      )..where((m) => m.podcastId.equals(podcastId))).go();

      for (var i = 0; i < folderIds.length; i++) {
        await _db
            .into(_db.podcastFolderMemberships)
            .insert(
              PodcastFolderMembershipsCompanion.insert(
                folderId: folderIds[i],
                podcastId: podcastId,
                sortOrder: Value(i),
              ),
            );
      }
    });
  }

  @override
  Future<void> reorderFolders(List<int> orderedIds) async {
    await _db.transaction(() async {
      for (var i = 0; i < orderedIds.length; i++) {
        await (_db.update(_db.podcastFolders)
              ..where((f) => f.id.equals(orderedIds[i])))
            .write(PodcastFoldersCompanion(sortOrder: Value(i)));
      }
    });
  }

  @override
  Future<List<Episode>> getLatestUnplayedPerPodcast(int folderId) async {
    // Get all podcast IDs in the folder.
    final memberships = await (_db.select(
      _db.podcastFolderMemberships,
    )..where((m) => m.folderId.equals(folderId))).get();

    if (memberships.isEmpty) return [];

    final podcastIds = memberships.map((m) => m.podcastId).toList();

    // For each podcast, get the single newest unplayed episode.
    final results = <Episode>[];
    for (final podcastId in podcastIds) {
      final rows =
          await (_db.select(_db.episodes)
                ..where(
                  (e) =>
                      e.podcastId.equals(podcastId) &
                      e.status.equals(EpisodeStatus.newEpisode.name),
                )
                ..orderBy([(e) => OrderingTerm.desc(e.pubDate)])
                ..limit(1))
              .get();

      if (rows.isNotEmpty) {
        results.add(_episodeFromRow(rows.first));
      }
    }

    // Sort all results by pubDate descending.
    results.sort((a, b) {
      if (a.pubDate == null && b.pubDate == null) return 0;
      if (a.pubDate == null) return 1;
      if (b.pubDate == null) return -1;
      return b.pubDate!.compareTo(a.pubDate!);
    });

    return results;
  }

  @override
  Future<List<({String rssUrl, String title})>> getFolderSubscriptions(
    int folderId,
  ) async {
    final query =
        _db.select(_db.podcasts).join([
            innerJoin(
              _db.podcastFolderMemberships,
              _db.podcastFolderMemberships.podcastId.equalsExp(_db.podcasts.id),
            ),
          ])
          ..where(_db.podcastFolderMemberships.folderId.equals(folderId))
          ..orderBy([OrderingTerm.asc(_db.podcasts.title)]);

    final rows = await query.get();
    return rows
        .map((r) => _podcastFromRow(r.readTable(_db.podcasts)))
        .map((p) => (rssUrl: p.rssUrl, title: p.title))
        .toList();
  }

  @override
  Future<
    List<({String? folderName, List<({String rssUrl, String title})> podcasts})>
  >
  getAllWithFolderStructure() async {
    final folders =
        await (_db.select(_db.podcastFolders)..orderBy([
              (f) => OrderingTerm.asc(f.sortOrder),
              (f) => OrderingTerm.asc(f.name),
            ]))
            .get();

    final result =
        <
          ({String? folderName, List<({String rssUrl, String title})> podcasts})
        >[];

    for (final folder in folders) {
      final subs = await getFolderSubscriptions(folder.id);
      result.add((folderName: folder.name, podcasts: subs));
    }

    // Unfiled podcasts (no memberships).
    final unfiledRows = await watchUnfiledPodcasts().first;
    if (unfiledRows.isNotEmpty) {
      result.add((
        folderName: null,
        podcasts: unfiledRows
            .map((p) => (rssUrl: p.rssUrl, title: p.title))
            .toList(),
      ));
    }

    return result;
  }

  PodcastFolder _folderFromRow(PodcastFolderRow row) => PodcastFolder(
    id: row.id,
    name: row.name,
    sortOrder: row.sortOrder,
    queueAgeLimitDays: row.queueAgeLimitDays,
    createdAt: row.createdAt,
  );

  Podcast _podcastFromRow(PodcastRow row) => Podcast(
    id: row.id,
    rssUrl: row.rssUrl,
    title: row.title,
    author: row.author,
    description: row.description,
    artworkUrl: row.artworkUrl,
    websiteUrl: row.websiteUrl,
    language: row.language,
    category: row.category,
    autoQueue: row.autoQueue,
    notificationEnabled: row.notificationEnabled,
    speedOverride: row.speedOverride,
    queueAgeLimitDays: row.queueAgeLimitDays,
    createdAt: row.createdAt,
    refreshedAt: row.refreshedAt,
  );

  Episode _episodeFromRow(EpisodeRow row) => Episode(
    id: row.id,
    podcastId: row.podcastId,
    guid: row.guid,
    title: row.title,
    description: row.description,
    audioUrl: row.audioUrl,
    durationSeconds: row.durationSeconds,
    pubDate: row.pubDate,
    artworkUrl: row.artworkUrl,
    episodeNumber: row.episodeNumber,
    seasonNumber: row.seasonNumber,
    chapterUrl: row.chapterUrl,
    transcriptUrl: row.transcriptUrl,
    status: row.status,
    downloadStatus: row.downloadStatus,
    downloadPath: row.downloadPath,
    positionSeconds: row.positionSeconds,
    playedAt: row.playedAt,
    createdAt: row.createdAt,
  );
}
