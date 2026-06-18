import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

// Material 3 bottom-nav metrics, named rather than inlined per flutter-style.md.
const double _barVerticalPadding = 12;
const double _indicatorWidth = 64;
const double _indicatorHeight = 32;
const double _iconLabelGap = 4;
const double _minTapHeight = 48;
const double _barElevation = 3;

/// Above this the visible badge collapses to "99+"; the spoken label still
/// carries the exact count (e.g. "Inbox, 247 new").
const int _maxVisibleBadgeCount = 99;

/// One destination in an [AccessibleNavBar].
///
/// [label] is the visible text shown under the icon. [semanticLabel] is what
/// VoiceOver/TalkBack speaks; it defaults to [label] when null. They are kept
/// separate so the Inbox can show a numeric badge while announcing a clean
/// "Inbox, N new" (see #322) without the badge count being read twice.
class AccessibleNavDestination {
  const AccessibleNavDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.semanticLabel,
    this.badgeCount = 0,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final String? semanticLabel;
  final int badgeCount;
}

/// A bottom navigation bar that gives VoiceOver/TalkBack full, correct
/// semantics for each destination.
///
/// Material's [NavigationBar] merges a forced `button: true` trait and a
/// literal "Tab N of M" label into every destination from inside its own
/// `MergeSemantics` boundary, so the call site can't fix the announcement
/// (see #321). This bar owns the semantics directly: each destination is a
/// single [SemanticsRole.tab] node with `selected` state and one clean spoken
/// label, and the interactive child is wrapped in [ExcludeSemantics] so no
/// second, unlabeled node is created.
class AccessibleNavBar extends StatelessWidget {
  const AccessibleNavBar({
    required this.selectedIndex,
    required this.destinations,
    required this.onDestinationSelected,
    super.key,
  });

  final int selectedIndex;
  final List<AccessibleNavDestination> destinations;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      role: SemanticsRole.tabBar,
      container: true,
      explicitChildNodes: true,
      child: Material(
        // Match Material's NavigationBar default elevation so the bar keeps a
        // shadow and doesn't blend into surface-toned body content.
        elevation: _barElevation,
        color: colors.surfaceContainer,
        child: SafeArea(
          top: false,
          child: Padding(
            // No fixed height: the bar grows vertically with Dynamic Type so
            // taller text isn't clipped; a long label in a narrow cell wraps.
            padding: const EdgeInsets.symmetric(vertical: _barVerticalPadding),
            child: Row(
              children: [
                for (var i = 0; i < destinations.length; i++)
                  Expanded(
                    child: _NavItem(
                      destination: destinations[i],
                      selected: i == selectedIndex,
                      onTap: () => onDestinationSelected(i),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final AccessibleNavDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final spokenLabel = destination.semanticLabel ?? destination.label;
    final iconData = selected ? destination.selectedIcon : destination.icon;
    final iconColor = selected
        ? colors.onSecondaryContainer
        : colors.onSurfaceVariant;

    Widget icon = Icon(iconData, color: iconColor);
    if (destination.badgeCount > 0) {
      final badgeText = destination.badgeCount > _maxVisibleBadgeCount
          ? '$_maxVisibleBadgeCount+'
          : '${destination.badgeCount}';
      icon = Badge(label: Text(badgeText), child: icon);
    }

    return Semantics(
      // SemanticsRole.tab/tabBar are honored by Android TalkBack but are NOT
      // mapped to a UIKit trait by Flutter's iOS bridge (3.44), so iOS
      // VoiceOver speaks the label + selected state only — e.g. "Inbox, 3 new,
      // selected" — with no "button" and no injected "Tab N of M". That is the
      // #321 win; do not assume iOS literally announces "tab".
      role: SemanticsRole.tab,
      selected: selected,
      label: spokenLabel,
      button: false,
      onTap: onTap,
      // ExcludeSemantics on the whole interactive child keeps the outer tab
      // node as the only semantics stop. Nesting a tap widget inside an outer
      // Semantics otherwise creates a second, unlabeled VoiceOver stop.
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          // Guarantee at least a 48dp tappable height regardless of text size;
          // each item already fills its cell width via the parent Row/Expanded.
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: _minTapHeight),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Material 3 selection pill behind the selected icon.
                Container(
                  width: _indicatorWidth,
                  height: _indicatorHeight,
                  alignment: Alignment.center,
                  decoration: selected
                      ? ShapeDecoration(
                          color: colors.secondaryContainer,
                          shape: const StadiumBorder(),
                        )
                      : null,
                  child: icon,
                ),
                const SizedBox(height: _iconLabelGap),
                Text(
                  destination.label,
                  textAlign: TextAlign.center,
                  style: textTheme.labelMedium?.copyWith(
                    color: selected
                        ? colors.onSurface
                        : colors.onSurfaceVariant,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
