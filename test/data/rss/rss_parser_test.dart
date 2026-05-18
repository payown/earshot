import 'dart:io';

import 'package:earshot/data/rss/rss_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late RssParser parser;
  late String sampleFeedXml;

  setUpAll(() {
    sampleFeedXml = File(
      'test/data/rss/fixtures/sample_feed.xml',
    ).readAsStringSync();
  });

  setUp(() => parser = RssParser());

  group('RssParser', () {
    group('podcast-level fields', () {
      test('parses title', () {
        final feed = parser.parse(sampleFeedXml);
        expect(feed.title, 'Test Podcast');
      });

      test('parses itunes:author', () {
        final feed = parser.parse(sampleFeedXml);
        expect(feed.author, 'Jane Smith');
      });

      test('parses itunes:image', () {
        final feed = parser.parse(sampleFeedXml);
        expect(feed.artworkUrl, 'https://example.com/artwork.jpg');
      });

      test('parses website link', () {
        final feed = parser.parse(sampleFeedXml);
        expect(feed.websiteUrl, 'https://example.com/podcast');
      });

      test('parses language', () {
        final feed = parser.parse(sampleFeedXml);
        expect(feed.language, 'en-us');
      });

      test('parses itunes:category', () {
        final feed = parser.parse(sampleFeedXml);
        expect(feed.category, 'Technology');
      });
    });

    group('episode list', () {
      test('skips items without enclosure', () {
        final feed = parser.parse(sampleFeedXml);
        expect(feed.episodes.length, 2);
      });

      test('parses episode 1 guid', () {
        final feed = parser.parse(sampleFeedXml);
        expect(feed.episodes[0].guid, 'https://example.com/episodes/1');
      });

      test('parses episode 1 title', () {
        final feed = parser.parse(sampleFeedXml);
        expect(feed.episodes[0].title, 'Episode 1: The Beginning');
      });

      test('parses episode 1 audio url', () {
        final feed = parser.parse(sampleFeedXml);
        expect(feed.episodes[0].audioUrl, 'https://example.com/ep1.mp3');
      });

      test('parses duration as plain seconds', () {
        final feed = parser.parse(sampleFeedXml);
        expect(feed.episodes[0].durationSeconds, 3600);
      });

      test('parses duration in HH:MM:SS format', () {
        final feed = parser.parse(sampleFeedXml);
        expect(feed.episodes[1].durationSeconds, 6330); // 1*3600 + 45*60 + 30
      });

      test('parses RFC 2822 pubDate', () {
        final feed = parser.parse(sampleFeedXml);
        expect(
          feed.episodes[0].pubDate,
          DateTime.utc(2024, 1, 1, 8, 0, 0),
        );
      });

      test('parses episode number and season', () {
        final feed = parser.parse(sampleFeedXml);
        expect(feed.episodes[0].episodeNumber, 1);
        expect(feed.episodes[0].seasonNumber, 1);
      });

      test('parses episode artwork', () {
        final feed = parser.parse(sampleFeedXml);
        expect(feed.episodes[0].artworkUrl, 'https://example.com/ep1-art.jpg');
      });

      test('parses podcast:chapters url', () {
        final feed = parser.parse(sampleFeedXml);
        expect(
          feed.episodes[0].chapterUrl,
          'https://example.com/ep1.chapters.json',
        );
      });

      test('parses podcast:transcript url', () {
        final feed = parser.parse(sampleFeedXml);
        expect(
          feed.episodes[0].transcriptUrl,
          'https://example.com/ep1.vtt',
        );
      });

      test('falls back to plain description when no itunes:summary', () {
        final feed = parser.parse(sampleFeedXml);
        expect(
          feed.episodes[1].description,
          'The second episode, described in plain RSS.',
        );
      });
    });

    group('error handling', () {
      test('throws RssParseException on invalid XML', () {
        expect(
          () => parser.parse('<not valid xml>>>'),
          throwsA(isA<RssParseException>()),
        );
      });

      test('throws RssParseException when no channel element', () {
        expect(
          () => parser.parse('<rss version="2.0"></rss>'),
          throwsA(isA<RssParseException>()),
        );
      });
    });
  });
}
