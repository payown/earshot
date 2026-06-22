import Foundation

/// Pure helpers for the Settings → Send Feedback screen (PRD 12, issue #392).
///
/// Kept free of `UIKit`, `MessageUI`, and SwiftUI so the body construction, the
/// anonymized system-info block, and the `mailto:` fallback URL can be
/// unit-tested without presenting a real mail composer.
///
/// Privacy: the system-info block contains ONLY app version, build number, iOS
/// version, and the device model identifier. No names, no account, no
/// identifiers for advertising, no listening history — Earshot's
/// minimum-data ethos applies here too.
enum FeedbackComposer {

    /// The address feedback is sent to (PRD 12).
    static let recipient = "beta@payown.media"

    /// The default subject line for a feedback mail.
    static let defaultSubject = "Earshot feedback"

    /// Builds the anonymized system-info block appended to the feedback body when
    /// the user opts in. Each field is on its own line with a stable label so a
    /// human reading the mail can scan it quickly.
    ///
    /// - Parameters:
    ///   - appVersion: `CFBundleShortVersionString` (e.g. "0.1.0").
    ///   - build: `CFBundleVersion` (e.g. "113").
    ///   - iosVersion: `UIDevice.current.systemVersion` (e.g. "17.4").
    ///   - deviceModel: hardware model identifier (e.g. "iPhone16,2").
    static func systemInfoBlock(
        appVersion: String,
        build: String,
        iosVersion: String,
        deviceModel: String
    ) -> String {
        """
        ---
        System info (anonymized)
        App version: \(appVersion) (\(build))
        iOS: \(iosVersion)
        Device: \(deviceModel)
        """
    }

    /// Builds the full mail body. When `systemInfo` is provided it is appended
    /// below a blank line so the user's own message stays at the top. When
    /// `systemInfo` is `nil` the body is just the lead-in text.
    static func body(systemInfo: String?) -> String {
        let lead = "Tell us what's working, what isn't, or what you'd like to see.\n\n"
        guard let systemInfo, !systemInfo.isEmpty else { return lead }
        return lead + "\n" + systemInfo
    }

    /// Builds a `mailto:` URL used as the fallback path when
    /// `MFMailComposeViewController.canSendMail()` is false. Subject and body are
    /// percent-encoded so spaces, newlines, and special characters survive the
    /// query string. Returns `nil` only if encoding fails entirely.
    static func mailtoURL(to recipient: String, subject: String, body: String) -> URL? {
        // RFC 6068: the mailto query is a URL query, so encode each value with a
        // conservative allowed set. `urlQueryAllowed` still permits `&`, `=`, `+`
        // and `?`, which would corrupt the query, so subtract them.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?")

        guard
            let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: allowed),
            let encodedBody = body.addingPercentEncoding(withAllowedCharacters: allowed)
        else {
            return nil
        }

        let string = "mailto:\(recipient)?subject=\(encodedSubject)&body=\(encodedBody)"
        return URL(string: string)
    }
}
