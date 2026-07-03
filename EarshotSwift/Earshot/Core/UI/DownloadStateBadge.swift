import SwiftUI

/// Compact "Downloaded / Downloading / Streaming" badge for episode rows and the
/// Now Playing surface (#513). Always icon + text + colour — never colour alone
/// and never icon alone — so a user can tell, at the point they decide to play,
/// whether the audio is local or will stream, without relying on colour
/// perception.
///
/// Purely decorative for VoiceOver: the spoken state is already folded into the
/// enclosing element's single accessibility label via
/// ``EpisodeRowLabel/spokenDownloadState(_:)``, so this view is hidden from the
/// accessibility tree to avoid a second stop on the row.
///
/// Uses semantic styles only (Dynamic Type `.caption`, `Color.accentColor` /
/// `Color.secondary`), so it scales and respects the user's theme.
struct DownloadStateBadge: View {
    let status: DownloadStatus

    var body: some View {
        let badge = EpisodeRowLabel.downloadBadge(status)
        Label(badge.text, systemImage: badge.systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption)
            // Downloaded reads as "ready / local" with the accent colour;
            // in-progress and streaming stay secondary so a full library isn't a
            // wall of accent. The icon and text carry the state regardless of
            // colour, so colour is never the only signal.
            .foregroundStyle(status == .downloaded ? Color.accentColor : Color.secondary)
            .accessibilityHidden(true)
    }
}
