import Foundation

/// Canonical URLs for Earshot's hosted privacy policy, surfaced from
/// Settings → Privacy and used for the App Store Connect privacy-policy field.
///
/// Earshot collects no data (see `PrivacyInfo.xcprivacy` = Data Not Collected,
/// #533). The hosted page states exactly that. ``collectionURL`` deep-links to
/// the "what we collect" section of the same page so the two Settings links
/// don't need two separate pages to maintain.
///
/// > Important (#463): the page is hosted by Payown Media. The value below is a
/// > placeholder on the brand domain — **confirm the final public URL and update
/// > it here before any App Store or TestFlight submission.** App Store Connect
/// > stores this URL, so it must be live and stable. The source of the page lives
/// > in `docs/privacy/index.html`.
enum PrivacyPolicy {
    /// The full privacy policy page.
    static let policyURL = URL(string: "https://payown.media/earshot/privacy")

    /// The "what we collect" section of the same page.
    static let collectionURL = URL(string: "https://payown.media/earshot/privacy#what-we-collect")
}
