import SwiftUI

struct QuickActionsSettingsView: View {
    @Environment(QuickActionStore.self) private var store

    var body: some View {
        @Bindable var store = store
        List {
            Section {
                Text("The first action is the default double-tap. Reorder to set the order of the VoiceOver Actions rotor on every episode. Changes apply immediately.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Active actions") {
                ForEach(store.actions) { action in
                    Text(action.label)
                        .accessibilityLabel(action.label)
                }
                .onMove { from, to in
                    store.actions.move(fromOffsets: from, toOffset: to)
                }
            }
        }
        .navigationTitle("Quick Actions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
    }
}
