import SwiftUI

struct CloudSyncSettingsView: View {
    @Environment(AppRuntime.self) private var runtime

    var body: some View {
        Form {
            Section("iCloud Sync") {
                LabeledContent("Status", value: statusText)
                Text(statusExplanation)
            }

            Section("What syncs") {
                Text("Podcasts you follow, playback progress, played status, queue order, folders, bookmarks, listening history, and shared preferences sync automatically.")
                Text("Downloaded audio, cached artwork, purchase entitlement records, and download preferences stay on this device.")
            }

            Section("Timing") {
                Text("Earshot syncs automatically when iCloud is available. A completed event means this device finished its current work; it does not prove that every other device has received the changes yet.")
            }
        }
        .navigationTitle("iCloud Sync")
    }

    private var statusText: String {
        CloudSyncStatusPresentation.status(
            availability: runtime.cloudSyncAvailability,
            event: runtime.cloudKitEventMonitor?.latestEvent
        )
    }

    private var statusExplanation: String {
        CloudSyncStatusPresentation.explanation(
            availability: runtime.cloudSyncAvailability,
            event: runtime.cloudKitEventMonitor?.latestEvent
        )
    }
}

enum CloudSyncStatusPresentation {
    static func status(
        availability: CloudSyncAvailability,
        event: CloudKitEventSnapshot?
    ) -> String {
        switch availability {
        case .disabled: return "Unavailable in this build"
        case .checking: return "Checking iCloud"
        case .signedOut: return "Signed out"
        case .restricted: return "Restricted"
        case .temporarilyUnavailable: return "Temporarily unavailable"
        case .accountChanged: return "Paused after account change"
        case .available:
            guard let event else {
                return "Available"
            }
            if event.endDate == nil { return "Syncing" }
            return event.succeeded ? "Available" : "Needs attention"
        }
    }

    static func explanation(
        availability: CloudSyncAvailability,
        event: CloudKitEventSnapshot?
    ) -> String {
        switch availability {
        case .disabled:
            return "This build does not have iCloud synchronization enabled."
        case .checking:
            return "Earshot is checking whether this device can use your private iCloud database."
        case .signedOut:
            return "Sign in to iCloud in System Settings to synchronize Earshot. Your local library remains available."
        case .restricted:
            return "This device currently restricts Earshot from using iCloud. Your local library remains available."
        case .temporarilyUnavailable:
            return "iCloud could not be reached. Earshot will keep your local changes and try again later."
        case .accountChanged:
            return "Synchronization is paused so a different iCloud account cannot silently merge with this library. Your local library has not been deleted."
        case .available:
            if let event, event.endDate != nil, !event.succeeded {
                return "The most recent iCloud operation failed. Your local changes remain saved and Earshot will try again."
            } else {
                return "Earshot can use your private iCloud database and synchronizes automatically."
            }
        }
    }
}
