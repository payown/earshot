import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/core_providers.dart';
import '../../../../data/rss/parsed_feed.dart';

final podcastPreviewProvider = FutureProvider.autoDispose
    .family<ParsedPodcast, String>((ref, feedUrl) async {
      final dio = ref.watch(dioProvider);
      final parser = ref.watch(rssParserProvider);
      final response = await dio.get<String>(
        feedUrl,
        options: Options(responseType: ResponseType.plain),
      );
      return parser.parse(response.data ?? '');
    });
