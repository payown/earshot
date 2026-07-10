import SwiftUI
import StoreKit

/// Tip jar (#636): three consumable one-time tip presets, available to every
/// user regardless of Earshot Plus entitlement. Pushed from Settings > Help &
/// About > "Leave a Tip" via a plain `NavigationLink`, not a sheet — so
/// dismissal-without-tipping is the standard system back button: always
/// visible, always at least 44pt, identical to every other screen in the app,
/// and requires no drag gesture. (Judgment call, flagged for sign-off: no
/// additional close button is added here. A second dismiss affordance
/// alongside the automatic back button would be redundant chrome on a pushed
/// screen, where the back button already sits at the top of the VoiceOver
/// focus order before anything else on the page.)
///
/// VoiceOver focus order (top to bottom, matches visual order, no override
/// needed): navigation bar back button -> explanatory body text -> three
/// preset buttons in ascending price order -> outcome status text (only
/// present after an attempt). This is a deliberate design decision: the exit
/// affordance is reachable before any tip button, and the three amounts read
/// in the same left-to-right/ascending order shown on screen.
struct TipJarView: View {
    @State private var viewModel = TipJarViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(
                    "Earshot is free to use, with no ads and no trackers. If it's useful to you, a tip helps keep it that way."
                )
                .font(.body)
                .foregroundStyle(AppColor.primaryText)

                content
            }
            .padding()
        }
        .navigationTitle("Leave a Tip")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await viewModel.loadProducts()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.productsState {
        case .idle, .loading:
            HStack {
                Spacer()
                ProgressView("Loading tip options")
                Spacer()
            }
            .padding(.top, 40)
        case .failed:
            VStack(alignment: .leading, spacing: 12) {
                Text("Couldn't load tip options.")
                    .font(.headline)
                Text("Check your connection and try again.")
                    .font(.subheadline)
                    .foregroundStyle(AppColor.secondaryText)
                Button("Try Again") {
                    Task { await viewModel.loadProducts() }
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
            }
        case .loaded(let products):
            VStack(alignment: .leading, spacing: 16) {
                ForEach(EarshotPlusProduct.tipProducts, id: \.self) { product in
                    TipPresetButton(
                        product: product,
                        storeKitProduct: products[product],
                        isPurchasing: viewModel.purchasingProduct == product,
                        isDisabled: viewModel.purchasingProduct != nil
                    ) {
                        await viewModel.purchase(product)
                    }
                }

                if let message = viewModel.outcomeMessage, let outcome = viewModel.lastOutcome {
                    TipOutcomeStatus(outcome: outcome, message: message)
                }
            }
            .motionAwareAnimation(.easeInOut(duration: 0.2), value: viewModel.lastOutcome)
        }
    }
}

/// One tip preset button. Shows the real StoreKit `displayName`/`displayPrice`
/// (never a hardcoded string) plainly, before the button is tapped — no
/// confirm-then-surprise. The whole row is one `Button`, so the busy state
/// (`ProgressView` swapped in for the heart glyph) and the explicit
/// `accessibilityLabel` below are the only things VoiceOver ever announces
/// for it; the decorative glyph never gets its own stop.
private struct TipPresetButton: View {
    let product: EarshotPlusProduct
    let storeKitProduct: Product?
    let isPurchasing: Bool
    let isDisabled: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(storeKitProduct?.displayName ?? placeholderName)
                        .font(.headline)
                        .lineLimit(2)
                    if let price = storeKitProduct?.displayPrice {
                        Text(price)
                            .font(.subheadline)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                }
                Spacer()
                if isPurchasing {
                    ProgressView()
                } else {
                    Image(systemName: "heart")
                        .foregroundStyle(AppColor.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding()
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || storeKitProduct == nil)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Purchases a one-time tip. Does not unlock Earshot Plus.")
    }

    private var placeholderName: String {
        switch product {
        case .tipSmall: "Small Tip"
        case .tipMedium: "Medium Tip"
        case .tipLarge: "Large Tip"
        case .plusMonthly, .plusYearly, .plusLifetime: "Tip"
        }
    }

    /// Combines the real StoreKit `displayPrice` (never a hardcoded string,
    /// so it reflects whatever price/locale App Store Connect actually has
    /// configured) with the purpose, so VoiceOver reads e.g. "Leave a $4.99
    /// tip" rather than just the bare product name. `displayPrice` is already
    /// the exact string form VoiceOver reads for any native price label
    /// elsewhere on iOS (e.g. the App Store itself), so no extra
    /// spoken-form transformation is applied here — that's a deliberate
    /// choice, flagged for sign-off: a hand-authored "one dollar ninety-nine
    /// cents" string would drift from the real configured price/locale and
    /// duplicates work VoiceOver's number formatter already does correctly.
    private var accessibilityLabel: String {
        guard let price = storeKitProduct?.displayPrice else {
            return isPurchasing ? "Purchasing tip" : "Leave a tip"
        }
        return isPurchasing ? "Purchasing \(price) tip" : "Leave a \(price) tip"
    }
}

/// Status text shown after a purchase attempt completes. Icon + label + color
/// together, never color alone (matches the pattern in `SendFeedbackView`'s
/// fallback-mail message).
private struct TipOutcomeStatus: View {
    let outcome: TipJarOutcome
    let message: String

    var body: some View {
        Label {
            Text(message)
                .font(.subheadline)
        } icon: {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }

    private var iconName: String {
        switch outcome {
        case .success: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        case .pending: "clock"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch outcome {
        case .success: AppColor.played
        case .cancelled, .pending: AppColor.secondaryText
        case .failed: AppColor.error
        }
    }
}
