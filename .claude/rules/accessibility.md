# Accessibility rules

These rules apply to every UI change in Earshot. Earshot exists to serve screen reader users; accessibility is the highest priority.

## Mandatory for every widget

1. **Every interactive widget has accessible labels.**
   - Use `Semantics(label: ..., button: true, ...)` or built-in widget semantics (e.g., `IconButton(tooltip: ...)`).
   - If a widget shows only an icon, the icon's purpose must be in the semantic label.
   - For images: `Image.asset(..., semanticLabel: ...)`. Decorative images use `excludeSemantics: true`.

2. **Touch targets meet minimum size.**
   - 48x48 dp on Android, 44x44 pt on iOS.
   - Use `InkWell` or `GestureDetector` with adequate padding rather than tiny tap zones.

3. **Color is never the only signal.**
   - Played state: icon + "Played" label + color.
   - Error state: error icon + error text + color.
   - Selected state: visible indicator + announced "Selected".

4. **Text scales with Dynamic Type.**
   - Use `Theme.of(context).textTheme.bodyLarge` (or appropriate style), never `TextStyle(fontSize: 14)`.
   - Test at largest accessibility size; nothing should clip or be cut off.

5. **Focus order matches visual order.**
   - Default Flutter focus order is usually correct. Override with `FocusTraversalOrder` only when necessary, and document why.

6. **Reduce Motion is respected.**
   - Check `MediaQuery.of(context).disableAnimations` before any non-essential animation.
   - When true, use instant transitions.

## Quick Actions implementation

Quick Actions map to VoiceOver actions rotor (iOS) and TalkBack custom actions (Android).

Use `customSemanticsActions` on the widget:

```dart
Semantics(
  label: episode.title,
  customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
    const CustomSemanticsAction(label: 'Play now'): () => _playNow(episode),
    const CustomSemanticsAction(label: 'Add to queue'): () => _addToQueue(episode),
    const CustomSemanticsAction(label: 'Open show notes'): () => _openNotes(episode),
  },
  child: ...,
)
```

The user's Quick Action order must be respected. The first Quick Action in the user's settings becomes the default activation (`onTap`).

## Status announcements

Use `SemanticsService.announce(message, textDirection)` for important state changes:

- "Episode added to queue, position 3 of 7"
- "Playing"
- "Speed changed to 1.5x"
- "Sleep timer extended by 5 minutes"

Don't announce noise. Reserve announcements for changes the user must know about.

## Testing requirements

Every new screen needs:

- A widget test that checks semantic labels are present
- A manual screen reader test note in the PR description ("Tested with VoiceOver on iOS 17 simulator, all actions reachable")

When in doubt, test with VoiceOver or TalkBack physically before merging.

## Patterns to avoid

- `Tooltip` as the only label (not all screen readers announce tooltips reliably)
- Nested `GestureDetector` with no semantic role
- `Visibility(visible: false)` for elements that should remain in tree but inaccessible (use `ExcludeSemantics` or remove from tree)
- Custom gesture-based controls without alternative button-based access
- Reading text aloud via TTS yourself; let the system screen reader handle it

## Modal bottom sheets

Always set `barrierLabel` so VoiceOver doesn't announce the scrim as "scrim":

```dart
showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  barrierLabel: 'Dismiss folder picker',  // required
  builder: (_) => MySheet(),
);
```

Never put `Focus(autofocus: true)` on the sheet's root container widget. VoiceOver treats any `Focus`-wrapped container as a group and reads a merged summary of all children on entry ("Add to Folder, Done, heading"). `barrierLabel` is sufficient to route VoiceOver past the scrim.

## Overriding built-in widget semantics

**Trust the widget first.** `CheckboxListTile`, `Switch`, `Slider`, `IconButton`, `ListTile` all produce correct semantics. Override only when the default label is wrong.

**When you DO override with an outer `Semantics` node:**

```dart
// CORRECT — exclude the whole interactive widget so only the outer node exists
Semantics(
  button: true,
  label: 'Done',
  hint: 'Save changes and close',
  child: ExcludeSemantics(       // wrap the entire FilledButton
    child: FilledButton(
      onPressed: onDone,
      child: const Text('Done'), // Text does NOT need ExcludeSemantics here
    ),
  ),
),
```

```dart
// WRONG — ExcludeSemantics only on the Text leaves FilledButton creating its
// own unnamed button node alongside the outer Semantics node
Semantics(
  button: true,
  label: 'Done',
  child: FilledButton(
    onPressed: onDone,
    child: const ExcludeSemantics(child: Text('Done')),  // ❌
  ),
),
```

**Never do this to a checkbox/toggle widget:**

```dart
// WRONG — ExcludeSemantics strips the gesture recognizer; iOS marks the node
// "dimmed". Semantics(checked:) without a proper type maps to "switch button".
Semantics(
  checked: value,
  onTap: () => onToggle(!value),
  child: ExcludeSemantics(child: CheckboxListTile(...)),  // ❌
),

// CORRECT — let CheckboxListTile own its semantics
CheckboxListTile(
  value: value,
  onChanged: (v) => onToggle(v ?? false),
  title: Text(label),
  secondary: const ExcludeSemantics(child: Icon(Icons.folder_outlined)),
),
```

## Sheet headings

`Semantics(header: true)` without an explicit `label:` derives its label from the child widget, creating two nodes with the same text (the `Semantics` node and the `Text` node). Always write:

```dart
Semantics(
  header: true,
  label: title,                      // explicit label
  child: ExcludeSemantics(           // prevent child Text from making a 2nd node
    child: Text(title, style: ...),
  ),
),
```
