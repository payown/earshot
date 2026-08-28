import Foundation

enum EpisodeFilterMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case keepMatching
    case filterMatching

    var id: Self { self }
    var title: String {
        switch self {
        case .keepMatching: "Keep matching"
        case .filterMatching: "Filter matching"
        }
    }
}

enum EpisodeFilterPatternKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case wildcard
    case regularExpression

    var id: Self { self }
    var title: String {
        switch self {
        case .wildcard: "Wildcard"
        case .regularExpression: "Regular expression"
        }
    }
}

struct EpisodeFilterRule: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name = "New filter"
    var isEnabled = true
    var titlePattern = ""
    var patternKind = EpisodeFilterPatternKind.wildcard
    var isCaseSensitive = false
    var minimumDurationMinutes: Int?

    var hasCriterion: Bool {
        !titlePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || minimumDurationMinutes != nil
    }

    var usesDuration: Bool { minimumDurationMinutes != nil }

    func validationMessage() -> String? {
        guard hasCriterion else { return "Add a title pattern or minimum duration." }
        guard minimumDurationMinutes.map({ $0 > 0 }) ?? true else {
            return "Minimum duration must be greater than zero."
        }
        guard patternKind == .regularExpression,
              !titlePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        do {
            _ = try NSRegularExpression(pattern: titlePattern, options: regexOptions)
            return nil
        } catch {
            return "The regular expression is not valid."
        }
    }

    func matches(title: String, durationSeconds: Int?) -> Bool {
        guard isEnabled, hasCriterion, validationMessage() == nil else { return false }
        if !titlePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !matchesTitle(title) { return false }
        if let minimumDurationMinutes {
            guard let durationSeconds,
                  durationSeconds >= minimumDurationMinutes * 60 else { return false }
        }
        return true
    }

    private var regexOptions: NSRegularExpression.Options {
        isCaseSensitive ? [] : [.caseInsensitive]
    }

    private func matchesTitle(_ title: String) -> Bool {
        let pattern: String
        switch patternKind {
        case .regularExpression:
            pattern = titlePattern
        case .wildcard:
            pattern = "^" + NSRegularExpression.escapedPattern(for: titlePattern)
                .replacingOccurrences(of: "\\*", with: ".*")
                .replacingOccurrences(of: "\\?", with: ".") + "$"
        }
        guard let expression = try? NSRegularExpression(pattern: pattern, options: regexOptions)
        else { return false }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        return expression.firstMatch(in: title, range: range) != nil
    }
}

struct EpisodeFilterConfiguration: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = currentVersion
    var isEnabled = false
    var mode = EpisodeFilterMode.filterMatching
    var rules: [EpisodeFilterRule] = []

    var enabledRules: [EpisodeFilterRule] { rules.filter(\.isEnabled) }
    var usesDuration: Bool { enabledRules.contains(where: \.usesDuration) }

    /// A keep-only filter with no usable enabled rule is never active. This is a
    /// second safety boundary behind UI validation, including for damaged or
    /// concurrently edited mirrored settings.
    var isActiveAtIngest: Bool {
        guard isEnabled, version == Self.currentVersion else { return false }
        let validRules = enabledRules.filter { $0.validationMessage() == nil }
        if mode == .keepMatching && validRules.isEmpty { return false }
        return !validRules.isEmpty
    }

    func shouldKeep(title: String, durationSeconds: Int?) -> Bool {
        guard isActiveAtIngest else { return true }
        let matched = enabledRules.contains { $0.matches(title: title, durationSeconds: durationSeconds) }
        return switch mode {
        case .keepMatching: matched
        case .filterMatching: !matched
        }
    }

    func validationMessage() -> String? {
        guard isEnabled else { return nil }
        if mode == .keepMatching && enabledRules.isEmpty {
            return "Keep matching requires at least one enabled filter."
        }
        if enabledRules.isEmpty { return "Enable at least one filter or turn filtering off." }
        if let message = enabledRules.compactMap({ $0.validationMessage() }).first { return message }
        return nil
    }
}

enum EpisodeFilterCodec {
    static func decode(_ rawValue: String?) -> EpisodeFilterConfiguration {
        guard let rawValue,
              let data = rawValue.data(using: .utf8),
              let configuration = try? JSONDecoder().decode(
                EpisodeFilterConfiguration.self, from: data
              ),
              configuration.version == EpisodeFilterConfiguration.currentVersion
        else { return EpisodeFilterConfiguration() }
        return configuration
    }

    static func encode(_ configuration: EpisodeFilterConfiguration) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(configuration), as: UTF8.self)
    }
}

enum EpisodeFilterSpeech {
    static func ruleLabel(_ rule: EpisodeFilterRule) -> String {
        "\(rule.name), \(rule.isEnabled ? "enabled" : "disabled"). \(ruleCriteriaLabel(rule))"
    }

    static func ruleCriteriaLabel(_ rule: EpisodeFilterRule) -> String {
        var sentences: [String] = []
        let pattern = rule.titlePattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pattern.isEmpty {
            let kind = rule.patternKind == .wildcard ? "Wildcard title" : "Regular expression title"
            sentences.append("\(kind), \(pattern).")
            if rule.isCaseSensitive { sentences.append("Case sensitive.") }
        }
        if let minutes = rule.minimumDurationMinutes {
            sentences.append(
                "Duration at least \(minutes) \(minutes == 1 ? "minute" : "minutes")."
            )
        }
        return sentences.joined(separator: " ")
    }

    static func previewLabel(
        kept: Bool,
        title: String,
        durationSeconds: Int?
    ) -> String {
        var parts = [kept ? "Kept" : "Filtered", title]
        if let durationSeconds {
            parts.append("\(max(1, durationSeconds / 60)) minutes")
        } else {
            parts.append("duration unavailable")
        }
        return parts.joined(separator: ", ") + "."
    }
}

enum EpisodeFilterSaveAssessment: Equatable {
    case allowed
    case confirmPartialDuration(reported: Int, total: Int)
    case refuseNoDuration

    static func assess(
        configuration: EpisodeFilterConfiguration,
        previewDurations: [Int?]
    ) -> Self {
        guard configuration.isEnabled, configuration.usesDuration else { return .allowed }
        let reported = previewDurations.compactMap { $0 }.count
        guard reported > 0 else { return .refuseNoDuration }
        guard reported == previewDurations.count else {
            return .confirmPartialDuration(reported: reported, total: previewDurations.count)
        }
        return .allowed
    }
}
