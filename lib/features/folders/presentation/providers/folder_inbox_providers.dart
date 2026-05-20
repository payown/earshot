import 'package:drift/drift.dart' hide Column;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/core_providers.dart';
import '../../../../data/db/enums.dart';
import '../../../subscriptions/domain/episode.dart';

// Inbox episodes (newEpisode status) for podcasts that belong to a given folder.
final inboxEpisodesByFolderProvider = StreamProvider.family<List<Episode>, int>(
  (ref, folderId) {
    final db = ref.watch(appDatabaseProvider);

    final podcastIdsSubquery = db.selectOnly(db.podcastFolderMemberships)
      ..addColumns([db.podcastFolderMemberships.podcastId])
      ..where(db.podcastFolderMemberships.folderId.equals(folderId));

    final query = db.select(db.episodes)
      ..where(
        (e) =>
            e.status.equals(EpisodeStatus.newEpisode.name) &
            e.podcastId.isInQuery(podcastIdsSubquery),
      )
      ..orderBy([(e) => OrderingTerm.desc(e.pubDate)]);

    return query.watch().map(
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
  },
);
