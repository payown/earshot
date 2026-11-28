import Foundation
import SwiftData

/// Device-local permission to apply peer playback places. A missing or
/// unfamiliar value is off, including stores upgraded from the write-only app.
@MainActor
enum ListeningPlacesPlaybackReceiveConsent {
    enum ConsentError: LocalizedError {
        case unsavedChanges

        var errorDescription: String? {
            "Listening changes are still saving. Try again."
        }
    }
    private static let key = "listening_places_receive_playback_v1"

    static func isEnabled(in context: ModelContext) -> Bool {
        LocalAppSettingIdentity.value(for: key, in: context) == "true"
    }

    static func stageEnabled(_ enabled: Bool, in context: ModelContext) throws {
        try LocalAppSettingIdentity.setValue(enabled ? "true" : "false", for: key, in: context)
    }

    static func setEnabled(_ enabled: Bool, in context: ModelContext) throws {
        // The Settings action must never commit or roll back an unrelated
        // unsaved playback or library mutation in the shared app context.
        guard !context.hasChanges else { throw ConsentError.unsavedChanges }
        do {
            try stageEnabled(enabled, in: context)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
