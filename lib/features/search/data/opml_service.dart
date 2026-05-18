import 'package:xml/xml.dart';

class OpmlParseResult {
  const OpmlParseResult({required this.feedUrls, required this.titles});

  final List<String> feedUrls;
  final List<String> titles;
}

class OpmlService {
  OpmlParseResult parse(String xmlContent) {
    late final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xmlContent);
    } on XmlException {
      return const OpmlParseResult(feedUrls: [], titles: []);
    }

    final feedUrls = <String>[];
    final titles = <String>[];

    for (final outline in doc.findAllElements('outline')) {
      final url =
          outline.getAttribute('xmlUrl') ??
          outline.getAttribute('url') ??
          outline.getAttribute('xmlurl');
      final title =
          outline.getAttribute('text') ?? outline.getAttribute('title') ?? '';

      if (url != null && url.isNotEmpty) {
        feedUrls.add(url);
        titles.add(title);
      }
    }

    return OpmlParseResult(feedUrls: feedUrls, titles: titles);
  }

  String generate(List<({String rssUrl, String title})> subscriptions) {
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element(
      'opml',
      attributes: {'version': '2.0'},
      nest: () {
        builder.element(
          'head',
          nest: () {
            builder.element(
              'title',
              nest: () => builder.text('Earshot Subscriptions'),
            );
          },
        );
        builder.element(
          'body',
          nest: () {
            for (final sub in subscriptions) {
              builder.element(
                'outline',
                attributes: {
                  'type': 'rss',
                  'text': sub.title,
                  'title': sub.title,
                  'xmlUrl': sub.rssUrl,
                },
              );
            }
          },
        );
      },
    );
    return builder.buildDocument().toXmlString(pretty: true);
  }
}
