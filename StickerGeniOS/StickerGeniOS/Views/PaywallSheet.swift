import RxSubscriptionIOS
import SwiftUI

/// The plans, top-ups, and balance screens, wrapped in this app's voice.
///
/// The body is `RxSubscriptionIOS.PaywallView` — the catalog, prices, purchase, and restore are all
/// the package's, driven by whatever is configured in the RxSubscription console, so a price change
/// never needs an app release. Only the header is ours.
struct PaywallSheet: View {
    let client: Client
    @Bindable var subscription: SubscriptionStore
    /// What the user was trying to do when the wall went up. Nil when they opened it themselves.
    var refusal: SubscriptionRefusal?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch subscription.paywallContent(for: refusal) {
                case .plans:
                    PaywallView(
                        client: client,
                        paywall: .server,
                        sections: [.plans, .topUps, .balances],
                        initialSection: initialSection
                    ) {
                        PaywallHeader(refusal: refusal, activePlanName: nil)
                    }
                case .credits:
                    // The published server paywall is an acquisition page. Active subscribers and
                    // users who merely ran out of credits need the package's credit controls, not
                    // another Plus purchase button.
                    PaywallView(
                        client: client,
                        paywall: .local,
                        sections: [.topUps, .balances],
                        initialSection: .topUps
                    ) {
                        PaywallHeader(
                            refusal: refusal,
                            activePlanName: subscription.activePlanName
                        )
                    }
                case .suppressed:
                    Color.clear
                        .task { dismiss() }
                }
            }
            .navigationTitle("Credits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("paywall-done")
                }
            }
        }
        .task { await subscription.monitorPresentedPaywall() }
    }

    /// Someone who ran out mid-sticker wants the cheapest way back to work, which is a top-up.
    /// Someone who needs a tier they are not on wants a plan.
    private var initialSection: PaywallSection {
        switch refusal {
        case .insufficientCredits: .topUps
        case .subscriptionRequired, nil: .plans
        }
    }
}

private struct PaywallHeader: View {
    let refusal: SubscriptionRefusal?
    let activePlanName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.largeTitle.bold())
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("paywall-header")
    }

    private var title: String {
        switch refusal {
        case .insufficientCredits: String(localized: "Out of credits")
        case .subscriptionRequired: String(localized: "Go Pro")
        case nil:
            activePlanName == nil
                ? String(localized: "Keep creating")
                : String(localized: "Manage credits")
        }
    }

    private var subtitle: String {
        switch refusal {
        case .insufficientCredits(let required, let available):
            if let required, let available {
                String(localized: "This one needs \(required) credits and you have \(available). Top up to finish it.")
            } else {
                String(localized: "Top up to finish this sticker, or upgrade for a monthly allowance.")
            }
        case .subscriptionRequired:
            String(localized: "Sharing packs on the marketplace is part of a paid plan.")
        case nil:
            if let activePlanName {
                String(localized: "Your \(activePlanName) plan is active. Top up whenever you need more credits.")
            } else {
                String(localized: "Credits pay for the AI that draws and animates your stickers.")
            }
        }
    }
}
