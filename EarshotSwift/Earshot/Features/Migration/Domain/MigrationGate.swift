import Foundation

/// Pure decision logic for the one-time Flutter→SwiftUI subscription import.
/// Kept free of SwiftData and UIKit so it is trivially unit-testable.
enum MigrationGate {
    /// Whether the one-time import should run on launch. It runs once, the first
    /// time the new build opens over an old install, and never again after it
    /// completes.
    static func shouldImport(migrationComplete: Bool) -> Bool {
        !migrationComplete
    }
}
