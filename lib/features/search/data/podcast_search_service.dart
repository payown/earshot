import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../../../core/config/api_keys.dart';
import '../domain/search_result.dart';

final _log = Logger('PodcastSearchService');

class PodcastSearchService {
  const PodcastSearchService({required Dio dio}) : _dio = dio;

  final Dio _dio;

  static const _baseUrl = 'https://api.podcastindex.org/api/1.0';

  Future<List<PodcastSearchResult>> search(String query) async {
    if (query.trim().isEmpty) return [];

    final unixTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final hashInput = '$podcastIndexApiKey$podcastIndexApiSecret$unixTime';
    final authHash = sha1.convert(utf8.encode(hashInput)).toString();

    try {
      final response = await _dio.get<String>(
        '$_baseUrl/search/byterm',
        queryParameters: {'q': query.trim(), 'max': 20},
        options: Options(
          responseType: ResponseType.plain,
          headers: {
            'X-Auth-Key': podcastIndexApiKey,
            'X-Auth-Date': unixTime.toString(),
            'Authorization': authHash,
            'User-Agent': 'Earshot/1.0 (+https://github.com/payown/earshot)',
          },
        ),
      );

      final body = response.data;
      if (body == null || body.isEmpty) {
        _log.warning('Podcast Index search returned empty body for "$query"');
        return [];
      }

      final data = jsonDecode(body) as Map<String, dynamic>?;
      if (data == null) {
        _log.warning('Podcast Index search returned null JSON for "$query"');
        return [];
      }

      final feeds = data['feeds'] as List<dynamic>? ?? [];
      return feeds
          .whereType<Map<String, dynamic>>()
          .where((f) => f['url'] != null)
          .map(_fromPodcastIndex)
          .toList();
    } on DioException catch (e) {
      _log.warning('Podcast Index search failed: ${e.message}');
      return [];
    }
  }

  PodcastSearchResult _fromPodcastIndex(Map<String, dynamic> json) {
    return PodcastSearchResult(
      title: (json['title'] as String?) ?? '',
      feedUrl: json['url'] as String,
      author: (json['author'] as String?)?.isNotEmpty == true
          ? json['author'] as String
          : json['ownerName'] as String?,
      artworkUrl: (json['artwork'] as String?)?.isNotEmpty == true
          ? json['artwork'] as String
          : json['image'] as String?,
      description: json['description'] as String?,
    );
  }
}
