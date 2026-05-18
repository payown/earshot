import 'package:earshot/features/search/data/opml_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late OpmlService service;

  setUp(() => service = OpmlService());

  group('parse', () {
    test('parses xmlUrl attributes', () {
      const opml = '''<?xml version="1.0"?>
<opml version="2.0">
  <body>
    <outline type="rss" text="Test Podcast" xmlUrl="https://example.com/feed.rss"/>
    <outline type="rss" text="Another Show" xmlUrl="https://another.com/rss"/>
  </body>
</opml>''';

      final result = service.parse(opml);
      expect(result.feedUrls.length, 2);
      expect(result.feedUrls[0], 'https://example.com/feed.rss');
      expect(result.feedUrls[1], 'https://another.com/rss');
      expect(result.titles[0], 'Test Podcast');
    });

    test('handles nested outlines', () {
      const opml = '''<?xml version="1.0"?>
<opml version="2.0">
  <body>
    <outline text="Technology">
      <outline type="rss" text="Tech Show" xmlUrl="https://tech.com/feed.rss"/>
    </outline>
  </body>
</opml>''';

      final result = service.parse(opml);
      expect(result.feedUrls.length, 1);
      expect(result.feedUrls[0], 'https://tech.com/feed.rss');
    });

    test('returns empty on malformed XML', () {
      final result = service.parse('<not valid >>>');
      expect(result.feedUrls, isEmpty);
    });

    test('returns empty when no rss outlines found', () {
      const opml = '''<?xml version="1.0"?>
<opml version="2.0"><body></body></opml>''';
      final result = service.parse(opml);
      expect(result.feedUrls, isEmpty);
    });

    test('skips outlines without xmlUrl', () {
      const opml = '''<?xml version="1.0"?>
<opml version="2.0">
  <body>
    <outline text="No URL"/>
    <outline type="rss" text="Has URL" xmlUrl="https://example.com/feed.rss"/>
  </body>
</opml>''';
      final result = service.parse(opml);
      expect(result.feedUrls.length, 1);
    });
  });

  group('generate', () {
    test('produces valid OPML with all feeds', () {
      final subs = [
        (rssUrl: 'https://a.com/feed.rss', title: 'Podcast A'),
        (rssUrl: 'https://b.com/feed.rss', title: 'Podcast B'),
      ];

      final xml = service.generate(subs);
      expect(xml, contains('xmlUrl="https://a.com/feed.rss"'));
      expect(xml, contains('xmlUrl="https://b.com/feed.rss"'));
      expect(xml, contains('text="Podcast A"'));
      expect(xml, contains('<opml'));
    });

    test('round-trips through parse', () {
      final subs = [
        (rssUrl: 'https://example.com/feed.rss', title: 'Test Podcast'),
      ];
      final xml = service.generate(subs);
      final parsed = service.parse(xml);
      expect(parsed.feedUrls, ['https://example.com/feed.rss']);
      expect(parsed.titles, ['Test Podcast']);
    });
  });
}
