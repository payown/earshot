import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../domain/search_result.dart';

final _log = Logger('PodcastSearchService');

class PodcastSearchService {
  const PodcastSearchService({required Dio dio}) : _dio = dio;

  final Dio _dio;

  static const _itunesBaseUrl = 'https://itunes.apple.com/search';

  Future<List<PodcastSearchResult>> search(String query) async {
    if (query.trim().isEmpty) return [];

    try {
      final response = await _dio.get<String>(
        _itunesBaseUrl,
        queryParameters: {
          'term': query.trim(),
          'media': 'podcast',
          'limit': 20,
          'entity': 'podcast',
        },
        options: Options(responseType: ResponseType.plain),
      );

      final body = response.data;
      if (body == null || body.isEmpty) {
        _log.warning('iTunes search returned empty body for query: "$query"');
        return [];
      }

      final data = jsonDecode(body) as Map<String, dynamic>?;
      if (data == null) {
        _log.warning('iTunes search returned null JSON for query: "$query"');
        return [];
      }

      final results = data['results'] as List<dynamic>? ?? [];
      return results
          .whereType<Map<String, dynamic>>()
          .where((r) => r['feedUrl'] != null)
          .map(_fromItunes)
          .toList();
    } on DioException catch (e) {
      _log.warning('iTunes search failed: ${e.message}');
      return [];
    }
  }

  PodcastSearchResult _fromItunes(Map<String, dynamic> json) {
    return PodcastSearchResult(
      title: (json['trackName'] as String?) ?? '',
      feedUrl: json['feedUrl'] as String,
      author: json['artistName'] as String?,
      artworkUrl: (json['artworkUrl600'] ?? json['artworkUrl100']) as String?,
      description: json['description'] as String?,
    );
  }
}
