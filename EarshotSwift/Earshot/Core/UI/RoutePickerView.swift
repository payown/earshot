import SwiftUI
import AVKit

/// Wraps `AVRoutePickerView` (the system AirPlay / output-device picker) as a
/// SwiftUI view. Tapping the icon presents the system route picker sheet.
///
/// Tint color is driven by `Color.accentColor` so it matches the app's primary
/// color token. The system renders the standard route-picker icon and handles
/// all picker interaction internally — no additional gesture recognizers needed.
struct RoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = UIColor(Color.accentColor)
        picker.activeTintColor = UIColor.systemBlue
        // The system accessibility label for AVRoutePickerView reads
        // "AirPlay" by default; we reinforce it so VoiceOver always
        // announces the correct name regardless of locale fallback.
        picker.isAccessibilityElement = true
        picker.accessibilityLabel = "AirPlay"
        picker.accessibilityHint = "Choose audio output device"
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        // Tint may change when the color scheme changes — keep it in sync.
        uiView.tintColor = UIColor(Color.accentColor)
        uiView.activeTintColor = UIColor.systemBlue
    }
}
