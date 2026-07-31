import 'package:drift/drift.dart';

import 'episodes.dart';

@DataClassName('BookmarkRow')
class Bookmarks extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get episodeId =>
      integer().references(Episodes, #id, onDelete: KeyAction.cascade)();
  IntColumn get positionSeconds => integer()();
  TextColumn get note => text().withDefault(const Constant(''))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}
