import Foundation

/// Opportunistic HTTPS upgrade for NON-media network fetches (#387, ADR 001).
///
/// Earshot's ATS policy is `NSAllowsArbitraryLoadsForMedia` — plain HTTP is
/// permitted only for audio/video loaded through AVFoundation (the streaming
/// path). Every other request goes through `URLSession` and is subject to ATS,
/// so a plain-`http://` feed document, artwork image, episode download, or ID3
/// tag read would be blocked.
///
/// This upgrades such URLs from `http` to `https`, so every host that also
/// serves HTTPS keeps working after the ATS narrowing. Hosts that are HTTP-only
/// still fail here, though their audio may stream through AVFoundation's media
/// exemption after the listener approves the cleartext connection. Playback
/// uses a separate verified HTTPS probe before choosing a secure URL.
enum SecureURL {
    /// BBC enclosure selectors can publish `/proto/http/` even when their
    /// `/proto/https/` variant serves the same episode over HTTPS. Only rewrite
    /// that exact selector on BBC's own host; other publishers keep the ordinary
    /// scheme-only upgrade. The caller must still verify the HTTPS response.
    static func preferredMediaHTTPS(_ url: URL) -> URL {
        let upgraded = upgradedForNonMedia(url)
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host(percentEncoded: false)?.lowercased() == "open.live.bbc.co.uk",
              var components = URLComponents(url: upgraded, resolvingAgainstBaseURL: false),
              components.percentEncodedPath.contains("/proto/http/")
        else { return upgraded }
        components.percentEncodedPath = components.percentEncodedPath.replacingOccurrences(
            of: "/proto/http/", with: "/proto/https/"
        )
        return components.url ?? upgraded
    }

    /// Returns `url` with its scheme upgraded from `http` to `https`; any other
    /// scheme (including `https` and `file`) is returned unchanged.
    static func upgradedForNonMedia(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.scheme = "https"
        // An explicit :80 no longer matches https; drop it so the upgraded URL
        // targets the default HTTPS port.
        if components.port == 80 { components.port = nil }
        return components.url ?? url
    }
}
