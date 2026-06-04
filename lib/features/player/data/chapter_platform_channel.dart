import 'dart:async';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import '../domain/chapter.dart';

final _log = Logger('ChapterPlatformChannel');

class ChapterPlatformChannel {
  static const _channel = MethodChannel('media.payown.earshot/chapters');

  /// Reads ID3 CHAP frames (MP3) or QuickTime chapter tracks (M4A) from the
  /// audio file at [audioUrl] using native platform APIs.
  /// Returns an empty list on any error or if the file has no chapters.
  static Future<List<Chapter>> getChapters(String audioUrl) async {
    try {
      final raw = await _channel
          .invokeListMethod<Object?>('getChapters', {'url': audioUrl})
          .timeout(const Duration(seconds: 10));

      if (raw == null || raw.isEmpty) return [];

      final chapters = <Chapter>[];
      for (var i = 0; i < raw.length; i++) {
        final item = raw[i];
        if (item is! Map) continue;
        final startTime = (item['startTime'] as num?)?.toDouble();
        if (startTime == null) continue;
        final rawTitle = item['title'] as String? ?? '';
        chapters.add(
          Chapter(
            index: i,
            startTime: startTime,
            title: rawTitle.isEmpty ? 'Chapter ${i + 1}' : rawTitle,
          ),
        );
      }
      return chapters;
    } on TimeoutException {
      _log.warning('Chapter platform channel timed out for $audioUrl');
      return [];
    } on PlatformException catch (e) {
      _log.warning('Chapter platform channel error for $audioUrl: $e');
      return [];
    }
  }
}
