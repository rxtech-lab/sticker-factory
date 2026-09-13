import Foundation
import Observation
import OSLog
import RxSubscriptionIOS
import StoreKit

nonisolated enum SubscriptionDiagnostics {
    static let logger = Logger(subsystem: "app.rxlab.stickerfactory", category: "Subscriptions")

    /// Only diagnostic codes are public; never log credentials, receipts, or user information.
    static func failure(_ error: Error, stage: String) {
        let nsError = error as NSError
        logger.error("""
            stage=\(stage, privacy: .public) error_type=\(String(reflecting: type(of: error)), privacy: .public) \
            domain=\(nsError.domain, privacy: .public) code=\(nsError.code)
            """)
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            logger.error("""
                stage=\(stage, privacy: .public) underlying_domain=\(underlying.domain, privacy: .public) \
                underlying_code=\(underlying.code)
                """)
        }
    }
}

nonisolated extension SubscriptionEnvironment {
    static func currentVerified(refreshing: Bool = false) async throws -> Self? {
        // Refresh can ask for App Store credentials, so only a user's retry requests it.
        let source = refreshing ? "storekit.refresh" : "storekit.shared"
        let result: VerificationResult<AppTransaction>
        do {
            SubscriptionDiagnostics.logger.info("stage=\(source, privacy: .public) started")
            if refreshing {
                result = try await AppTransaction.refresh()
            } else {
                result = try await AppTransaction.shared
            }
        } catch {
            SubscriptionDiagnostics.failure(error, stage: "\(source).request")
            throw SubscriptionStoreKitFailure(error, stage: refreshing ? .refreshRequest : .sharedRequest)
        }
        switch result {
        case .unverified(_, let error):
            SubscriptionDiagnostics.failure(error, stage: "\(source).verification")
            throw SubscriptionStoreKitFailure(error, stage: refreshing ? .refreshVerification : .sharedVerification)
        case .verified(let appTransaction):
            let environment: Self?
            if appTransaction.environment == .xcode {
                environment = .xcode
            } else if appTransaction.environment == .sandbox {
                environment = .sandbox
            } else if appTransaction.environment == .production {
                environment = .production
            } else {
                environment = nil
            }
            SubscriptionDiagnostics.logger.info("""
                stage=\(source, privacy: .public) verified \
                environment=\(environment?.rawValue ?? "unsupported", privacy: .public)
                """)
            return environment
        }
    }
}

nonisolated enum SubscriptionConnectionError: LocalizedError {
    case notConfigured
    case appStoreUnavailable

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            String(localized: "Subscriptions are not configured in this version of the app. Please update the app and try again.")
        case .appStoreUnavailable:
            String(localized: "We couldn’t verify this installation with the App Store. Check your connection and try again.")
        }
    }
}

nonisolated enum SubscriptionAccess {
    /// Keep this aligned with the subscription backend's live entitlement statuses.
    private static let activeStatuses = Set(["active", "trialing", "past_due"])

    static func isActive(status: String) -> Bool {
        activeStatuses.contains(status)
    }

    static func canPublishPacks(permissions: [String]) -> Bool {
        permissions.contains("marketplace.publish") || permissions.contains("marketplace.publish:all")
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
/// they have" — questions asked from a toolbar and from a service, neither
/// of which should be issuing its own network call.
///
/// Deliberately not the enforcement point. The server holds the secret key and decides whether a
/// generation may run; this only decides what to *show*. A stale cache here can put a paywall up a
/// moment late, which is a cosmetic problem, not a revenue one.
@MainActor
@Observable
final class SubscriptionStore {
    private(set) var entitlements: Entitlements?
    private(set) var isLoading = false
    private(set) var isConnecting = false
    private(set) var lastError: String?
    private(set) var connectionDiagnostics: String?

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
    @ObservationIgnored private let environmentProvider: (Bool) async throws -> SubscriptionEnvironment?
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var clientBindingTask: Task<Void, Never>?
    @ObservationIgnored private var connectionID: UUID?
    @ObservationIgnored private var transactionObserver: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Live accounts keep their subscription entry points during setup and failures.
    /// The empty store used by previews and ordinary UI tests disables billing entirely.
    var isEnabled: Bool { tokenBroker != nil || client != nil }

    /// Whether this build has the URL and at least one valid publishable key.
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

    /// The server enforces publishing access while entitlements are still loading.
    var canPublishPacks: Bool {
        guard isConfigured, let entitlements else { return true }
        return SubscriptionAccess.canPublishPacks(permissions: entitlements.permissions)
    }

    init(
        configuration: AppConfiguration,
        tokenBroker: SharedTokenBroker,
        environmentProvider: @escaping (Bool) async throws -> SubscriptionEnvironment? = { refreshing in
            try await SubscriptionEnvironment.currentVerified(refreshing: refreshing)
        },
        session: URLSession = .shared
    ) {
        self.serverURL = configuration.subscriptionBaseURL
        self.publishableKeys = configuration.subscriptionPublishableKeys
        self.tokenBroker = tokenBroker
        self.environmentProvider = environmentProvider
        self.session = session
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
        self.environmentProvider = { _ in nil }
        self.session = .shared
    }

    #if DEBUG
    convenience init(uiTestClient: Client) {
        self.init()
        self.client = uiTestClient
        self.pendingRefusal = .insufficientCredits(required: nil, available: nil)
        self.isPaywallPresented = true
    }
    #endif

    deinit {
        clientBindingTask?.cancel()
        transactionObserver?.cancel()
    }

    /// Resolves identity and StoreKit before making a client. Failed attempts can be retried
    /// on foregrounding or from the visible subscription sheet, without signing out.
    private func connect(refreshingStoreKit: Bool = false) {
        guard isEnabled, clientBindingTask == nil else { return }
        guard let serverURL, let tokenBroker, publishableKeys.hasAnyKey else {
            SubscriptionDiagnostics.logger.error("""
                stage=configuration url_present=\(self.serverURL != nil) \
                key_present=\(self.publishableKeys.hasAnyKey)
                """)
            lastError = SubscriptionConnectionError.notConfigured.localizedDescription
            return
        }
        let attempt = UUID()
        connectionID = attempt
        isConnecting = true
        lastError = nil
        connectionDiagnostics = nil
        let environmentProvider = self.environmentProvider
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        SubscriptionDiagnostics.logger.info("""
            stage=connection started version=\(version, privacy: .public) build=\(build, privacy: .public) \
            storekit_refresh=\(refreshingStoreKit)
            """)

        clientBindingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.connectionID == attempt {
                    self.connectionID = nil
                    self.clientBindingTask = nil
                    self.isConnecting = false
                }
            }
            var stage = "identity"
            do {
                guard let subject = try await tokenBroker.currentBundle()?.subject, !subject.isEmpty else {
                    throw TokenBrokerError.missingSession
                }
                guard !Task.isCancelled, self.connectionID == attempt else { return }
                stage = "storekit.environment"
                let environment = try await environmentProvider(refreshingStoreKit)
                guard !Task.isCancelled, self.connectionID == attempt else { return }
                guard let environment else { throw SubscriptionConnectionError.appStoreUnavailable }
                stage = "configuration.\(environment.rawValue)"
                guard let publishableKey = self.publishableKeys.key(for: environment) else {
                    throw SubscriptionConnectionError.notConfigured
                }

                let client = Client(
                    serverURL: serverURL,
                    publishableKey: publishableKey,
                    rxlabUserID: subject,
                    userToken: { forceRefresh in
                        try await tokenBroker.validAccessToken(forceRefresh: forceRefresh)
                    },
                    session: self.session
                )
                self.client = client
                self.lastError = nil
                SubscriptionDiagnostics.logger.info("stage=connection ready environment=\(environment.rawValue, privacy: .public)")
                self.transactionObserver = client.observeTransactionUpdates { [weak self] _ in
                    self?.refresh()
                }
                self.refresh()
            } catch {
                guard !Task.isCancelled, self.connectionID == attempt else { return }
                self.lastError = error.localizedDescription
                if let failure = error as? SubscriptionStoreKitFailure {
                    self.connectionDiagnostics = failure.report(
                        version: version, build: build,
                        operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString
                    )
                }
                SubscriptionDiagnostics.failure(error, stage: stage)
                AppTelemetry.failure(error, operation: "subscription_connection")
            }
        }
    }

    /// Only the user's retry may invoke StoreKit's authentication prompt.
    func retryConnection() {
        guard client == nil else { refresh(); return }
        connect(refreshingStoreKit: true)
    }

    /// Reloads the cache, coalescing overlapping calls.
    ///
    /// Several surfaces refresh on appear and the open paywall monitors for fulfillment; without
    /// this a user returning to the Library after buying credits would fire duplicate requests.
    func refresh() {
        guard let client else { connect(); return }
        guard refreshTask == nil else { return }
        isLoading = true
        refreshTask = Task { [weak self] in
            defer {
                if self?.client === client {
                    self?.refreshTask = nil
                    self?.isLoading = false
                }
            }
            do {
                let updatedEntitlements = try await client.entitlements()
                guard let self, self.client === client, !Task.isCancelled else { return }
                let hadActiveSubscription = self.hasActiveSubscription
                self.entitlements = updatedEntitlements
                self.lastError = nil
                SubscriptionDiagnostics.logger.info("stage=entitlements loaded")

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
                guard self?.client === client, !Task.isCancelled else { return }
                // Kept quiet on purpose. A failed entitlement read must not put an error in front
                // of somebody who was doing something else; the surfaces that need it fall back to
                // "unknown", and the server is the one that actually enforces.
                self?.lastError = error.localizedDescription
                SubscriptionDiagnostics.failure(error, stage: "entitlements")
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
        return try await AppTelemetry.measure(.restorePurchases) {
            guard let client else { throw SubscriptionConnectionError.appStoreUnavailable }
            _ = try await client.restoreApplePurchases()
            refresh()
        }
    }

    /// Drops everything on sign-out.
    ///
    /// The cache is memory-only, so there is nothing on disk for `SharedLogoutPurger` to sweep —
    /// but the next user must not see the last one's balance, and the client is bound to an
    /// `rxlabUserID` that is no longer signed in.
    func reset() {
        clientBindingTask?.cancel()
        clientBindingTask = nil
        connectionID = nil
        isConnecting = false
        transactionObserver?.cancel()
        transactionObserver = nil
        refreshTask?.cancel()
        refreshTask = nil
        client = nil
        entitlements = nil
        lastError = nil
        connectionDiagnostics = nil
        isLoading = false
        isPaywallPresented = false
        pendingRefusal = nil
    }

    /// Raises the paywall, either because the user asked for it or because the server said no.
    func presentPaywall(for refusal: SubscriptionRefusal? = nil) {
        guard isEnabled else { return }
        guard paywallContent(for: refusal) != .suppressed else {
            // The cached entitlement and the server refusal disagree. Do not upsell an active
            // subscriber; refresh so the rest of the UI converges on the newest backend state.
            refresh()
            return
        }
        if !isPaywallPresented {
            AppTelemetry.event("paywall_viewed", parameters: ["reason": refusal == nil ? "user" : "refusal"])
        }
        pendingRefusal = refusal
        isPaywallPresented = true
        if client == nil { refresh() }
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
        guard let refusal = error.subscriptionRefusal, isEnabled else { return false }
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
