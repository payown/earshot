import 'package:earshot/features/subscriptions/domain/alphabet_index.dart';
import 'package:earshot/features/subscriptions/domain/podcast.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime(2024, 6, 1);

Podcast _podcast(int id, String title) => Podcast(
  id: id,
  rssUrl: 'https://example.com/$id.xml',
  title: title,
  autoQueue: false,
  notificationEnabled: false,
  inboxExcluded: false,
  inboxIncluded: false,
  createdAt: _now,
);

void main() {
  group('buildAlphabetIndex', () {
    test('returns an empty map for an empty list', () {
      expect(buildAlphabetIndex(const []), isEmpty);
    });

    test('groups by uppercase first letter and counts members', () {
      final podcasts = [
        _podcast(0, '1Up Show'),
        _podcast(1, 'Alpha Cast'),
        _podcast(2, 'Apple Cast'),
        _podcast(3, 'Banana Cast'),
        _podcast(4, 'zebra cast'),
      ];

      final index = buildAlphabetIndex(podcasts);

      expect(index.keys.toList(), ['#', 'A', 'B', 'Z']);
      expect(index['#']!.firstIndex, 0);
      expect(index['#']!.count, 1);
      expect(index['A']!.firstIndex, 1);
      expect(index['A']!.count, 2);
      expect(index['B']!.firstIndex, 3);
      expect(index['B']!.count, 1);
      expect(index['Z']!.firstIndex, 4);
      expect(index['Z']!.count, 1);
    });

    test('only includes letters actually present', () {
      final podcasts = [_podcast(0, 'Only One')];

      final index = buildAlphabetIndex(podcasts);

      expect(index.keys.toList(), ['O']);
    });
  });
}
