import 'package:drift/drift.dart';

@DataClassName('PodcastRow')
class Podcasts extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get rssUrl => text().unique()();
  TextColumn get title => text()();
  TextColumn get author => text().nullable()();
  TextColumn get description => text().nullable()();
  TextColumn get artworkUrl => text().nullable()();
  TextColumn get websiteUrl => text().nullable()();
  TextColumn get language => text().nullable()();
  TextColumn get category => text().nullable()();
  BoolColumn get autoQueue => boolean().withDefault(const Constant(false))();
  BoolColumn get notificationEnabled =>
      boolean().withDefault(const Constant(false))();
  RealColumn get speedOverride => real().nullable()();
  IntColumn get queueAgeLimitDays => integer().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get refreshedAt => dateTime().nullable()();
}
