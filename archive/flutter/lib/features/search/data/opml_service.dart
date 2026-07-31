import 'package:xml/xml.dart';

class OpmlParseResult {
  const OpmlParseResult({
    required this.feedUrls,
    required this.titles,
    this.folderGroups = const {},
  });

  final List<String> feedUrls;
  final List<String> titles;

  // Maps folder name → list of feed URLs from nested outline groups.
  // Empty when the OPML has no folder structure.
  final Map<String, List<String>> folderGroups;
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
    final folderGroups = <String, List<String>>{};

    // Find the <body> element; fall back to scanning everything.
    final body = doc
        .findElements('opml')
        .firstOrNull
        ?.findElements('body')
        .firstOrNull;
    final topLevelOutlines = body != null
        ? body.findElements('outline').toList()
        : doc.findAllElements('outline').where((e) => e.depth == 3).toList();

    for (final outline in topLevelOutlines) {
      final url =
          outline.getAttribute('xmlUrl') ??
          outline.getAttribute('url') ??
          outline.getAttribute('xmlurl');
      final title =
          outline.getAttribute('text') ?? outline.getAttribute('title') ?? '';

      if (url != null && url.isNotEmpty) {
        // Flat podcast outline.
        feedUrls.add(url);
        titles.add(title);
      } else {
        // Potential folder group: check for child podcast outlines.
        final children = outline.findElements('outline').toList();
        final childFeeds = <String>[];
        for (final child in children) {
          final childUrl =
              child.getAttribute('xmlUrl') ??
              child.getAttribute('url') ??
              child.getAttribute('xmlurl');
          final childTitle =
              child.getAttribute('text') ?? child.getAttribute('title') ?? '';
          if (childUrl != null && childUrl.isNotEmpty) {
            childFeeds.add(childUrl);
            if (!feedUrls.contains(childUrl)) {
              feedUrls.add(childUrl);
              titles.add(childTitle);
            }
          }
        }
        if (childFeeds.isNotEmpty && title.isNotEmpty) {
          folderGroups[title] = childFeeds;
        }
      }
    }

    return OpmlParseResult(
      feedUrls: feedUrls,
      titles: titles,
      folderGroups: folderGroups,
    );
  }

  // Generates OPML with folder groups as nested <outline> elements.
  // Groups with folderName == null are written as "Uncategorized" and placed
  // last. Podcasts in multiple folders appear in each group.
  String generateWithFolders(
    List<({String? folderName, List<({String rssUrl, String title})> podcasts})>
    groups,
  ) {
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
            // Named folders first.
            for (final group in groups.where((g) => g.folderName != null)) {
              builder.element(
                'outline',
                attributes: {'text': group.folderName!},
                nest: () {
                  for (final sub in group.podcasts) {
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
            }
            // Unfiled group last, only if non-empty.
            final unfiled = groups.where((g) => g.folderName == null).toList();
            if (unfiled.isNotEmpty && unfiled.first.podcasts.isNotEmpty) {
              builder.element(
                'outline',
                attributes: {'text': 'Uncategorized'},
                nest: () {
                  for (final sub in unfiled.first.podcasts) {
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
            }
          },
        );
      },
    );
    return builder.buildDocument().toXmlString(pretty: true);
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
