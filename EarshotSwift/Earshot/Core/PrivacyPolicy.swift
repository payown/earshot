import Foundation

/// Canonical URLs for Earshot's hosted privacy policy, surfaced from
/// Settings → Privacy and used for the App Store Connect privacy-policy field.
///
/// Earshot collects no data (see `PrivacyInfo.xcprivacy` = Data Not Collected,
/// #533). The hosted page states exactly that. ``collectionURL`` deep-links to
/// the "what we collect" section of the same page so the two Settings links
/// don't need two separate pages to maintain.
///
/// The page is hosted by Payown Media. Its version-controlled source lives in
/// `docs/privacy/index.html`; keep that source, the published page, and App
/// Store Connect's privacy-policy field in sync.
enum PrivacyPolicy {
    /// The full privacy policy page.
    static let policyURL = URL(string: "https://payown.media/earshot-privacy-policy/")

    /// The "what we collect" section of the same page.
    static let collectionURL = URL(string: "https://payown.media/earshot-privacy-policy/#what-we-collect")

    /// Apple's standard EULA governs Earshot until Payown Media publishes a
    /// custom agreement. This is the canonical URL Apple provides for apps
    /// that use the standard licensed-application agreement.
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")
}
