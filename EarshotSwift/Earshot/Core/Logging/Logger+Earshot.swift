import os

/// Centralized `os.Logger` factory for Earshot. No `print()` anywhere in the
/// app — use these per-feature loggers so output is filterable by category in
/// Console.app and Instruments.
enum AppLog {
    /// The app's logging subsystem, matching the bundle identifier.
    static let subsystem = "media.payown.earshot.swift"

    static let player = Logger(subsystem: subsystem, category: "player")
    static let subscriptions = Logger(subsystem: subsystem, category: "subscriptions")
    static let quickActions = Logger(subsystem: subsystem, category: "quick-actions")
    static let data = Logger(subsystem: subsystem, category: "data")
    static let networking = Logger(subsystem: subsystem, category: "networking")
    static let notifications = Logger(subsystem: subsystem, category: "notifications")
}
