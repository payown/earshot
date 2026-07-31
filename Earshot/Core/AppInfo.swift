import Foundation

/// App identity values read from the main bundle's Info.plist.
///
/// Centralizes `CFBundleShortVersionString` / `CFBundleVersion` reading so the
/// About screen, Send Feedback, and any future caller share one source of truth
/// and one fallback ("unknown") for the rare case the keys are missing.
enum AppInfo {
    /// Marketing version, e.g. "0.1.0". Falls back to "unknown" if absent.
    static var version: String {
        version(from: .main)
    }

    /// Build number, e.g. "113". Falls back to "unknown" if absent.
    static var build: String {
        build(from: .main)
    }

    /// Combined display string, e.g. "Version 0.1.0 (113)".
    static var versionString: String {
        versionString(version: version, build: build)
    }

    // MARK: Testable internals

    /// Reads the marketing version from an arbitrary bundle. Used by tests.
    static func version(from bundle: Bundle) -> String {
        string(bundle, "CFBundleShortVersionString")
    }

    /// Reads the build number from an arbitrary bundle. Used by tests.
    static func build(from bundle: Bundle) -> String {
        string(bundle, "CFBundleVersion")
    }

    /// Formats a version + build pair into the user-facing string. Pure function
    /// so it can be unit-tested without a bundle.
    static func versionString(version: String, build: String) -> String {
        "Version \(version) (\(build))"
    }

    private static func string(_ bundle: Bundle, _ key: String) -> String {
        bundle.object(forInfoDictionaryKey: key) as? String ?? "unknown"
    }
}
