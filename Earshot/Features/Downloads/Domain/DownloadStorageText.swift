import Foundation

enum DownloadStorageText {
    static func approximateSize(bytes: Int64) -> String? {
        guard bytes > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.includesCount = true
        formatter.isAdaptive = true
        formatter.zeroPadsFractionDigits = false
        return formatter.string(fromByteCount: bytes)
    }

    static func clearConfirmation(summary: DownloadStorageSummary) -> String {
        var clauses: [String] = []
        if summary.downloadedCount > 0 {
            clauses.append("This removes \(episodePhrase(summary.downloadedCount)) from this device")
        }
        if summary.activeCount > 0 {
            clauses.append(
                clauses.isEmpty
                    ? "This cancels \(activeDownloadPhrase(summary.activeCount))"
                    : "cancels \(activeDownloadPhrase(summary.activeCount))"
            )
        }
        if summary.downloadedCount > 0,
           let size = approximateSize(bytes: summary.allocatedBytes) {
            clauses.append("frees about \(size) of storage")
        }
        return joined(clauses) + ". This can't be undone."
    }

    static func storageFooter(summary: DownloadStorageSummary) -> String {
        guard summary.downloadedCount > 0 else {
            return summary.activeCount == 0
                ? "You have no downloaded episodes."
                : "You have \(activeDownloadPhrase(summary.activeCount))."
        }
        let count = episodePhrase(summary.downloadedCount)
        guard let size = approximateSize(bytes: summary.allocatedBytes) else {
            return "Removing \(count) frees device storage. This can't be undone."
        }
        return "\(count) use about \(size) on this device. Clearing them frees that storage. This can't be undone."
    }

    static func cancelConfirmation(activeCount: Int) -> String {
        "Stops \(activeDownloadPhrase(activeCount)). Completed downloads are kept."
    }

    private static func episodePhrase(_ count: Int) -> String {
        count == 1 ? "1 downloaded episode" : "\(count) downloaded episodes"
    }

    private static func activeDownloadPhrase(_ count: Int) -> String {
        count == 1 ? "1 active download" : "\(count) active downloads"
    }

    private static func joined(_ clauses: [String]) -> String {
        switch clauses.count {
        case 0: return ""
        case 1: return clauses[0]
        case 2: return clauses.joined(separator: " and ")
        default: return clauses.dropLast().joined(separator: ", ") + ", and " + clauses.last!
        }
    }
}
