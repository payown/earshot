import 'package:drift/drift.dart';

import '../../../data/db/app_database.dart';
import '../domain/bookmark.dart';

abstract interface class BookmarkRepository {
  Future<Bookmark> addBookmark(
    int episodeId,
    int positionSeconds, {
    String note,
  });

  Future<void> deleteBookmark(int bookmarkId);

  Stream<List<Bookmark>> watchBookmarksForEpisode(int episodeId);
}

class BookmarkRepositoryImpl implements BookmarkRepository {
  const BookmarkRepositoryImpl({required AppDatabase database})
    : _db = database;

  final AppDatabase _db;

  @override
  Future<Bookmark> addBookmark(
    int episodeId,
    int positionSeconds, {
    String note = '',
  }) async {
    final id = await _db
        .into(_db.bookmarks)
        .insert(
          BookmarksCompanion.insert(
            episodeId: episodeId,
            positionSeconds: positionSeconds,
            note: Value(note),
          ),
        );
    final row = await (_db.select(
      _db.bookmarks,
    )..where((b) => b.id.equals(id))).getSingle();
    return _fromRow(row);
  }

  @override
  Future<void> deleteBookmark(int bookmarkId) async {
    await (_db.delete(
      _db.bookmarks,
    )..where((b) => b.id.equals(bookmarkId))).go();
  }

  @override
  Stream<List<Bookmark>> watchBookmarksForEpisode(int episodeId) {
    return (_db.select(_db.bookmarks)
          ..where((b) => b.episodeId.equals(episodeId))
          ..orderBy([(b) => OrderingTerm.asc(b.positionSeconds)]))
        .watch()
        .map((rows) => rows.map(_fromRow).toList());
  }

  Bookmark _fromRow(BookmarkRow row) => Bookmark(
    id: row.id,
    episodeId: row.episodeId,
    positionSeconds: row.positionSeconds,
    note: row.note,
    createdAt: row.createdAt,
  );
}
