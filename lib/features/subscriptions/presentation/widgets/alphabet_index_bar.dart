import 'package:flutter/material.dart';

import '../../../../core/constants/spacing.dart';

/// A vertical A-Z index for jumping to a section of a long alphabetical list.
///
/// Only letters present in [letters] are shown — VoiceOver/TalkBack users get
/// a clean swipe-through list of just the available letters, each its own
/// `Semantics` button reachable without any drag gesture. The bar scrolls
/// independently of the main list if it doesn't fit the available height.
class AlphabetIndexBar extends StatelessWidget {
  const AlphabetIndexBar({
    required this.letters,
    required this.onLetterSelected,
    super.key,
  });

  final List<String> letters;
  final ValueChanged<String> onLetterSelected;

  @override
  Widget build(BuildContext context) {
    if (letters.isEmpty) return const SizedBox.shrink();

    return Semantics(
      container: true,
      label: 'Alphabet index',
      child: SizedBox(
        width: 28,
        child: ListView.builder(
          physics: const ClampingScrollPhysics(),
          itemCount: letters.length,
          itemBuilder: (context, index) {
            final letter = letters[index];
            final label = letter == '#'
                ? 'Jump to podcasts starting with a number or symbol'
                : 'Jump to $letter';
            return Semantics(
              button: true,
              label: label,
              onTap: () => onLetterSelected(letter),
              child: ExcludeSemantics(
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    onTap: () => onLetterSelected(letter),
                    child: SizedBox(
                      height: Spacing.xl,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Spacing.xs,
                        ),
                        child: Center(
                          child: Text(
                            letter,
                            textAlign: TextAlign.center,
                            style:
                                Theme.of(
                                  context,
                                ).textTheme.labelSmall?.copyWith(
                                  color: Theme.of(context).colorScheme.primary,
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
