import Foundation

/// Identifiable wrapper so an exported local-file URL can drive a `.sheet(item:)`
/// presenting the system share sheet. Shared by the Now Playing "Export audio
/// file" action and the per-row "Export audio" Quick Action (#371, #689).
struct ExportFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
