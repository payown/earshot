import SwiftUI
import UniformTypeIdentifiers

struct ListeningPlacesSettingsView: View {
    @Environment(ListeningPlacesService.self) private var service
    @State private var choosingFolder = false
    @State private var selectionError: String?
    @State private var confirmingRemoval = false

    var body: some View {
        Form {
            Section {
                Text("Share listening positions and played state through a folder you already sync. Earshot does not create an account or send this data to an Earshot server.")
                Text("Earshot 1.2.0 writes outward only. It does not import another device's changes yet.")
            }

            Section("Folder") {
                LabeledContent("Selected folder", value: service.folderName ?? "None")

                Button(service.folderName == nil ? "Choose Folder" : "Choose a Different Folder") {
                    choosingFolder = true
                }
                .accessibilityHint("Opens the folder picker. Earshot creates a Listening Places folder inside your selection.")
            }

            Section {
                Toggle("Share listening places", isOn: Binding(
                    get: { service.enabled },
                    set: { value in Task { await service.setEnabled(value) } }
                ))
                .disabled(service.folderName == nil)
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

            Section("Status") {
                Text(statusText)
                    .accessibilityLabel("Listening Places status: \(statusText)")

                Button("Write Now") {
                    Task { await service.writeNow() }
                }
                .disabled(!service.enabled || service.status == .writing)
                .accessibilityHint("Writes the latest listening positions to the selected folder")

                if service.folderName != nil {
                    Button("Stop Sharing and Remove This Device", role: .destructive) {
                        confirmingRemoval = true
                    }
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
                Task { await service.chooseFolder(url) }
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
        case .writing: "Writing listening places."
        case .lastWritten(let date): "Last written \(date.formatted(date: .abbreviated, time: .shortened))."
        case .failed(let message): "Could not write listening places. \(message)"
        }
    }
}
