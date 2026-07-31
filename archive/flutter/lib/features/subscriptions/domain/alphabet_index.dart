import 'podcast.dart';

/// Metadata for one letter group in an [AlphabetIndexBar].
class AlphabetIndexEntry {
  const AlphabetIndexEntry({required this.firstIndex, required this.count});

  /// Index of this group's first podcast in the list passed to
  /// [buildAlphabetIndex].
  final int firstIndex;

  /// Number of podcasts in this group.
  final int count;
}

/// Groups [podcasts] by the uppercase first letter of their title.
///
/// [podcasts] is expected to already be sorted alphabetically by title,
/// case-insensitively — this just locates each letter's first occurrence and
/// counts members, it doesn't sort. Titles that don't start with A-Z (digits,
/// symbols, emoji, etc.) are grouped under '#'.
///
/// Returns group keys in display order ('#' first, then A-Z) mapped to their
/// [AlphabetIndexEntry]. Only letters actually present are included.
Map<String, AlphabetIndexEntry> buildAlphabetIndex(List<Podcast> podcasts) {
  final entries = <String, AlphabetIndexEntry>{};
  for (var i = 0; i < podcasts.length; i++) {
    final key = _indexKeyFor(podcasts[i].title);
    final existing = entries[key];
    entries[key] = existing == null
        ? AlphabetIndexEntry(firstIndex: i, count: 1)
        : AlphabetIndexEntry(
            firstIndex: existing.firstIndex,
            count: existing.count + 1,
          );
  }

  final sortedKeys = entries.keys.toList()
    ..sort((a, b) {
      if (a == '#') return b == '#' ? 0 : -1;
      if (b == '#') return 1;
      return a.compareTo(b);
    });

  return {for (final key in sortedKeys) key: entries[key]!};
}

final _letterPattern = RegExp(r'^[A-Z]$');

String _indexKeyFor(String title) {
  final trimmed = title.trim();
  if (trimmed.isEmpty) return '#';
  final firstChar = trimmed[0].toUpperCase();
  return _letterPattern.hasMatch(firstChar) ? firstChar : '#';
}
