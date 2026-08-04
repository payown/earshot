import Foundation
import SwiftData

/// Generic key/value scalar settings store. Mirrors the Flutter drift
/// `app_settings` table. Typed access goes through ``AppSettingsStore``.
@Model
final class AppSetting {
    var key: String = ""
    var value: String = ""

    init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}
