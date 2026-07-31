import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../../../core/constants/spacing.dart';
import '../../domain/alphabet_index.dart';

/// A vertical A-Z index for jumping to a section of a long alphabetical list.
///
/// Visually this shows every letter present in [index] so sighted/touch
/// users can tap a letter directly. For VoiceOver/TalkBack, the whole bar is
/// a single "Adjustable" element — matching the section index in apps like
/// Contacts. Once focused, swiping up/down moves to the next/previous letter
/// and announces it along with how many podcasts are in that group.
class AlphabetIndexBar extends StatefulWidget {
  const AlphabetIndexBar({
    required this.index,
    required this.onLetterSelected,
    super.key,
  });

  /// Ordered map of letter -> group info, as produced by
  /// [buildAlphabetIndex].
  final Map<String, AlphabetIndexEntry> index;

  final ValueChanged<AlphabetIndexEntry> onLetterSelected;

  @override
  State<AlphabetIndexBar> createState() => _AlphabetIndexBarState();
}

class _AlphabetIndexBarState extends State<AlphabetIndexBar> {
  int _position = 0;

  @override
  void didUpdateWidget(covariant AlphabetIndexBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final maxPosition = widget.index.length - 1;
    if (_position > maxPosition) {
      _position = maxPosition < 0 ? 0 : maxPosition;
      if (maxPosition >= 0) {
        _announce('List updated. Now at ${_valueAt(_position)}.');
      }
    }
  }

  String _describeLetter(String letter) =>
      letter == '#' ? 'number or symbol' : letter;

  String _valueAt(int position) {
    final letter = widget.index.keys.elementAt(position);
    final entry = widget.index[letter]!;
    final podcastWord = entry.count == 1 ? 'podcast' : 'podcasts';
    return '${_describeLetter(letter)}, ${entry.count} $podcastWord';
  }

  /// Sends a VoiceOver/TalkBack announcement, since the Adjustable value
  /// re-announcement alone doesn't cover boundary or list-changed cases
  /// where the value text doesn't change.
  void _announce(String message) {
    SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      TextDirection.ltr,
    );
  }

  void _select(int position) {
    setState(() => _position = position);
    final letter = widget.index.keys.elementAt(position);
    widget.onLetterSelected(widget.index[letter]!);
  }

  void _adjust(int delta) {
    final newPosition = (_position + delta).clamp(0, widget.index.length - 1);
    if (newPosition == _position) {
      final boundary = delta > 0 ? 'last' : 'first';
      _announce('At the $boundary letter, ${_valueAt(_position)}.');
      return;
    }
    _select(newPosition);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.index.isEmpty) return const SizedBox.shrink();

    final letters = widget.index.keys.toList();

    return Semantics(
      label: 'Alphabet index',
      hint: 'Swipe up or down to browse podcasts alphabetically',
      value: _valueAt(_position),
      increasedValue: _valueAt(
        (_position + 1).clamp(0, letters.length - 1),
      ),
      decreasedValue: _valueAt(
        (_position - 1).clamp(0, letters.length - 1),
      ),
      onIncrease: () => _adjust(1),
      onDecrease: () => _adjust(-1),
      child: ExcludeSemantics(
        child: SizedBox(
          width: 28,
          child: ListView.builder(
            physics: const ClampingScrollPhysics(),
            itemCount: letters.length,
            itemBuilder: (context, position) {
              final letter = letters[position];
              final isCurrent = position == _position;
              return Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: () => _select(position),
                  child: SizedBox(
                    height: Spacing.minTouchTarget,
                    child: Center(
                      child: Text(
                        letter,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: isCurrent
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                          fontWeight: isCurrent
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
