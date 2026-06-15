import Flutter
import UIKit
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Forwards the VoiceOver magic tap to Dart, which toggles play/pause.
  /// Flutter exposes no magic-tap API, so the gesture is caught in the
  /// responder chain (see accessibilityPerformMagicTap). Held here so the
  /// override can reach it.
  private var magicTapChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    WorkmanagerPlugin.registerPeriodicTask(withIdentifier: "media.payown.earshot.refreshFeeds", frequency: nil)
    WorkmanagerPlugin.registerBGProcessingTask(withIdentifier: "media.payown.earshot.downloadEpisodes")
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ChapterChannel") else { return }
    ChapterChannel.register(with: registrar.messenger())

    guard let airplayRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "AirPlayButton") else { return }
    airplayRegistrar.register(
      AirPlayButtonFactory(),
      withId: "media.payown.earshot/airplay_button"
    )

    if let magicTapRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "MagicTapChannel") {
      magicTapChannel = FlutterMethodChannel(
        name: "media.payown.earshot/magic_tap",
        binaryMessenger: magicTapRegistrar.messenger()
      )
    }
  }

  /// VoiceOver "magic tap" (two-finger double-tap). Flutter has no hook for it,
  /// so AppDelegate — the last responder in the chain — catches it and asks
  /// Dart to toggle play/pause from anywhere in the app. Always claim the
  /// gesture: there is no useful system default for a podcast play/pause to
  /// fall through to, and Dart announces "Nothing playing" when idle.
  override func accessibilityPerformMagicTap() -> Bool {
    magicTapChannel?.invokeMethod("performMagicTap", arguments: nil)
    return true
  }
}
