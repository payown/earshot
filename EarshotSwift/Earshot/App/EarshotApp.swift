import SwiftUI
import SwiftData

@main
struct EarshotApp: App {
    @State private var player = PlayerService()
    @State private var quickActions = QuickActionStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(player)
                .environment(quickActions)
        }
        .modelContainer(for: [Podcast.self, Episode.self])
    }
}
