import SwiftUI

/// Hosts the paywall for the whole app.
///
/// Applied once, at the tab-view root. A refusal can come from a chat turn, an export sheet, or a
/// pack publish — different screens, some already presenting a sheet of their own — so each of them
/// raises a flag on `SubscriptionStore` and this is the only thing that puts a sheet on screen.
private struct SubscriptionPaywallModifier: ViewModifier {
    @Bindable var subscription: SubscriptionStore

    func body(content: Content) -> some View {
        content.sheet(isPresented: $subscription.isPaywallPresented) {
            if let client = subscription.client {
                PaywallSheet(
                    client: client,
                    subscription: subscription,
                    refusal: subscription.pendingRefusal
                )
            }
        }
        .onChange(of: subscription.isPaywallPresented) { _, isPresented in
            if !isPresented { subscription.paywallDismissed() }
        }
    }
}

extension View {
    func subscriptionPaywall(_ subscription: SubscriptionStore) -> some View {
        modifier(SubscriptionPaywallModifier(subscription: subscription))
    }
}
