import Foundation
import UserNotifications

/// Minimal abstraction over the parts of `UNUserNotificationCenter` that
/// ``NotificationService`` uses. Lets tests substitute a mock so authorization
/// and delivery logic is verifiable without the real notification center (which
/// is unavailable / prompts in a unit-test host) (#72).
protocol NotificationScheduling: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) async
    func add(_ request: UNNotificationRequest) async throws
}

/// Production adapter backed by the real `UNUserNotificationCenter`.
struct SystemNotificationCenter: NotificationScheduling {
    private var center: UNUserNotificationCenter { .current() }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) async {
        center.setNotificationCategories(categories)
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }
}
