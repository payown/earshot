import 'package:drift/drift.dart';

import 'podcast_folders.dart';
import 'podcasts.dart';

@DataClassName('PodcastFolderMembershipRow')
class PodcastFolderMemberships extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get folderId => integer().references(
    PodcastFolders,
    #id,
    onDelete: KeyAction.cascade,
  )();
  IntColumn get podcastId => integer().references(
    Podcasts,
    #id,
    onDelete: KeyAction.cascade,
  )();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {folderId, podcastId},
  ];
}
