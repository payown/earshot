import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/core_providers.dart';
import '../../data/opml_service.dart';
import '../../data/podcast_search_service.dart';
import '../../domain/search_result.dart';

final podcastSearchServiceProvider = Provider<PodcastSearchService>(
  (ref) => PodcastSearchService(dio: ref.watch(dioProvider)),
);

final opmlServiceProvider = Provider<OpmlService>((_) => OpmlService());

final podcastSearchProvider = FutureProvider.autoDispose
    .family<List<PodcastSearchResult>, String>(
      (ref, query) async {
        if (query.isEmpty) return [];
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return ref.read(podcastSearchServiceProvider).search(query);
      },
    );
