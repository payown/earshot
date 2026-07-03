import SwiftUI

/// Settings → Accessibility. Extracted from the former single Settings form.
/// Direct-touch turns the playback area into a direct-manipulation surface so
/// VoiceOver users can scrub without the double-tap intercepting the gesture.
struct AccessibilitySettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Accessibility") {
                Toggle("Direct-touch playback area", isOn: $settings.directTouchEnabled)
            }
        }
        .navigationTitle("Accessibility")
    }
}
