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
            } else {
                SubscriptionConnectionView(subscription: subscription)
            }
        }
        .onChange(of: subscription.isPaywallPresented) { _, isPresented in
            if !isPresented { subscription.paywallDismissed() }
        }
    }
}

private struct SubscriptionConnectionView: View {
    @Bindable var subscription: SubscriptionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if subscription.isConnecting {
                    PosterProgress(message: String(localized: "Connecting to the App Store…"))
                        .accessibilityIdentifier("subscription-connection-progress")
                } else {
                    ContentUnavailableView {
                        Label("Subscriptions unavailable", systemImage: "creditcard")
                            .accessibilityIdentifier("subscription-connection-error")
                    } description: {
                        Text(subscription.lastError ?? String(localized: "Please try again to view subscription plans."))
                    } actions: {
                        Button("Try Again") { subscription.retryConnection() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("subscription-connection-retry")
                    }
                }
            }
            .navigationTitle("Subscription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("paywall-done")
                }
            }
        }
    }
}

extension View {
    func subscriptionPaywall(_ subscription: SubscriptionStore) -> some View {
        modifier(SubscriptionPaywallModifier(subscription: subscription))
    }
}
