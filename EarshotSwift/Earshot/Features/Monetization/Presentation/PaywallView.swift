import StoreKit
import SwiftUI
import UIKit

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
/// Each purchasable card remains one VoiceOver Button. Its label contains only
/// decision information; compressed terms live in its hint, and one shared,
/// fully focusable legal disclosure follows all tier controls.
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
///   settled] → available tier controls (three in the standard paywall) → one
///   shared purchase-terms element → Terms/Privacy links → Close
///   button (nav bar, read as part of the nav bar's own VoiceOver group,
///   reachable at any time independent of scroll position).
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.openURL) private var openURL

    @State private var model = PaywallViewModel()
    @State private var openingManageSubscriptions = false

    let mode: PaywallPresentationMode

    init(mode: PaywallPresentationMode = .upgrade) {
        self.mode = mode
    }

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
                if model.showsLifetimeCancellationGuidance {
                    lifetimeCancellationGuidance
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
            Text(mode == .changePlan
                ? "Review your current plan and available Earshot Plus upgrades."
                : "Follow unlimited podcasts. The free plan is capped at \(PodcastCapPolicy.freeTierLimit) subscriptions — Earshot Plus removes that limit.")
                .font(.body)
                .foregroundStyle(AppColor.secondaryText)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(PaywallLogic.visibleBenefits, id: \.self) { benefit in
                    Label(benefit, systemImage: "checkmark.circle.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppColor.primaryText)
                }
            }
            // The existing subtitle already carries the benefit in upgrade mode,
            // and plan-change VoiceOver users already hear the tier decision
            // labels. This row is the missing visual layer, not another stop.
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func outcomeBanner(_ outcome: PaywallPurchaseOutcome) -> some View {
        switch outcome {
        case .success:
            Label {
                Text(mode == .changePlan
                    ? "Your Earshot Plus plan is updated. Thank you."
                    : "You're an Earshot Plus member. Thank you.")
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
        VStack(spacing: Spacing.md) {
            ForEach(PaywallLogic.tierOptions(
                mode: mode,
                currentProduct: entitlements.activeProduct
            )) { option in
                if let display = model.display(for: option.product) {
                    switch option.status {
                    case .current:
                        currentPlanCard(display)
                    case .offer:
                        productCard(
                            display,
                            badge: display.product == .plusYearly ? model.bestValueBadge : nil
                        )
                    }
                }
            }
            sharedLegalDisclosure
        }
    }

    private func productCard(_ display: PaywallProductDisplay, badge: String?) -> some View {
        let showsSubscriberNotice = mode == .changePlan
            && display.product == .plusLifetime
            && entitlements.hasActiveSubscription

        return VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(PaywallLogic.decisionDisplayName(for: display))
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                Text(display.displayPrice)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppColor.secondaryText)
            }
            .accessibilityHidden(true)
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
                    .accessibilityHidden(true)
            }
            if showsSubscriberNotice {
                Text(PaywallLogic.lifetimeSubscriberNotice)
                    .font(.footnote)
                    .foregroundStyle(AppColor.secondaryText)
                    // The concise equivalent lives in the button hint, so this
                    // visible warning does not add another mandatory flick.
                    .accessibilityHidden(true)
            }

            HStack {
                Spacer()
                Button {
                    Task { await model.purchase(display, entitlements: entitlements) }
                } label: {
                    Text(buttonTitle(for: display))
                }
                .buttonStyle(.borderedProminent)
                // Match the intrinsic visual height used by the app's other
                // primary bordered buttons. The transparent outer region keeps
                // the full 44-point target without inflating the blue chrome.
                .frame(minHeight: Spacing.minTouchTarget)
                .contentShape(Rectangle())
                .disabled(model.purchasingProduct != nil || model.outcome == .success)
                // `.disabled` alone only adds the "dimmed" trait, no spoken
                // busy indication. Swap the label while StoreKit is active.
                .accessibilityLabel(model.purchasingProduct == display.product
                    ? "Purchasing \(PaywallLogic.decisionDisplayName(for: display))"
                    : PaywallLogic.tierAccessibilityLabel(for: display, badge: badge))
                .accessibilityHint(PaywallLogic.purchaseHint(
                    for: display,
                    mode: mode,
                    hasActiveSubscription: entitlements.hasActiveSubscription
                ))
                Spacer()
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func currentPlanCard(_ display: PaywallProductDisplay) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(PaywallLogic.decisionDisplayName(for: display))
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                Text(display.displayPrice)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppColor.secondaryText)
            }
            Label("Current plan", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColor.accent)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PaywallLogic.currentPlanAccessibilityLabel(for: display))
    }

    private var sharedLegalDisclosure: some View {
        Text(PaywallLogic.sharedLegalDisclosure)
            .font(.footnote)
            .foregroundStyle(AppColor.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Purchase terms. \(PaywallLogic.sharedLegalDisclosure)")
    }

    private var lifetimeCancellationGuidance: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label("Subscription action needed", systemImage: "exclamationmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(AppColor.accent)
                Text("Your Lifetime purchase does not cancel your subscription automatically. Cancel the subscription to avoid future charges.")
                    .font(.body)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Subscription action needed. Your Lifetime purchase does not cancel your subscription automatically. Cancel the subscription to avoid future charges.")

            Button {
                openManageSubscriptions()
            } label: {
                Text(openingManageSubscriptions ? "Opening Subscriptions…" : "Manage Subscription")
                    .frame(minHeight: Spacing.minTouchTarget)
            }
            .buttonStyle(.bordered)
            .disabled(openingManageSubscriptions)
            .accessibilityLabel(openingManageSubscriptions ? "Opening subscriptions" : "Manage Subscription")
            .accessibilityHint("Opens Apple's subscription management")
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func buttonTitle(for display: PaywallProductDisplay) -> String {
        if model.purchasingProduct == display.product {
            return "Purchasing…"
        }
        guard mode == .changePlan else { return "Continue" }
        switch display.product {
        case .plusYearly: return "Upgrade to Yearly"
        case .plusLifetime: return "Buy Lifetime"
        case .plusMonthly, .tipSmall, .tipMedium, .tipLarge: return "Continue"
        }
    }

    private func openManageSubscriptions() {
        guard !openingManageSubscriptions else { return }
        openingManageSubscriptions = true
        Task {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
            else {
                openManageSubscriptionsFallback()
                return
            }
            do {
                try await AppStore.showManageSubscriptions(in: scene)
                openingManageSubscriptions = false
            } catch {
                AppLog.monetization.error("Manage subscriptions sheet failed: \(error.localizedDescription, privacy: .public)")
                openManageSubscriptionsFallback()
            }
        }
    }

    private func openManageSubscriptionsFallback() {
        openingManageSubscriptions = false
        guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else { return }
        openURL(url) { accepted in
            if !accepted {
                AppLog.monetization.error("No application accepted the subscriptions account URL")
                Announcer.announce("Could not open subscriptions. Try again from App Store account settings.", assertive: true)
            }
        }
    }

    private var legalFooter: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
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
