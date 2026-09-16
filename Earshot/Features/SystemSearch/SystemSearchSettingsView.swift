import SwiftUI

struct SystemSearchSettingsView: View {
    @AppStorage(LibrarySearchIndex.enabledKey) private var enabled = false
    @AppStorage(ListeningDonations.enabledKey) private var listeningEnabled = false
    var body: some View {
        Form {
            Section {
                Toggle("Include library in Siri and Search", isOn: $enabled)
            } footer: {
                Text("Allow Earshot to share podcast and episode titles and descriptions with system search on this device, including content from private subscriptions. Audio, transcripts, bookmark notes, and feed addresses are not included. Turning this off removes Earshot’s search entries.")
            }
            if #available(iOS 27.0, *) {
                Section {
                    Toggle("Suggest episodes I choose to play", isOn: $listeningEnabled)
                        .disabled(!enabled)
                } footer: {
                    Text("Allow Earshot to tell Siri when an episode you select in Earshot starts playing, including private subscriptions. Automatic playback and actions started by Siri are not donated again. Turning this off removes Earshot’s donated listening actions.")
                }
            }
            Section {
                Text(LibrarySearchIndex.shared.status)
            } footer: {
                Text("Search includes a limited selection of recent, queued, downloaded, bookmarked, and unfinished episodes. Opening a result shows its notes without starting playback. Siri’s available features depend on your device and system version.")
            }
        }
        .navigationTitle("Siri and Search")
        .onChange(of: enabled) { LibrarySearchIndex.shared.requestRefresh() }
        .onChange(of: listeningEnabled) { LibrarySearchIndex.shared.requestRefresh() }
    }
}
