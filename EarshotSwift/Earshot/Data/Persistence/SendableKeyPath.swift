import Foundation

/// Wraps a key path so it satisfies the `KeyPath & Sendable` requirement that
/// `SortDescriptor.init` and `@Query(sort:)` impose under strict concurrency.
///
/// SwiftData `@Model` classes are reference types bound to a `ModelContext` and
/// are deliberately **not** `Sendable`. A key-path literal into one — e.g.
/// `\PodcastFolder.sortOrder` — is therefore typed `KeyPath<PodcastFolder, Int>`
/// without `Sendable`, so passing it straight to `SortDescriptor(_:order:)`
/// produces "type 'KeyPath<…>' does not conform to 'Sendable'" under
/// `SWIFT_STRICT_CONCURRENCY: complete` (issue #357).
///
/// A key path that addresses a stored property carries no mutable state and is
/// safe to share across isolation domains, which is exactly why the standard
/// library is moving toward treating such literals as implicitly `Sendable`.
/// Until the toolchain does that automatically, this helper makes the guarantee
/// explicit. The key-path literal is formed inside this generic function (where
/// the parameter type is a plain `KeyPath`, so no `Sendable` check applies at
/// the call site) and then re-typed via `unsafeBitCast` — a layout-preserving
/// no-op, since the witness adds no storage.
///
/// - Precondition: Use this **only** for key paths that address a stored
///   property (e.g. `\PodcastFolder.sortOrder`). Do not pass a key path that
///   captures subscript arguments or other non-`Sendable` state — the cast
///   would then launder a genuine data race past the compiler.
@inline(__always)
func sendableKeyPath<Root, Value>(
    _ keyPath: KeyPath<Root, Value>
) -> any KeyPath<Root, Value> & Sendable {
    unsafeBitCast(keyPath, to: (any KeyPath<Root, Value> & Sendable).self)
}
