import 'package:flutter_test/flutter_test.dart';

import 'package:earshot/features/player/data/chapter_service.dart';

void main() {
  group('ChapterService.parseDescriptionChapters', () {
    test('returns empty for null input', () {
      expect(ChapterService.parseDescriptionChapters(null), isEmpty);
    });

    test('returns empty for blank input', () {
      expect(ChapterService.parseDescriptionChapters('   '), isEmpty);
    });

    test('returns empty for a single timestamp (requires at least 2)', () {
      const desc = 'Check out 5:30 for the best part of this episode.';
      expect(ChapterService.parseDescriptionChapters(desc), isEmpty);
    });

    test('parses "Title Timestamp" format', () {
      const desc = '''
Introduction 0:00
Interview with Guest 5:30
Outro 1:15:00
''';
      final chapters = ChapterService.parseDescriptionChapters(desc);
      expect(chapters, hasLength(3));
      expect(chapters[0].title, 'Introduction');
      expect(chapters[0].startTime, 0.0);
      expect(chapters[1].title, 'Interview with Guest');
      expect(chapters[1].startTime, 330.0);
      expect(chapters[2].title, 'Outro');
      expect(chapters[2].startTime, 4500.0);
    });

    test('parses "Timestamp Title" format', () {
      const desc = '''
0:00 Introduction
5:30 Interview with Guest
1:15:00 Outro
''';
      final chapters = ChapterService.parseDescriptionChapters(desc);
      expect(chapters, hasLength(3));
      expect(chapters[0].title, 'Introduction');
      expect(chapters[1].title, 'Interview with Guest');
      expect(chapters[2].title, 'Outro');
    });

    test('parses "Timestamp - Title" format with dashes', () {
      const desc = '''
0:00 - Introduction
5:30 - Main topic
''';
      final chapters = ChapterService.parseDescriptionChapters(desc);
      expect(chapters, hasLength(2));
      expect(chapters[0].title, 'Introduction');
      expect(chapters[1].title, 'Main topic');
    });

    test('strips HTML tags and parses paragraphs', () {
      const html = '''
<p><strong>0:00</strong> Introduction</p>
<p><strong>5:30</strong> Interview segment</p>
''';
      final chapters = ChapterService.parseDescriptionChapters(html);
      expect(chapters, hasLength(2));
      expect(chapters[0].title, 'Introduction');
      expect(chapters[1].title, 'Interview segment');
    });

    test('strips HTML list items', () {
      const html = '''
<ul>
<li>0:00 Introduction</li>
<li>5:30 Deep dive</li>
</ul>
''';
      final chapters = ChapterService.parseDescriptionChapters(html);
      expect(chapters, hasLength(2));
      expect(chapters[0].title, 'Introduction');
      expect(chapters[1].title, 'Deep dive');
    });

    test('sorts chapters by start time when out of order', () {
      const desc = '''
5:30 Second
0:00 First
''';
      final chapters = ChapterService.parseDescriptionChapters(desc);
      expect(chapters[0].startTime, 0.0);
      expect(chapters[0].title, 'First');
      expect(chapters[1].startTime, 330.0);
      expect(chapters[1].title, 'Second');
    });

    test('ignores long prose lines with embedded times', () {
      const desc = '''
0:00 Intro
This is a long sentence that happens to mention a time of 5:30 pm in the middle of the text and goes on for a while.
10:00 Outro
''';
      final chapters = ChapterService.parseDescriptionChapters(desc);
      expect(chapters, hasLength(2));
      expect(chapters[0].title, 'Intro');
      expect(chapters[1].title, 'Outro');
    });

    test('ignores invalid timestamps (seconds >= 60)', () {
      const desc = '''
0:00 Valid chapter
5:75 Invalid seconds
10:00 Another valid chapter
''';
      final chapters = ChapterService.parseDescriptionChapters(desc);
      expect(chapters, hasLength(2));
    });

    test('assigns fallback title when line has only a timestamp', () {
      const desc = '''
0:00
5:30
''';
      final chapters = ChapterService.parseDescriptionChapters(desc);
      expect(chapters, hasLength(2));
      expect(chapters[0].title, 'Chapter 1');
      expect(chapters[1].title, 'Chapter 2');
    });

    test('indices are contiguous after sort', () {
      const desc = '''
10:00 Third
0:00 First
5:00 Second
''';
      final chapters = ChapterService.parseDescriptionChapters(desc);
      expect(chapters.map((c) => c.index).toList(), [0, 1, 2]);
    });
  });
}
