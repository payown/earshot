import 'package:earshot/core/utils/text_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('stripHtml', () {
    test('returns empty for null or empty', () {
      expect(stripHtml(null), '');
      expect(stripHtml(''), '');
    });

    test('strips tags, decodes entities, collapses whitespace', () {
      expect(
        stripHtml('<p>Tom &amp; Jerry</p>\n<p>are   here</p>'),
        'Tom & Jerry are here',
      );
    });

    test('decodes numeric and hex character references', () {
      expect(stripHtml('It&#8217;s here'), 'It’s here');
      expect(stripHtml('A&#x2014;B'), 'A—B');
    });

    test('decodes common named entities so they are not spoken raw', () {
      expect(stripHtml('well&mdash;maybe&hellip;'), 'well—maybe…');
      expect(stripHtml('she&rsquo;s right'), 'she’s right');
    });
  });

  group('descriptionPreview', () {
    test('returns empty for null', () {
      expect(descriptionPreview(null), '');
    });

    test('returns full stripped text when under the limit', () {
      expect(
        descriptionPreview('<p>A short note.</p>'),
        'A short note.',
      );
    });

    test('truncates long text at a word boundary with an ellipsis', () {
      final long = 'word ' * 100; // 500 chars
      final preview = descriptionPreview(long, maxChars: 20);
      expect(preview.endsWith('…'), isTrue);
      expect(preview.length, lessThanOrEqualTo(21));
      // Does not cut mid-word: nothing but whole "word" tokens before ellipsis.
      expect(preview.replaceAll('…', '').trim(), 'word word word word');
    });

    test('strips HTML before measuring length', () {
      const html = '<p>Hello <strong>world</strong> this is plenty</p>';
      expect(descriptionPreview(html, maxChars: 11), 'Hello world…');
    });
  });
}
