import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack {
                SubscriptionsView()
            }
            .tabItem { Label("Podcasts", systemImage: "music.note.list") }

            NavigationStack {
                QuickActionsSettingsView()
            }
            .tabItem { Label("Actions", systemImage: "slider.horizontal.3") }
        }
        .safeAreaInset(edge: .bottom) {
            NowPlayingBar()
        }
    }
}
