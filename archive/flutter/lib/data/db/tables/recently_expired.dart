import 'package:drift/drift.dart';

import 'episodes.dart';

@DataClassName('RecentlyExpiredRow')
class RecentlyExpired extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get episodeId =>
      integer().references(Episodes, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get expiredAt => dateTime().withDefault(currentDateAndTime)();

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {episodeId},
  ];
}
