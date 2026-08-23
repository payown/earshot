import Foundation

struct StoreWALSnapshot: Sendable, Equatable {
    let primaryBytes: Int64
    let localBytes: Int64

    var totalBytes: Int64 { primaryBytes + localBytes }
}

/// Telemetry-free, read-only WAL measurements for #711. This deliberately uses
/// FileManager metadata only: it never opens SQLite, checkpoints a live store,
/// or deletes a sidecar owned by SwiftData.
enum StoreWALDiagnostics {
    enum Event: String, Sendable {
        case beforeStoreOpen = "before-store-open"
        case beforeFullRefresh = "before-full-refresh"
        case afterFullRefresh = "after-full-refresh"
        case appBackground = "app-background"
    }

    static func snapshot(
        at storeURL: URL,
        fileManager: FileManager = .default
    ) -> StoreWALSnapshot {
        let urls = walURLs(for: storeURL)
        return StoreWALSnapshot(
            primaryBytes: fileSize(at: urls.primary, fileManager: fileManager),
            localBytes: fileSize(at: urls.local, fileManager: fileManager)
        )
    }

    static func log(
        _ event: Event,
        at storeURL: URL = ModelContainerFactory.storeURL,
        elapsed: Duration? = nil
    ) {
        let sample = snapshot(at: storeURL)
        if let elapsed {
            AppLog.data.info(
                "WAL sample event=\(event.rawValue, privacy: .public) primaryBytes=\(sample.primaryBytes) localBytes=\(sample.localBytes) totalBytes=\(sample.totalBytes) elapsedMilliseconds=\(milliseconds(elapsed)) (#711)"
            )
        } else {
            AppLog.data.info(
                "WAL sample event=\(event.rawValue, privacy: .public) primaryBytes=\(sample.primaryBytes) localBytes=\(sample.localBytes) totalBytes=\(sample.totalBytes) (#711)"
            )
        }
    }

    static func walURLs(for storeURL: URL) -> (primary: URL, local: URL) {
        (
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: StoreMigration.localStoreURL(for: storeURL).path + "-wal")
        )
    }

    private static func fileSize(at url: URL, fileManager: FileManager) -> Int64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
    }
}
