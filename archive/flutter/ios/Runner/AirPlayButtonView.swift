import AVKit
import Flutter
import UIKit

/// Wraps `AVRoutePickerView` so it can be embedded in the Flutter UI as an
/// in-app AirPlay output picker. `AVRoutePickerView` owns its own
/// accessibility node (VoiceOver announces "AirPlay") and tap handling, so
/// it must not be wrapped in any additional Flutter `Semantics`/gesture
/// widgets on the Dart side.
class AirPlayButtonPlatformView: NSObject, FlutterPlatformView {
    private let routePickerView: AVRoutePickerView

    init(frame: CGRect) {
        routePickerView = AVRoutePickerView(frame: frame)
        routePickerView.tintColor = .label
        routePickerView.activeTintColor = .systemBlue
        routePickerView.prioritizesVideoDevices = false
        routePickerView.accessibilityLabel = "AirPlay"
        super.init()
    }

    func view() -> UIView {
        routePickerView
    }
}

class AirPlayButtonFactory: NSObject, FlutterPlatformViewFactory {
    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        AirPlayButtonPlatformView(frame: frame)
    }
}
