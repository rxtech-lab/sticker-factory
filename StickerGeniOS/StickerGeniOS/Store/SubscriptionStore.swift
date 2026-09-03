import Foundation
import Observation
import RxSubscriptionIOS
import StoreKit

nonisolated extension SubscriptionEnvironment {
    static func currentVerified() async -> Self? {
        guard let result = try? await AppTransaction.shared else { return nil }
        guard case .verified(let appTransaction) = result else { return nil }

        if appTransaction.environment == .xcode { return .xcode }
        if appTransaction.environment == .sandbox { return .sandbox }
        if appTransaction.environment == .production { return .production }
        return nil
    }
}

nonisolated enum SubscriptionAccess {
    /// Keep this aligned with the subscription backend's live entitlement statuses.
    private static let activeStatuses = Set(["active", "trialing", "past_due"])

    static func isActive(status: String) -> Bool {
        activeStatuses.contains(status)
    }
}

nonisolated enum SubscriptionBalance {
    /// Matches `CREDIT_UNIT` on the Sticker Factory server.
    static let creditUnit = "points"

    static func credits(in balances: [Balance]) -> Int {
        balances.first { $0.unit == creditUnit }?.available ?? 0
    }
}

nonisolated enum SubscriptionPaywallContent: Equatable {
    case plans
    case credits
    case suppressed

    static func resolve(
        hasActiveSubscription: Bool,
        refusal: SubscriptionRefusal?
    ) -> Self {
        switch refusal {
        case .insufficientCredits:
            return .credits
        case .subscriptionRequired:
            return hasActiveSubscription ? .suppressed : .plans
        case nil:
            return hasActiveSubscription ? .credits : .plans
        }
    }
}

/// What the app knows about the signed-in user's plan, credits, and paywall.
///
/// The RxSubscription client is stateless and each of the package's screens fetches for itself, so
/// this exists to give the rest of the app one cached, observable answer to "how many credits do
/// they have" and "may they publish" — questions asked from a toolbar and from a service, neither
/// of which should be issuing its own network call.
///
/// Deliberately not the enforcement point. The server holds the secret key and decides whether a
/// generation may run; this only decides what to *show*. A stale cache here can put a paywall up a
/// moment late, which is a cosmetic problem, not a revenue one.
@MainActor
@Observable
final class SubscriptionStore {
    /// Matches `PUBLISH_PERMISSION` on the server.
    private static let publishPermission = "marketplace.publish"

    private(set) var entitlements: Entitlements?
    private(set) var isLoading = false
    private(set) var lastError: String?

    /// Raised by whichever surface hit a wall, and lowered when the sheet closes.
    var isPaywallPresented = false
    /// Why the paywall went up, so it can open on the section that answers it. Nil when the user
    /// opened it themselves.
    private(set) var pendingRefusal: SubscriptionRefusal?

    /// Nil until somebody signs in — the client is bound to one rxlab user, and there is no
    /// meaningful request to make before there is one.
    private(set) var client: Client?

    @ObservationIgnored private let serverURL: URL?
    @ObservationIgnored private let publishableKeys: SubscriptionPublishableKeys
    @ObservationIgnored private let tokenBroker: SharedTokenBroker?
    @ObservationIgnored private let environmentProvider: () async -> SubscriptionEnvironment?
    @ObservationIgnored private var clientBindingTask: Task<Void, Never>?
    @ObservationIgnored private var bindingUserID: String?
    @ObservationIgnored private var transactionObserver: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Whether this build has a paywall at all. A build with no key configured hides every
    /// subscription surface rather than showing an empty one.
    var isConfigured: Bool { serverURL != nil && publishableKeys.hasAnyKey }

    /// Whether there is a client to hand the package's views.
    var isReady: Bool { client != nil }

    var credits: Int? {
        guard let entitlements else { return nil }
        // Free users may not have a balance row until their first grant. Once entitlements have
        // loaded, absence means zero rather than an indefinitely loading balance.
        return SubscriptionBalance.credits(in: entitlements.balances)
    }

    /// The plan to show in Account. Nil means the free tier, which has no subscription row.
    var activePlanName: String? {
        entitlements?.plans.first { SubscriptionAccess.isActive(status: $0.status) }?.planName
    }

    var hasActiveSubscription: Bool {
        activePlanName != nil
    }

    /// Whether the marketplace is open to this user. Unknown-yet reads as allowed: the server
    /// refuses a publish it should not permit, and blocking the button on a cache that has not
    /// loaded would make the app look broken to a paying user.
    var canPublishPacks: Bool {
        guard isConfigured, let entitlements else { return true }
        return entitlements.permissions.contains(Self.publishPermission)
    }

    init(
        configuration: AppConfiguration,
        tokenBroker: SharedTokenBroker,
        environmentProvider: @escaping () async -> SubscriptionEnvironment? = {
            await SubscriptionEnvironment.currentVerified()
        }
    ) {
        self.serverURL = configuration.subscriptionBaseURL
        self.publishableKeys = configuration.subscriptionPublishableKeys
        self.tokenBroker = tokenBroker
        self.environmentProvider = environmentProvider
    }

    /// For previews and UI tests: a store with nothing configured, which reports no paywall.
    init() {
        self.serverURL = nil
        self.publishableKeys = SubscriptionPublishableKeys(
            xcode: nil,
            sandbox: nil,
            production: nil
        )
        self.tokenBroker = nil
        self.environmentProvider = { nil }
    }

    deinit {
        clientBindingTask?.cancel()
        transactionObserver?.cancel()
    }

    /// Binds the store to a signed-in user and loads their entitlements.
    ///
    /// Safe to call on every launch and after every sign-in; re-binding to the same user is a
    /// no-op, and binding to a different one throws away the previous user's cache first.
    func signedIn(rxlabUserID: String) {
        guard let serverURL, let tokenBroker, publishableKeys.hasAnyKey else { return }
        guard client?.user.rxlabUserID != rxlabUserID else {
            refresh()
            return
        }
        guard bindingUserID != rxlabUserID else { return }
        reset()
        bindingUserID = rxlabUserID
        let environmentProvider = self.environmentProvider

        clientBindingTask = Task { [weak self] in
            let environment = await environmentProvider()
            guard let self,
                  !Task.isCancelled,
                  self.bindingUserID == rxlabUserID else { return }
            guard let environment else {
                self.bindingUserID = nil
                self.clientBindingTask = nil
                self.lastError = "The App Store environment could not be verified."
                return
            }
            guard let publishableKey = self.publishableKeys.key(for: environment) else {
                self.bindingUserID = nil
                self.clientBindingTask = nil
                self.lastError = "No valid \(environment.rawValue) subscription publishable key is configured."
                return
            }

            let client = Client(
                serverURL: serverURL,
                publishableKey: publishableKey,
                rxlabUserID: rxlabUserID,
                userToken: { forceRefresh in
                    try await tokenBroker.validAccessToken(forceRefresh: forceRefresh)
                }
            )
            self.client = client
            self.bindingUserID = nil
            self.clientBindingTask = nil
            self.lastError = nil
            // Renewals and Ask-to-Buy approvals never come back as the result of a purchase call,
            // so without this they would reach the server only through App Store notifications
            // and the app's own credit count would sit stale until the next cold start.
            self.transactionObserver = client.observeTransactionUpdates { [weak self] _ in
                self?.refresh()
            }
            self.refresh()
        }
    }

    /// Reloads the cache, coalescing overlapping calls.
    ///
    /// Several surfaces refresh on appear and the open paywall monitors for fulfillment; without
    /// this a user returning to the Library after buying credits would fire duplicate requests.
    func refresh() {
        guard let client else { return }
        guard refreshTask == nil else { return }
        isLoading = true
        refreshTask = Task { [weak self] in
            defer {
                self?.refreshTask = nil
                self?.isLoading = false
            }
            do {
                let updatedEntitlements = try await client.entitlements()
                guard let self else { return }
                let hadActiveSubscription = self.hasActiveSubscription
                self.entitlements = updatedEntitlements
                self.lastError = nil

                // A purchase, restore, or remote backend update can land while the purchase wall
                // is still open. Once the active plan arrives, keep the sheet open but stop
                // presenting it as a subscription requirement; the view then changes in place to
                // the credit/top-up surface with the refreshed balance.
                if !hadActiveSubscription,
                   self.hasActiveSubscription,
                   self.isPaywallPresented,
                   case .subscriptionRequired = self.pendingRefusal {
                    self.pendingRefusal = nil
                }
            } catch is CancellationError {
                return
            } catch {
                // Kept quiet on purpose. A failed entitlement read must not put an error in front
                // of somebody who was doing something else; the surfaces that need it fall back to
                // "unknown", and the server is the one that actually enforces.
                self?.lastError = error.localizedDescription
            }
        }
    }

    /// Keeps the app-level balance and plan cache current while the package-owned purchase UI is
    /// visible. The package completes StoreKit fulfillment internally, so the containing app does
    /// not receive a direct completion callback for purchases started inside `PaywallView`.
    ///
    /// Polling is deliberately scoped to the presented sheet and stops as soon as it closes. A
    /// successful purchase changes the acquisition paywall to the credit controls in place and
    /// refreshes the observable balance without requiring the user to close and reopen the sheet.
    func monitorPresentedPaywall() async {
        while isPaywallPresented, !Task.isCancelled {
            refresh()
            let currentRefresh = refreshTask
            await currentRefresh?.value

            guard isPaywallPresented, !Task.isCancelled else { return }
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
        }
    }

    /// Restores App Store purchases and reloads. Surfaced in Account, where App Review looks for it.
    func restorePurchases() async throws {
        guard let client else { return }
        _ = try await client.restoreApplePurchases()
        refresh()
    }

    /// Drops everything on sign-out.
    ///
    /// The cache is memory-only, so there is nothing on disk for `SharedLogoutPurger` to sweep —
    /// but the next user must not see the last one's balance, and the client is bound to an
    /// `rxlabUserID` that is no longer signed in.
    func reset() {
        clientBindingTask?.cancel()
        clientBindingTask = nil
        bindingUserID = nil
        transactionObserver?.cancel()
        transactionObserver = nil
        refreshTask?.cancel()
        refreshTask = nil
        client = nil
        entitlements = nil
        lastError = nil
        isLoading = false
        isPaywallPresented = false
        pendingRefusal = nil
    }

    /// Raises the paywall, either because the user asked for it or because the server said no.
    func presentPaywall(for refusal: SubscriptionRefusal? = nil) {
        guard isReady else { return }
        guard paywallContent(for: refusal) != .suppressed else {
            // The cached entitlement and the server refusal disagree. Do not upsell an active
            // subscriber; refresh so the rest of the UI converges on the newest backend state.
            refresh()
            return
        }
        pendingRefusal = refusal
        isPaywallPresented = true
    }

    func paywallContent(for refusal: SubscriptionRefusal?) -> SubscriptionPaywallContent {
        SubscriptionPaywallContent.resolve(
            hasActiveSubscription: hasActiveSubscription,
            refusal: refusal
        )
    }

    /// Presents the paywall if this error was a billing refusal, and reports whether it did.
    ///
    /// Call sites hand it whatever the server threw; anything that is not a refusal comes back
    /// `false` and is shown the ordinary way.
    @discardableResult
    func presentPaywallIfRefused(_ error: any Error) -> Bool {
        guard let refusal = error.subscriptionRefusal, isReady else { return false }
        presentPaywall(for: refusal)
        // The balance the server just quoted is newer than the cache, so pull it forward: the
        // paywall should not open showing the count that was already wrong.
        refresh()
        return true
    }

    /// Called when the sheet closes, so the next opening does not inherit the last reason.
    func paywallDismissed() {
        pendingRefusal = nil
        // A purchase inside the sheet lands as a fulfillment the package handled on its own, so
        // this is the moment to pick up whatever it bought.
        refresh()
    }
}
