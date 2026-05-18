import 'package:drift/drift.dart';

import 'episodes.dart';
import 'podcasts.dart';

@DataClassName('ListeningSessionRow')
class ListeningSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get episodeId =>
      integer().references(Episodes, #id, onDelete: KeyAction.cascade)();
  IntColumn get podcastId =>
      integer().references(Podcasts, #id, onDelete: KeyAction.cascade)();
  IntColumn get durationSeconds => integer()();
  RealColumn get speed => real().withDefault(const Constant(1.0))();
  DateTimeColumn get date => dateTime().withDefault(currentDateAndTime)();
}
