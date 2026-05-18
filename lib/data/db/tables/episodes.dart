import 'package:drift/drift.dart';

import '../enums.dart';
import 'podcasts.dart';

class Episodes extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get podcastId =>
      integer().references(Podcasts, #id, onDelete: KeyAction.cascade)();
  TextColumn get guid => text()();
  TextColumn get title => text()();
  TextColumn get description => text().nullable()();
  TextColumn get audioUrl => text()();
  IntColumn get durationSeconds => integer().nullable()();
  DateTimeColumn get pubDate => dateTime().nullable()();
  TextColumn get artworkUrl => text().nullable()();
  IntColumn get episodeNumber => integer().nullable()();
  IntColumn get seasonNumber => integer().nullable()();
  TextColumn get chapterUrl => text().nullable()();
  TextColumn get transcriptUrl => text().nullable()();
  TextColumn get status =>
      textEnum<EpisodeStatus>().withDefault(const Constant('newEpisode'))();
  TextColumn get downloadStatus =>
      textEnum<DownloadStatus>().withDefault(const Constant('none'))();
  TextColumn get downloadPath => text().nullable()();
  IntColumn get positionSeconds =>
      integer().withDefault(const Constant(0))();
  DateTimeColumn get playedAt => dateTime().nullable()();
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
        {podcastId, guid},
      ];
}
