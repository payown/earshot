import CoreFoundation
import Foundation

/// A defensive, read-only view of another device's file. File discovery,
/// ownership, merge order, and user-state mutation belong to separate layers.
struct ListeningPlacesInboundFile: Sendable {
    /// Self-reported metadata. The file reader must compare this with the
    /// coordinated filename and exclude this device's own ID.
    let deviceID: String
    /// Self-reported, untrusted text. A UI caller must sanitize and bound it
    /// before displaying or announcing it.
    let deviceLabel: String?
    let app: String
    let writtenAt: Date
    let entries: [ListeningPlacesInboundEntry]
    let skippedMalformedRowCount: Int
    let skippedUnsupportedRowCount: Int
    let skippedOverLimitRowCount: Int
    let futureClockCorrectionCount: Int
    let isStale: Bool
}

struct ListeningPlacesInboundEntry: Sendable {
    /// `record.updatedAt` is kept as the source wrote it. Comparisons use the
    /// guarded effective time, so a wrong future clock cannot win forever.
    let record: ListeningPlaceRecord
    let effectiveUpdatedAt: Date
}

enum ListeningPlacesInboundParseError: Error, Equatable {
    case tooLarge
    case invalidFile
    case unsupportedFormat
}

/// Parses only episode places and their tombstones. Subscription, folder, and
/// local-file records must not cause an otherwise useful device file to fail.
enum ListeningPlacesInboundParser {
    static let maximumFileBytes = 2 * 1_024 * 1_024
    private static let futureClockTolerance: TimeInterval = 24 * 60 * 60
    private static let staleDeviceAge: TimeInterval = 180 * 24 * 60 * 60

    static func parse(data: Data, now: Date = .now) throws -> ListeningPlacesInboundFile {
        guard data.count <= maximumFileBytes else { throw ListeningPlacesInboundParseError.tooLarge }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ListeningPlacesInboundParseError.invalidFile
        }
        guard let format = root["format"] as? String else {
            throw ListeningPlacesInboundParseError.invalidFile
        }
        guard format == ListeningPlacesFormat.identifier else {
            throw ListeningPlacesInboundParseError.unsupportedFormat
        }
        guard let deviceID = root["device"] as? String, !deviceID.isEmpty,
              let app = root["app"] as? String, !app.isEmpty,
              let writtenAtString = root["written_at"] as? String,
              let rows = root["records"] as? [Any] else {
            throw ListeningPlacesInboundParseError.invalidFile
        }
        let dates = DateReader()
        guard let writtenAt = dates.date(writtenAtString) else {
            throw ListeningPlacesInboundParseError.invalidFile
        }

        var entries: [ListeningPlacesInboundEntry] = []
        var malformed = 0
        var unsupported = 0
        var correctedFuture = 0
        entries.reserveCapacity(min(rows.count, ListeningPlacesFormat.maximumRecordCount))
        for value in rows {
            guard let row = value as? [String: Any] else {
                malformed += 1
                continue
            }
            if row["kind"] != nil && !(row["kind"] is String) {
                malformed += 1
                continue
            }
            let kind = row["kind"] as? String
            let id = row["id"] as? String
            if kind == "subscription" || kind == "folder" || kind == "file"
                || id?.hasPrefix("sub:") == true || id?.hasPrefix("folder:") == true
                || id?.hasPrefix("file:") == true {
                unsupported += 1
                continue
            }
            guard kind == nil || kind == "episode" else {
                unsupported += 1
                continue
            }
            guard let id, validEpisodeID(id),
                  let timeString = row["updated_at"] as? String,
                  let updatedAt = dates.date(timeString) else {
                malformed += 1
                continue
            }
            let deleted: Bool?
            if let rawDeleted = row["deleted"] {
                guard let parsed = boolean(rawDeleted) else {
                    malformed += 1
                    continue
                }
                deleted = parsed
            } else {
                deleted = nil
            }
            let record: ListeningPlaceRecord
            if deleted == true {
                record = ListeningPlaceRecord(
                    id: id, kind: nil, positionMilliseconds: nil,
                    durationMilliseconds: nil, played: nil, updatedAt: updatedAt,
                    label: nil, feed: nil, deleted: true
                )
            } else {
                guard let position = integer(row["position_ms"]),
                      let played = boolean(row["played"]) else {
                    malformed += 1
                    continue
                }
                let duration: Int?
                if let rawDuration = row["duration_ms"] {
                    guard let parsed = integer(rawDuration) else {
                        malformed += 1
                        continue
                    }
                    duration = max(0, parsed)
                } else {
                    duration = nil
                }
                let lowerBounded = max(0, position)
                let clampedPosition = duration.map { $0 > 0 ? min(lowerBounded, $0) : lowerBounded }
                    ?? lowerBounded
                let label = row["label"] as? String
                record = ListeningPlaceRecord(
                    id: id, kind: "episode", positionMilliseconds: clampedPosition,
                    durationMilliseconds: duration, played: played, updatedAt: updatedAt,
                    label: label, feed: nil, deleted: nil
                )
            }
            let effectiveTime: Date
            if updatedAt.timeIntervalSince(now) > futureClockTolerance {
                correctedFuture += 1
                effectiveTime = writtenAt.timeIntervalSince(now) > futureClockTolerance
                    ? now : writtenAt
            } else {
                effectiveTime = updatedAt
            }
            entries.append(ListeningPlacesInboundEntry(record: record, effectiveUpdatedAt: effectiveTime))
        }

        // The format's episode cap bounds later index and merge work. If an
        // oversize logical file contains more, keep newest effective records,
        // then return them in their original stable file order.
        let overLimit = max(0, entries.count - ListeningPlacesFormat.maximumRecordCount)
        if overLimit > 0 {
            let kept = entries.enumerated().sorted {
                if $0.element.effectiveUpdatedAt != $1.element.effectiveUpdatedAt {
                    return $0.element.effectiveUpdatedAt > $1.element.effectiveUpdatedAt
                }
                return $0.element.record.id < $1.element.record.id
            }.prefix(ListeningPlacesFormat.maximumRecordCount)
                .sorted { $0.offset < $1.offset }
            entries = kept.map(\.element)
        }
        return ListeningPlacesInboundFile(
            deviceID: deviceID, deviceLabel: root["device_label"] as? String,
            app: app, writtenAt: writtenAt, entries: entries,
            skippedMalformedRowCount: malformed,
            skippedUnsupportedRowCount: unsupported,
            skippedOverLimitRowCount: overLimit,
            futureClockCorrectionCount: correctedFuture,
            isStale: writtenAt.timeIntervalSince(now) < -staleDeviceAge
        )
    }

    private static func validEpisodeID(_ id: String) -> Bool {
        guard id.hasPrefix("episode:") else { return false }
        let suffix = id.dropFirst("episode:".count)
        return suffix.utf8.count == 16 && suffix.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(number.stringValue)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private final class DateReader {
        private let standard = ISO8601DateFormatter()
        private let fractional = ISO8601DateFormatter()

        init() {
            standard.formatOptions = [.withInternetDateTime]
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        }

        func date(_ value: String) -> Date? {
            fractional.date(from: value) ?? standard.date(from: value)
        }
    }
}
