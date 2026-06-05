import 'package:logging/logging.dart';
import 'package:xml/xml.dart';

import 'parsed_feed.dart';

final _log = Logger('RssParser');

class RssParseException implements Exception {
  const RssParseException(this.message);
  final String message;

  @override
  String toString() => 'RssParseException: $message';
}

class RssParser {
  ParsedPodcast parse(String xmlContent) {
    late final XmlDocument document;
    try {
      document = XmlDocument.parse(xmlContent);
    } on XmlException catch (e) {
      throw RssParseException('Invalid XML: $e');
    }

    final channel = document.findAllElements('channel').firstOrNull;
    if (channel == null) {
      throw const RssParseException('No <channel> element found');
    }

    return ParsedPodcast(
      title: _directText(channel, 'title') ?? '',
      author: _itunesText(channel, 'author') ?? _directText(channel, 'author'),
      description:
          _itunesText(channel, 'summary') ??
          _directText(channel, 'description'),
      artworkUrl: _itunesImageUrl(channel) ?? _imageUrl(channel),
      websiteUrl: _directText(channel, 'link'),
      language: _directText(channel, 'language'),
      category: _itunesCategory(channel),
      episodes: _parseEpisodes(channel),
    );
  }

  List<ParsedEpisode> _parseEpisodes(XmlElement channel) {
    final episodes = <ParsedEpisode>[];
    for (final item in channel.findElements('item')) {
      final episode = _parseEpisode(item);
      if (episode != null) episodes.add(episode);
    }
    return episodes;
  }

  ParsedEpisode? _parseEpisode(XmlElement item) {
    final audioUrl = _enclosureUrl(item);
    if (audioUrl == null) return null;

    final rawGuid = _directText(item, 'guid');
    if (rawGuid == null) {
      _log.warning(
        'Episode missing <guid>; falling back to enclosure URL: $audioUrl',
      );
    }
    final guid = rawGuid ?? audioUrl;
    final title = _directText(item, 'title') ?? '';

    return ParsedEpisode(
      guid: guid,
      title: title,
      audioUrl: audioUrl,
      description:
          _itunesText(item, 'summary') ?? _directText(item, 'description'),
      durationSeconds: _parseDuration(_itunesText(item, 'duration')),
      pubDate: _parsePubDate(_directText(item, 'pubDate')),
      artworkUrl: _itunesImageUrl(item),
      episodeNumber: _parseInt(_itunesText(item, 'episode')),
      seasonNumber: _parseInt(_itunesText(item, 'season')),
      chapterUrl: _podcastText(item, 'chapters'),
      transcriptUrl: _podcastTranscriptUrl(item),
    );
  }

  // Returns the text content of the first direct child with the given local name.
  String? _directText(XmlElement parent, String localName) {
    for (final el in parent.childElements) {
      if (el.localName == localName && el.namespaceUri == null) {
        final text = el.innerText.trim();
        return text.isEmpty ? null : text;
      }
    }
    return null;
  }

  // Returns text from an itunes-namespaced element.
  String? _itunesText(XmlElement parent, String localName) {
    for (final el in parent.childElements) {
      if (el.localName == localName &&
          (el.namespaceUri?.contains('itunes') ?? false)) {
        final text = el.innerText.trim();
        return text.isEmpty ? null : text;
      }
    }
    return null;
  }

  // Returns the href attribute from a podcast-namespaced element.
  // Falls back to prefix check in case namespace resolution returns null.
  String? _podcastText(XmlElement parent, String localName) {
    for (final el in parent.childElements) {
      if (el.localName == localName &&
          ((el.namespaceUri?.contains('podcastindex') ?? false) ||
              el.name.prefix == 'podcast')) {
        return el.getAttribute('url') ??
            el.getAttribute('href') ??
            el.innerText.trim().nullIfEmpty;
      }
    }
    return null;
  }

  // Finds the first podcast:transcript element with type text/vtt or text/srt.
  String? _podcastTranscriptUrl(XmlElement item) {
    for (final el in item.childElements) {
      if (el.localName == 'transcript' &&
          ((el.namespaceUri?.contains('podcastindex') ?? false) ||
              el.name.prefix == 'podcast')) {
        final type = el.getAttribute('type') ?? '';
        if (type.contains('vtt') ||
            type.contains('srt') ||
            type.contains('json')) {
          return el.getAttribute('url');
        }
      }
    }
    return null;
  }

  String? _itunesImageUrl(XmlElement parent) {
    for (final el in parent.childElements) {
      if (el.localName == 'image' &&
          (el.namespaceUri?.contains('itunes') ?? false)) {
        return el.getAttribute('href');
      }
    }
    return null;
  }

  String? _imageUrl(XmlElement channel) {
    final image = channel.findElements('image').firstOrNull;
    if (image == null) return null;
    return image.findElements('url').firstOrNull?.innerText.trim().nullIfEmpty;
  }

  String? _enclosureUrl(XmlElement item) {
    final enclosure = item.findElements('enclosure').firstOrNull;
    return enclosure?.getAttribute('url')?.trim().nullIfEmpty;
  }

  String? _itunesCategory(XmlElement channel) {
    for (final el in channel.childElements) {
      if (el.localName == 'category' &&
          (el.namespaceUri?.contains('itunes') ?? false)) {
        return el.getAttribute('text');
      }
    }
    return null;
  }

  int? _parseDuration(String? value) {
    if (value == null) return null;
    final parts = value.trim().split(':');
    if (parts.length == 1) return int.tryParse(parts[0]);
    if (parts.length == 2) {
      final m = int.tryParse(parts[0]) ?? 0;
      final s = int.tryParse(parts[1]) ?? 0;
      return m * 60 + s;
    }
    if (parts.length == 3) {
      final h = int.tryParse(parts[0]) ?? 0;
      final m = int.tryParse(parts[1]) ?? 0;
      final s = int.tryParse(parts[2]) ?? 0;
      return h * 3600 + m * 60 + s;
    }
    return null;
  }

  DateTime? _parsePubDate(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();

    final iso = DateTime.tryParse(trimmed);
    if (iso != null) return iso.toUtc();

    // RFC 2822: "Mon, 01 Jan 2024 00:00:00 +0000"
    final match = RegExp(
      r'\w+,\s+(\d{1,2})\s+(\w{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})',
    ).firstMatch(trimmed);
    if (match == null) return null;

    const months = {
      'Jan': 1,
      'Feb': 2,
      'Mar': 3,
      'Apr': 4,
      'May': 5,
      'Jun': 6,
      'Jul': 7,
      'Aug': 8,
      'Sep': 9,
      'Oct': 10,
      'Nov': 11,
      'Dec': 12,
    };

    final month = months[match.group(2)];
    if (month == null) return null;

    return DateTime.utc(
      int.parse(match.group(3)!),
      month,
      int.parse(match.group(1)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
    );
  }

  int? _parseInt(String? value) => value == null ? null : int.tryParse(value);
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
