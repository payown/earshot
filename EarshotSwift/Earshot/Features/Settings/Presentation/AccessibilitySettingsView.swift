import SwiftUI

/// Settings → Accessibility. Extracted from the former single Settings form.
/// Direct-touch turns the playback area into a direct-manipulation surface so
/// VoiceOver users can scrub without the double-tap intercepting the gesture.
struct AccessibilitySettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            // No section header: the "Accessibility" navigation title already
            // names the screen, so a matching header would be a redundant
            // VoiceOver heading stop.
            Section {
                Toggle("Direct-touch playback area", isOn: $settings.directTouchEnabled)
            }
        }
        .navigationTitle("Accessibility")
    }
}
