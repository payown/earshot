import SwiftUI

/// Earshot Plus upgrade paywall (#632).
///
/// Presented as a sheet from exactly THREE trigger points, and never any
/// other way — no launch interstitial, no timer, no re-presentation on a
/// schedule:
///   1. An 11th-subscribe attempt hits the free-tier cap (`SearchView`,
///      `PodcastPreviewView` — both catch `SubscriptionError.podcastCapReached`).
///   2. An OPML import gets trimmed by the cap (`DataSettingsView`, via
///      `OPMLFileImporter`'s `onCapSkipped` callback).
///   3. The persistent "Upgrade to Earshot Plus" row in Settings.
///
/// All three Earshot Plus products (Monthly, Yearly, Lifetime) render with
/// EQUAL visual and semantic weight: identical font sizes, identical
/// `.borderedProminent` button styling, identical card layout. The only
/// differentiation is a small, factually-computed "Best value" badge on
/// Yearly (``PaywallViewModel/bestValueBadge``, from
/// ``PaywallLogic/bestValueBadge(monthly:yearly:)``) — never achieved through
/// size, color, or prominence manipulation of the other two options. Monthly
/// is never smaller, muted, or buried.
///
/// Price and subscription terms are a standalone, always-visible `Text`
/// element positioned BEFORE each purchase button in both layout and
/// VoiceOver reading order — never a button hint, never gated behind a tap
/// or a `DisclosureGroup`. See ``PaywallLogic/subscriptionDisclosure(for:)``
/// and ``PaywallLogic/lifetimeDisclosure(for:)``.
///
/// Dismissal (the top-leading "Close" button) works identically before,
/// during, and after a purchase attempt — there is no guilt-tripping
/// dismiss-path copy, no countdown, no "X spots left." A successful purchase
/// does NOT auto-dismiss the sheet (deliberate — see the success banner
/// below): the user closes it the same explicit way they would at any other
/// point, so a VoiceOver user is never caught off guard by a timed
/// disappearance mid-announcement.
///
/// VoiceOver reading order (top to bottom, matches visual layout — no
/// `accessibilitySortPriority` overrides needed since the default List/VStack
/// order already produces this):
///   heading ("Earshot Plus") → subtitle → [outcome banner, if a purchase has
///   settled] → Monthly card (name+price → disclosure → purchase button with
///   its own combined label) → Yearly card (same shape, badge included in the
///   name+price line) → Lifetime card (same shape) → footer note → Close
///   button (nav bar, read as part of the nav bar's own VoiceOver group,
///   reachable at any time independent of scroll position).
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(EntitlementStore.self) private var entitlements

    @State private var model = PaywallViewModel()

    var body: some View {
        NavigationStack {
            Group {
                switch model.loadState {
                case .loading:
                    loadingView
                case .failed:
                    failedView
                case .loaded:
                    loadedView
                }
            }
            .navigationTitle("Earshot Plus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    // Explicit label rather than relying on shape recognition of
                    // the xmark glyph — hard requirement (#632).
                    .accessibilityLabel("Close")
                }
            }
        }
        .task { await model.loadProducts() }
    }

    // MARK: Loading / failed

    private var loadingView: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
            Text("Loading Earshot Plus…")
                .font(.body)
                .foregroundStyle(AppColor.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading Earshot Plus")
    }

    private var failedView: some View {
        VStack(spacing: Spacing.md) {
            Label {
                Text("Couldn't load Earshot Plus. Check your connection.")
                    .font(.body)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColor.error)
            }
            .accessibilityElement(children: .combine)
            Button("Try Again") {
                Task { await model.loadProducts() }
            }
            .buttonStyle(.bordered)
            .frame(minHeight: Spacing.minTouchTarget)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Loaded

    private var loadedView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                header
                if let outcome = model.outcome {
                    outcomeBanner(outcome)
                }
                productsSection
                legalFooter
            }
            .padding()
        }
        // Disables the whole sheet's interactive content (not the Close
        // button, which lives in the toolbar) while a purchase is in flight,
        // so a second tap on another product can't fire mid-purchase.
        .disabled(model.purchasingProduct != nil)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Earshot Plus")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            // Plain-language, honest description of what Plus unlocks. No
            // "supercharge"/"unlock your potential" language — just what it does.
            Text("Follow unlimited podcasts. The free plan is capped at \(PodcastCapPolicy.freeTierLimit) subscriptions — Earshot Plus removes that limit.")
                .font(.body)
                .foregroundStyle(AppColor.secondaryText)
        }
    }

    @ViewBuilder
    private func outcomeBanner(_ outcome: PaywallPurchaseOutcome) -> some View {
        switch outcome {
        case .success:
            Label {
                Text("You're an Earshot Plus member. Thank you.")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColor.played)
            }
            .font(.headline)
            .accessibilityElement(children: .combine)
        case .pending:
            Label {
                Text("Purchase pending approval. You'll be notified once it's approved.")
            } icon: {
                Image(systemName: "clock.fill")
                    .foregroundStyle(AppColor.secondaryText)
            }
            .font(.headline)
            .accessibilityElement(children: .combine)
        case .failed:
            Label {
                Text("Purchase failed. Check your connection and try again.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColor.error)
            }
            .font(.headline)
            .accessibilityElement(children: .combine)
        }
    }

    private var productsSection: some View {
        // Fixed order — Monthly, Yearly, Lifetime — regardless of which one
        // (if any) earns the "Best value" badge. The badge is the only
        // differentiation; ordering by shortest-to-longest commitment is a
        // deliberate, neutral judgment call, not a ranking by "best."
        VStack(spacing: Spacing.md) {
            if let monthly = model.monthlyDisplay {
                productCard(monthly, badge: nil)
            }
            if let yearly = model.yearlyDisplay {
                productCard(yearly, badge: model.bestValueBadge)
            }
            if let lifetime = model.lifetimeDisplay {
                productCard(lifetime, badge: nil)
            }
        }
    }

    private func productCard(_ display: PaywallProductDisplay, badge: String?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(display.displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                Text(display.displayPrice)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppColor.secondaryText)
            }
            if let badge {
                // A small factual badge — icon + text, matching the
                // never-color-alone rule even though this isn't a state
                // indicator, kept visually secondary (caption + secondary
                // accent weight) so it can never read as differential
                // prominence versus Monthly or Lifetime's identical card
                // chrome/button styling.
                Label(badge, systemImage: "star.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColor.accent)
            }
            // Standalone, always-visible disclosure — see the type doc
            // comment above for why this must be a separate element, not a
            // button hint.
            Text(display.subscriptionPeriod != nil
                 ? PaywallLogic.subscriptionDisclosure(for: display)
                 : PaywallLogic.lifetimeDisclosure(for: display))
                .font(.footnote)
                .foregroundStyle(AppColor.secondaryText)

            Button {
                Task { await model.purchase(display, entitlements: entitlements) }
            } label: {
                Text(model.purchasingProduct == display.product ? "Purchasing…" : "Continue")
                    .frame(maxWidth: .infinity, minHeight: Spacing.minTouchTarget)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.purchasingProduct != nil || model.outcome == .success)
            // `.disabled` alone only adds the "dimmed" trait, no spoken busy
            // indication (matches `RestorePurchasesRow`'s documented reasoning)
            // — swap the label text itself for the busy state.
            .accessibilityLabel(model.purchasingProduct == display.product
                ? "Purchasing \(display.displayName)"
                : PaywallLogic.accessibilityLabel(for: display))
            .accessibilityHint(display.subscriptionPeriod != nil
                ? "Starts the subscription immediately"
                : "Completes a one-time purchase")
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var legalFooter: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Subscriptions renew automatically unless cancelled. Lifetime is a one-time purchase. All purchases are processed by Apple.")
                .font(.caption)
                .foregroundStyle(AppColor.secondaryText)

            HStack(spacing: Spacing.md) {
                if let termsURL = PrivacyPolicy.termsURL {
                    Link("Terms of Use", destination: termsURL)
                        .accessibilityHint("Opens Apple's standard license agreement in your browser")
                }
                if let policyURL = PrivacyPolicy.policyURL {
                    Link("Privacy Policy", destination: policyURL)
                        .accessibilityHint("Opens Earshot's privacy policy in your browser")
                }
            }
            .font(.caption)
        }
    }
}
