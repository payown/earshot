import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../../core/providers/core_providers.dart';
import '../domain/chapter.dart';

final _log = Logger('ChapterService');

// Matches M:SS, MM:SS, H:MM:SS, HH:MM:SS — but not plain clock times like
// "at 9:00 am" by requiring the preceding character not to be a digit or colon.
final _timestampRe = RegExp(r'(?<![0-9:])\b(\d{1,3}:\d{2}(?::\d{2})?)\b');

// Separators between a timestamp and its title (leading or trailing).
final _separatorRe = RegExp(r'^[\s\-–—:•·|\t]+|[\s\-–—:•·|\t]+$');

class ChapterService {
  ChapterService(this._dio);

  final Dio _dio;

  // ── Podcasting 2.0 external chapter JSON ─────────────────────────────────

  Future<List<Chapter>> fetchChapters(String url) async {
    try {
      // Fetch as plain string so we own the JSON decode regardless of
      // Content-Type (chapter files are often served as application/json+chapters
      // which dio doesn't auto-decode).
      final response = await _dio.get<String>(
        url,
        options: Options(responseType: ResponseType.plain),
      );
      final body = response.data;
      if (body == null || body.isEmpty) {
        _log.warning('Empty chapter response from $url');
        return [];
      }

      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        _log.warning('Unexpected chapter JSON structure from $url');
        return [];
      }

      final raw = decoded['chapters'];
      if (raw is! List) return [];

      final chapters = <Chapter>[];
      for (var i = 0; i < raw.length; i++) {
        final item = raw[i];
        if (item is! Map) continue;

        // Per Podcasting 2.0 spec: toc: false means hidden from chapter list.
        if (item['toc'] == false) continue;

        final startTime = (item['startTime'] as num?)?.toDouble();
        if (startTime == null) continue;

        chapters.add(
          Chapter(
            index: i,
            startTime: startTime,
            title: item['title'] as String? ?? 'Chapter ${chapters.length + 1}',
            imageUrl: item['img'] as String?,
          ),
        );
      }
      return chapters;
    } catch (e) {
      _log.warning('Failed to fetch chapters from $url: $e');
      return [];
    }
  }

  // ── Description timestamp parser ──────────────────────────────────────────

  /// Parses chapters from timestamps embedded in an HTML episode description.
  /// Handles common formats:
  ///   "0:00 Introduction"
  ///   "Introduction - 0:00"
  ///   "5:30 - Deep Dive into Topic"
  ///
  /// Returns empty list if fewer than 2 timestamps are found (avoids treating
  /// incidental time references in prose as a chapter list).
  static List<Chapter> parseDescriptionChapters(String? html) {
    if (html == null || html.isEmpty) return [];

    // Replace block-level closing tags with newlines before stripping, so
    // adjacent HTML paragraphs/list items land on separate lines.
    final text = html
        .replaceAll(
          RegExp(
            r'<br\s*/?>|</p>|</li>|</div>|</h\d>',
            caseSensitive: false,
          ),
          '\n',
        )
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&#8211;', '–')
        .replaceAll('&#8212;', '—')
        .replaceAll(RegExp(r'&#\d+;'), '')
        .replaceAll(RegExp(r'&[a-z]+;'), '');

    final lines = text.split(RegExp(r'\r?\n'));
    final raw = <(double, String)>[];

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final match = _timestampRe.firstMatch(trimmed);
      if (match == null) continue;

      // Chapter timestamps appear at the START or END of the line.
      // If the timestamp is buried in the middle of prose, ignore it.
      final nearStart = match.start <= 10;
      final nearEnd = match.end >= trimmed.length - 10;
      if (!nearStart && !nearEnd) continue;

      final startTime = _parseTimestamp(match.group(1)!);
      if (startTime == null) continue;

      final title = trimmed
          .replaceFirst(match.group(0)!, '')
          .replaceAll(_separatorRe, '')
          .trim();

      raw.add((startTime, title.isEmpty ? '' : title));
    }

    if (raw.length < 2) return [];

    // Sort by start time (descriptions aren't always ordered).
    raw.sort((a, b) => a.$1.compareTo(b.$1));

    return [
      for (var i = 0; i < raw.length; i++)
        Chapter(
          index: i,
          startTime: raw[i].$1,
          title: raw[i].$2.isEmpty ? 'Chapter ${i + 1}' : raw[i].$2,
        ),
    ];
  }

  static double? _parseTimestamp(String ts) {
    final parts = ts.split(':');
    if (parts.length == 2) {
      final m = int.tryParse(parts[0]);
      final s = int.tryParse(parts[1]);
      if (m == null || s == null || s >= 60) return null;
      return (m * 60 + s).toDouble();
    }
    if (parts.length == 3) {
      final h = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      final s = int.tryParse(parts[2]);
      if (h == null || m == null || s == null || m >= 60 || s >= 60) {
        return null;
      }
      return (h * 3600 + m * 60 + s).toDouble();
    }
    return null;
  }
}

final chapterServiceProvider = Provider<ChapterService>(
  (ref) => ChapterService(ref.watch(dioProvider)),
);
