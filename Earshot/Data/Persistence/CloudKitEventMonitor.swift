import CoreData
import Foundation
import OSLog
import Observation

extension Notification.Name {
    /// A completed, successful CloudKit import may change rows held by views
    /// that deliberately use bounded fetches instead of live `@Query` results.
    static let earshotCloudKitImportDidFinish = Notification.Name(
        "earshotCloudKitImportDidFinish"
    )
}

/// A bounded diagnostic view of the public Core Data + CloudKit event stream.
///
/// SwiftData does not expose a supported "last synced" timestamp. Its backing
/// Core Data stack may publish setup/import/export events, which are useful for
/// development measurement but do not prove that every record has converged.
/// This observer is event-driven, performs no polling, and is not started by the
/// production app during the B1 feasibility phase.
struct CloudKitEventSnapshot: Equatable, Sendable {
    enum Kind: String, Sendable {
        case setup
        case `import`
        case export
    }

    let identifier: UUID
    let storeIdentifier: String
    let kind: Kind
    let startDate: Date
    let endDate: Date?
    let succeeded: Bool
    let errorDescription: String?

    init?(event: NSPersistentCloudKitContainer.Event) {
        let kind: Kind
        switch event.type {
        case .setup:
            kind = .setup
        case .import:
            kind = .import
        case .export:
            kind = .export
        @unknown default:
            return nil
        }
        self.init(
            identifier: event.identifier as UUID,
            storeIdentifier: event.storeIdentifier,
            kind: kind,
            startDate: event.startDate,
            endDate: event.endDate,
            succeeded: event.succeeded,
            errorDescription: event.error?.localizedDescription
        )
    }

    init(
        identifier: UUID,
        storeIdentifier: String,
        kind: Kind,
        startDate: Date,
        endDate: Date?,
        succeeded: Bool,
        errorDescription: String?
    ) {
        self.identifier = identifier
        self.storeIdentifier = storeIdentifier
        self.kind = kind
        self.startDate = startDate
        self.endDate = endDate
        self.succeeded = succeeded
        self.errorDescription = errorDescription
    }
}

@MainActor
@Observable
final class CloudKitEventMonitor {
    static let defaultCapacity = 100

    private(set) var events: [CloudKitEventSnapshot] = []

    var latestEvent: CloudKitEventSnapshot? { events.last }
    private let capacity: Int
    private let center: NotificationCenter
    private var observer: NSObjectProtocol?

    init(
        capacity: Int = defaultCapacity,
        center: NotificationCenter = .default
    ) {
        self.capacity = max(1, capacity)
        self.center = center
    }

    func start() {
        guard observer == nil else { return }
        observer = center.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[
                NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            ] as? NSPersistentCloudKitContainer.Event,
                  let snapshot = CloudKitEventSnapshot(event: event) else { return }
            MainActor.assumeIsolated {
                self?.record(snapshot)
            }
        }
    }

    func stop() {
        if let observer {
            center.removeObserver(observer)
            self.observer = nil
        }
    }

    func record(_ event: CloudKitEventSnapshot) {
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        let duration = event.endDate.map { $0.timeIntervalSince(event.startDate) } ?? -1
        let errorDescription = event.errorDescription ?? "none"
        AppLog.data.info(
            "CloudKit event kind=\(event.kind.rawValue, privacy: .public) succeeded=\(event.succeeded, privacy: .public) durationSeconds=\(duration, privacy: .public) error=\(errorDescription, privacy: .public)"
        )
        if event.kind == .import, event.endDate != nil, event.succeeded {
            center.post(name: .earshotCloudKitImportDidFinish, object: nil)
        }
    }

}
