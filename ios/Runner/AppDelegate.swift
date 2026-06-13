import Flutter
import UIKit
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
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
  }
}
