import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/core_providers.dart';
import '../../data/bookmark_repository.dart';
import '../../domain/bookmark.dart';

final bookmarkRepositoryProvider = Provider<BookmarkRepository>(
  (ref) => BookmarkRepositoryImpl(database: ref.watch(appDatabaseProvider)),
);

final bookmarksForEpisodeProvider = StreamProvider.family<List<Bookmark>, int>((
  ref,
  episodeId,
) {
  return ref
      .watch(bookmarkRepositoryProvider)
      .watchBookmarksForEpisode(episodeId);
});
