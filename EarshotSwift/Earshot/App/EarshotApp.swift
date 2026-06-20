import SwiftUI
import SwiftData

@main
struct EarshotApp: App {
    @State private var player = PlayerService()
    @State private var quickActions = QuickActionStore()
    @State private var downloads = DownloadManager()
    @State private var settings = SettingsStore()
    @State private var tips = TipsStore()
    private let container: ModelContainer

    /// True when the process is hosting an XCTest run. Unit tests use the app as
    /// their test host; rendering the real SwiftUI tree (with `@Query` observing
    /// the model graph) inside the test process races with the tests' own
    /// SwiftData work. During tests we keep the host inert.
    private let isRunningTests = NSClassFromString("XCTestCase") != nil

    init() {
        if NSClassFromString("XCTestCase") != nil {
            container = ModelContainerFactory.makeTestHostPlaceholder()
        } else {
            container = ModelContainerFactory.makeShared()
        }
    }

    var body: some Scene {
        WindowGroup {
            if isRunningTests {
                Color.clear
            } else {
                RootView()
                    .environment(player)
                    .environment(quickActions)
                    .environment(downloads)
                    .environment(settings)
                    .environment(tips)
            }
        }
        .modelContainer(container)
    }
}
