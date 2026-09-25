import SwiftData

/// First-paint preferences belong to this root's lifetime. Avoid repeated store
/// fetches while startup awaits services; live settings still drive later edits.
@MainActor
final class RootLaunchPreferences {
    struct Snapshot {
        let tab: RootTab
        let theme: ThemeOverride
        let accent: AccentChoice
        let density: LayoutDensity
    }
    private weak var container: ModelContainer?
    private var snapshot: Snapshot?

    func value(in context: ModelContext) -> Snapshot {
        if container === context.container, let snapshot { return snapshot }
        let store = AppSettingsStore(context: context)
        let value = Snapshot(tab: RootTab(launchScreen: store.launchScreen()),
                             theme: store.themeOverride(), accent: store.accentChoice(),
                             density: store.layoutDensity())
        container = context.container
        snapshot = value
        return value
    }
}
