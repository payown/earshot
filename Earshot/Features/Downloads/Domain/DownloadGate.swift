import Foundation

/// Pure Wi-Fi gating decision for downloads. When the user has "Wi-Fi only"
/// enabled, downloads are blocked off Wi-Fi; otherwise always allowed.
enum DownloadGate {
    static func allowed(wifiOnly: Bool, isOnWifi: Bool) -> Bool {
        !wifiOnly || isOnWifi
    }
}
