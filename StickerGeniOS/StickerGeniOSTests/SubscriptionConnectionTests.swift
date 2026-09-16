import Foundation
import RxSubscriptionIOS
import StoreKit
import XCTest
@testable import StickerGeniOS

@MainActor
final class SubscriptionConnectionTests: XCTestCase {
    func testStoreKitErrorSurvivesFailedRetryAndClearsAfterRecoveryAndReset() async throws {
        let appleError = NSError(domain: "ASDErrorDomain", code: 530,
                                 userInfo: [NSLocalizedDescriptionKey: "Unable to Complete Request"])
        var shouldFail = true
        let store = makeStore { refreshing in
            guard shouldFail else { return .sandbox }
            throw SubscriptionStoreKitFailure(StoreKitError.systemError(appleError),
                                              stage: refreshing ? .refreshRequest : .sharedRequest)
        }
        defer { store.reset() }
        store.refresh()
        try await settled(store)
        XCTAssertFalse(store.isReady)
        XCTAssertTrue(try XCTUnwrap(store.connectionDiagnostics).contains("storekit.shared.request"))
        store.retryConnection()
        try await settled(store)
        let report = try XCTUnwrap(store.connectionDiagnostics)
        XCTAssertTrue(report.contains("storekit.refresh.request"))
        XCTAssertTrue(report.contains("ASDErrorDomain (530)"))
        XCTAssertTrue(report.contains("Unable to Complete Request"))
        XCTAssertFalse(store.isReady, "Failed verification must not select a billing environment")
        shouldFail = false
        store.retryConnection()
        try await settled(store)
        XCTAssertTrue(store.isReady)
        XCTAssertNil(store.connectionDiagnostics)
        XCTAssertNil(store.lastError)
        store.reset()
        shouldFail = true
        store.refresh()
        try await settled(store)
        XCTAssertNotNil(store.connectionDiagnostics)
        store.reset()
        XCTAssertNil(store.connectionDiagnostics)
    }

    func testStoreKitFailureKeepsPaywallAccessibleAndExplicitRetryLoadsSandboxBalance() async throws {
        var attempts: [Bool] = []
        let store = makeStore { refreshing in
            attempts.append(refreshing)
            return refreshing ? .sandbox : nil
        }
        defer { store.reset() }
        store.refresh()
        try await settled(store)
        XCTAssertTrue(store.isEnabled)
        XCTAssertFalse(store.isReady)
        XCTAssertNotNil(store.lastError)

        store.presentPaywall()
        try await settled(store)
        XCTAssertTrue(store.isPaywallPresented)
        XCTAssertTrue(attempts.allSatisfy { !$0 }, "Opening the app or sheet must not prompt for App Store credentials")

        store.retryConnection()
        try await settled(store)
        XCTAssertEqual(attempts.last, true)
        XCTAssertTrue(store.isReady)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.credits, 42)
        XCTAssertEqual(store.paywallContent(for: nil), .plans)
        XCTAssertTrue(store.isPaywallPresented)
    }

    func testOrdinaryRefreshRecoversTransientInitializationFailureWithoutStoreKitPrompt() async throws {
        var attempts = 0
        let store = makeStore { refreshing in
            XCTAssertFalse(refreshing)
            attempts += 1
            return attempts == 1 ? nil : .sandbox
        }
        defer { store.reset() }
        store.refresh()
        try await settled(store)
        XCTAssertFalse(store.isReady)
        store.refresh()
        try await settled(store)
        XCTAssertTrue(store.isReady)
        XCTAssertEqual(store.credits, 42)
        XCTAssertEqual(attempts, 2)
    }

    func testMissingSessionCanBeRetriedAfterSharedIdentityArrives() async throws {
        let vault = InMemoryTokenVault()
        let store = makeStore(vault: vault) { _ in .sandbox }
        defer { store.reset() }
        store.refresh()
        try await settled(store)
        XCTAssertFalse(store.isReady)
        XCTAssertNotNil(store.lastError)
        try vault.replace(with: tokenBundle)
        store.refresh()
        try await settled(store)
        XCTAssertEqual(store.client?.user.rxlabUserID, "subscription-test")
        XCTAssertEqual(store.credits, 42)
    }

    func testMissingSandboxKeyCannotFallBackToProduction() async throws {
        let store = makeStore(keys: .init(xcode: nil, sandbox: nil, production: "rxs_pk_production_test")) { _ in .sandbox }
        defer { store.reset() }
        store.refresh()
        try await settled(store)
        XCTAssertTrue(store.isEnabled)
        XCTAssertFalse(store.isReady)
        XCTAssertEqual(store.lastError, SubscriptionConnectionError.notConfigured.localizedDescription)
        store.presentPaywall()
        XCTAssertTrue(store.isPaywallPresented)
    }

    func testResetDuringStoreKitResolutionCannotRestoreSignedOutClient() async throws {
        var pending: CheckedContinuation<SubscriptionEnvironment?, Never>?
        let store = makeStore { _ in
            await withCheckedContinuation { pending = $0 }
        }
        store.refresh()
        for _ in 0..<100 where pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        let continuation = try XCTUnwrap(pending)
        store.reset()
        continuation.resume(returning: .sandbox)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(store.isReady)
        XCTAssertFalse(store.isConnecting)
        XCTAssertNil(store.entitlements)
        XCTAssertNil(store.lastError)
    }

    /// The connection sheet shows its error alert off this count. Were it a flag, or were the
    /// sheet left to watch `isConnecting` fall, a retry failing the same way as the attempt before
    /// it — the common case, since the reason is usually still there — would put nothing on screen
    /// and the user's tap would look ignored.
    func testEveryFailedAttemptIsCountedSeparatelyEvenWhenTheErrorNeverChanges() async throws {
        var shouldFail = true
        let store = makeStore { refreshing in
            guard shouldFail else { return .sandbox }
            throw SubscriptionStoreKitFailure(StoreKitError.systemError(URLError(.timedOut)),
                                              stage: refreshing ? .refreshRequest : .sharedRequest)
        }
        defer { store.reset() }
        store.refresh()
        try await settled(store)
        XCTAssertEqual(store.connectionFailures, 1)
        let firstError = store.lastError
        store.retryConnection()
        try await settled(store)
        XCTAssertEqual(store.lastError, firstError, "This is the case the count exists for")
        XCTAssertEqual(store.connectionFailures, 2)
        shouldFail = false
        store.retryConnection()
        try await settled(store)
        XCTAssertTrue(store.isReady)
        XCTAssertEqual(store.connectionFailures, 2, "A connection that succeeded is not a failure")
    }

    func testLiveConfigurationFailureKeepsControlsWhilePreviewDisablesBilling() {
        let store = makeStore(keys: .init(xcode: nil, sandbox: nil, production: nil)) { _ in .sandbox }
        store.refresh()
        XCTAssertTrue(store.isEnabled)
        XCTAssertNotNil(store.lastError)
        store.presentPaywall()
        XCTAssertTrue(store.isPaywallPresented)
        let preview = SubscriptionStore()
        preview.refresh()
        XCTAssertFalse(preview.isEnabled)
        preview.presentPaywall()
        XCTAssertFalse(preview.isPaywallPresented)
    }

    private var tokenBundle: SharedTokenBundle {
        .init(accessToken: "test-token", expiresAt: .distantFuture, subject: "subscription-test")
    }

    private func makeStore(
        vault: InMemoryTokenVault? = nil,
        keys: SubscriptionPublishableKeys = .init(xcode: nil, sandbox: "rxs_pk_sandbox_test", production: "rxs_pk_production_test"),
        environment: @escaping (Bool) async throws -> SubscriptionEnvironment?
    ) -> SubscriptionStore {
        let url = URL(string: "https://subscription-connection.test")!
        let configuration = AppConfiguration(
            appVersion: "test", appBuild: "1", apiBaseURL: url,
            oauthIssuer: url, oauthTokenURL: url, oauthClientID: "test", oauthRedirectURI: "test://callback",
            subscriptionBaseURL: url, subscriptionPublishableKeys: keys
        )
        let broker = SharedTokenBroker(vault: vault ?? InMemoryTokenVault(tokenBundle),
            transport: URLSessionOAuthRefreshTransport(), tokenURL: url, clientID: "test", lockURL: nil)
        let network = URLSessionConfiguration.ephemeral
        network.protocolClasses = [SubscriptionConnectionProtocol.self]
        return SubscriptionStore(configuration: configuration, tokenBroker: broker,
            environmentProvider: environment, session: URLSession(configuration: network))
    }

    private func settled(_ store: SubscriptionStore) async throws {
        for _ in 0..<200 {
            if !store.isConnecting && !store.isLoading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Subscription connection did not settle")
    }
}

private final class SubscriptionConnectionProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "subscription-connection.test"
    }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        // The real client must use the sandbox key selected from StoreKit.
        let status = request.value(forHTTPHeaderField: "X-Api-Key") == "rxs_pk_sandbox_test" ? 200 : 403
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                      headerFields: ["Content-Type": "application/json"])!
        let json = """
        {"user":{"id":"test","rxlabUserId":"subscription-test","level":0},"plans":[],"roles":[],
         "permissions":[],"features":{},
         "balances":[{"unit":"points","name":"Points","precision":0,"amount":42,"available":42}],"usage":[]}
        """
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
