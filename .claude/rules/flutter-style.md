# Flutter and Dart code style

## File and folder layout

- Feature-first folder structure: `lib/features/<feature_name>/`
- Each feature has three layers:
  - `data/` — repositories, models, data sources
  - `domain/` — entities, use cases (if needed), value objects
  - `presentation/` — widgets, screens, Riverpod providers
- Shared utilities in `lib/core/`
- Cross-feature data (database, network client) in `lib/data/`

## Widgets

- **Prefer `StatelessWidget`.** Use `StatefulWidget` only when you genuinely need local state.
- **Use `const` constructors everywhere possible.** This is a real performance win.
- **No business logic in `build()`.** No network calls, no DB calls, no heavy computation.
- **Split large widgets into smaller composable widgets.**
- Use `ListView.builder` for lists, never `Column` + `SingleChildScrollView` for long lists.

## State management

- **Riverpod is the only state management solution.**
- Use `StateNotifier` or `AsyncNotifier` (Riverpod v2) for mutable state.
- Use sealed/union types for async states. Never `isLoading` + `isError` + `data` as separate booleans.
- Providers are organized per feature: `lib/features/<feature>/presentation/providers/`
- Global providers (theme, settings, account) in `lib/core/providers/`

## Theming

- **Colors come from `Theme.of(context).colorScheme`.** Never `Colors.red` or hex literals.
- **Text styles come from `Theme.of(context).textTheme`.** Never inline `TextStyle(fontSize: ...)`.
- **Spacing tokens** are defined in `lib/core/theme/spacing.dart`. Use them, not magic numbers.
- Dark mode must work everywhere. Test in both modes before merging.

## Dependency injection

- Riverpod providers handle all DI.
- Constructor injection where Riverpod isn't applicable.
- Never construct dependencies inside business logic.
- Use abstract interfaces at layer boundaries (repository pattern).

## Logging

- Use `package:logging` with a project logger:
  ```dart
  final _log = Logger('FeatureName');
  _log.info('Subscribed to podcast: ${podcast.title}');
  ```
- **No `print()` statements in production code.** Allowed only in scripts in `tool/`.
- Log levels: `severe`, `warning`, `info`, `fine`. Use them honestly.

## Error handling

- Don't swallow exceptions silently.
- Wrap async operations that can fail in try/catch and surface user-friendly messages.
- Use `Result<T, E>` or sealed types for expected failure cases (e.g., network errors).

## Async

- `async`/`await` everywhere. No callback hell.
- Always handle the failure case of a `Future`.
- Cancel in-flight operations on widget dispose where appropriate.

## Constants and magic values

- Constants in `lib/core/constants/` or per-feature `constants.dart`.
- Magic numbers in code are forbidden. Even durations like `Duration(milliseconds: 300)` should reference a named constant if used more than once.

## Lints

- `analysis_options.yaml` includes `very_good_analysis`.
- No lint suppressions without an `// ignore: rule_name — reason` comment.
- CI fails on any lint warning.

## Imports

- Order: dart, flutter, packages, project (separated by blank lines).
- Use relative imports within a feature, absolute (`package:earshot/...`) across features.
- No `package:earshot/src/...` imports across packages (Dart encapsulation).

## Testing

- Every public API has unit tests.
- Every screen has widget tests including accessibility checks.
- Integration tests cover critical user flows.
- Test files mirror source structure: `test/features/<feature>/...`
- Use `mocktail` for mocks, not `mockito` (null-safety, simpler API).

## What to avoid

- `GlobalKey` unless absolutely necessary
- `UniqueKey()` in `build()` (forces rebuild every frame)
- Mixing concerns: a widget that fetches data, manages state, and renders UI
- Long files. Split when over ~300 lines.
- Premature abstraction. Add use-cases only when business logic is shared.
