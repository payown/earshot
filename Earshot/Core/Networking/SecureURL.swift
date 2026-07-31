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
/// still fail here — but their audio continues to STREAM via AVFoundation's
/// media exemption, which is why the AVPlayer stream URL is deliberately never
/// passed through this helper.
enum SecureURL {
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
