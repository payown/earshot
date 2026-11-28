import SwiftUI
import UniformTypeIdentifiers

struct ListeningPlacesSettingsView: View {
    @Environment(ListeningPlacesService.self) private var service
    @Environment(PlayerService.self) private var player
    @State private var choosingFolder = false
    @State private var selectionError: String?
    @State private var confirmingRemoval = false

    var body: some View {
        Form {
            #if DEBUG
            if ScreenshotHarness.isListeningPlacesPlaybackDemo {
                ListeningPlacesPlaybackDemoControls()
            }
            #endif
            Section {
                #if DEBUG
                if ScreenshotHarness.isListeningPlacesPlaybackDemo {
                    Text("Disposable Playback test: this Debug screen imports synthetic peer positions. The regular Receiving switch separately controls public podcast playback imports.")
                } else {
                    Text("Listening Places can share this device's episode positions and played state with a folder you choose. Receiving playback places is a separate choice. Follows and folders are not exchanged.")
                }
                #else
                Text("Listening Places can share this device's episode positions and played state with a folder you choose. Receiving playback places is a separate choice. Follows and folders are not exchanged.")
                #endif
                Text("iCloud Sync separately syncs your Earshot library and listening progress between your devices through your private iCloud account. Listening Places does not require iCloud Sync or an Earshot account.")
            }

            Section("Folder") {
                LabeledContent("Selected folder", value: service.folderName ?? "None")

                Button(service.folderName == nil ? "Choose Folder" : "Choose a Different Folder") {
                    choosingFolder = true
                }
                #if DEBUG
                .disabled(ScreenshotHarness.isListeningPlacesPlaybackDemo
                    && service.isSharingStopPendingForTesting)
                #endif
                .accessibilityHint("Opens the folder picker. Earshot creates a Listening Places folder inside your selection.")
            }

            Section {
                Toggle("Share listening places", isOn: Binding(
                    get: { service.enabled },
                    set: { value in Task { await service.setEnabled(value) } }
                ))
                .disabled(service.folderName == nil)
                #if DEBUG
                .disabled(ScreenshotHarness.isListeningPlacesPlaybackDemo
                    && service.isSharingStopPendingForTesting)
                #endif
                .accessibilityHint("Writes this device's episode positions and played state to the selected folder")

                Toggle("Include podcast and episode names", isOn: Binding(
                    get: { service.includeLabels },
                    set: { value in Task { await service.setIncludeLabels(value) } }
                ))
                .disabled(!service.enabled)
                .accessibilityHint("Off keeps readable podcast and episode names out of the shared file")
            } header: {
                Text("Sharing")
            } footer: {
                Text("Names are off by default. Episode identifiers are shortened hashes. Earshot does not include feed URLs.")
            }

            Section {
                Toggle("Receive playback places", isOn: Binding(
                    get: { service.receivePlaybackEnabled },
                    set: { service.setReceivePlaybackEnabled($0) }
                ))
                .disabled(service.folderName == nil)
                .accessibilityHint("Reads eligible public podcast playback places from other device files when you choose Sync Playback Now. Does not import follows or folders.")

                Button("Sync Playback Now") {
                    Task {
                        await service.syncPlaybackNow(
                            loadedEpisodeID: { player.nowPlayingEpisode?.persistentModelID }
                        )
                    }
                }
                .disabled(!service.receivePlaybackEnabled || service.isReceivingPlayback)

                Text(service.receivePlaybackStatus)
                    .accessibilityLabel("Receiving status: \(service.receivePlaybackStatus)")
            } header: {
                Text("Receiving")
            } footer: {
                Text("Only podcasts verified as public and allowed on this device are eligible. A loaded episode waits until you leave it. Your folder provider may need time to download new files.")
            }

            Section("Status") {
                Text(statusText)
                    .accessibilityLabel("Listening Places status: \(statusText)")

                #if DEBUG
                if ScreenshotHarness.isListeningPlacesPlaybackDemo,
                   service.isSharingStopPendingForTesting {
                    Button("Retry disposable cleanup") {
                        Task { await service.setEnabled(false) }
                    }
                    .accessibilityHint("Retries cleanup of only this Debug fixture's owned file")
                }
                #endif

                Button("Write Now") {
                    Task { await service.writeNow() }
                }
                .disabled(!service.enabled || service.status == .writing)
                .accessibilityHint("Writes the latest listening positions to the selected folder")

                if service.folderName != nil {
                    Button("Stop Sharing and Remove This Device", role: .destructive) {
                        confirmingRemoval = true
                    }
                    #if DEBUG
                    .disabled(ScreenshotHarness.isListeningPlacesPlaybackDemo
                        && service.isSharingStopPendingForTesting)
                    #endif
                    .accessibilityHint("Removes only this device's Listening Places file and forgets the selected folder")
                }
            }
        }
        .navigationTitle("Listening Places")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $choosingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await service.chooseFolder(url, enableSharing: service.enabled) }
            case .failure(let error):
                selectionError = error.localizedDescription
            }
        }
        .alert("Could Not Choose Folder", isPresented: Binding(
            get: { selectionError != nil },
            set: { if !$0 { selectionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(selectionError ?? "Choose a folder and try again.")
        }
        .confirmationDialog(
            "Stop sharing listening places?",
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Stop Sharing and Remove This Device", role: .destructive) {
                Task { await service.stopSharingAndRemoveDeviceFile() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Earshot will remove only this device's JSON file. Your listening progress stays in Earshot, and other devices' files are not changed.")
        }
    }

    private var statusText: String {
        switch service.status {
        case .notConfigured: "Choose a folder to begin."
        case .off: "Sharing is off."
        case .ready: "Ready. No listening changes need to be written."
        case .writing:
            #if DEBUG
            if ScreenshotHarness.isListeningPlacesPlaybackDemo,
               service.isSharingStopPendingForTesting {
                "Stopping disposable sharing. Owned-file cleanup is pending."
            } else {
                "Writing listening places."
            }
            #else
            "Writing listening places."
            #endif
        case .lastWritten(let date): "Last written \(date.formatted(date: .abbreviated, time: .shortened))."
        case .failed(let message):
            #if DEBUG
            if ScreenshotHarness.isListeningPlacesPlaybackDemo,
               service.isSharingStopPendingForTesting {
                "Could not finish disposable cleanup. Retry cleanup; if the synthetic file changed, repair it first."
            } else {
                "Could not write listening places. \(message)"
            }
            #else
            "Could not write listening places. \(message)"
            #endif
        }
    }
}
