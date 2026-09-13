#if DEBUG
import Foundation
import StoreKit

/// Uses the real connection, client and paywall after a simulated StoreKit failure.
/// No Apple credentials or production requests are involved in this UI test.
nonisolated final class SubscriptionConnectionFixture: URLProtocol, @unchecked Sendable {
    @MainActor static func makeStore() -> SubscriptionStore {
        let configuration = AppConfiguration(
            appVersion: "test", appBuild: "1",
            apiBaseURL: URL(string: "https://subscription-ui-test.invalid")!,
            oauthIssuer: URL(string: "https://subscription-ui-test.invalid")!,
            oauthTokenURL: URL(string: "https://subscription-ui-test.invalid/token")!,
            oauthClientID: "ui-test", oauthRedirectURI: "stickerfactory://oauth/callback",
            subscriptionBaseURL: URL(string: "https://subscription-ui-test.invalid")!,
            subscriptionPublishableKeys: .init(xcode: nil, sandbox: "rxs_pk_sandbox_ui_test", production: nil)
        )
        let broker = SharedTokenBroker(
            vault: FixtureVault(), transport: URLSessionOAuthRefreshTransport(),
            tokenURL: configuration.oauthTokenURL, clientID: configuration.oauthClientID, lockURL: nil
        )
        let network = URLSessionConfiguration.ephemeral
        network.protocolClasses = [Self.self]
        var retryCount = 0
        return SubscriptionStore(
            configuration: configuration, tokenBroker: broker,
            environmentProvider: { refreshing in
                if refreshing {
                    retryCount += 1
                    if retryCount > 1 { return .sandbox }
                }
                let underlying = NSError(domain: "ASDErrorDomain", code: 530,
                                         userInfo: [NSLocalizedDescriptionKey: "Unable to Complete Request"])
                throw SubscriptionStoreKitFailure(StoreKitError.systemError(underlying),
                                                  stage: refreshing ? .refreshRequest : .sharedRequest)
            },
            session: URLSession(configuration: network)
        )
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "subscription-ui-test.invalid"
    }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let json: String
        if request.url?.path == "/api/v1/paywall" {
            json = """
            {"id":"test-paywall","name":"Plans","designVersion":1,"publishedAt":"2026-09-12T00:00:00Z",
             "spec":{"version":1,"theme":{"colorScheme":"system","colors":{"primary":"#2563EB","background":"#FFFFFF",
             "foreground":"#0F172A","muted":"#64748B","accent":"#F59E0B"},"cornerRadius":14,"fontDesign":"default"},
             "root":{"id":"root","type":"VStack","props":{"spacing":20},"children":[
               {"id":"title","type":"Text","props":{"text":"Choose your plan","style":"largeTitle"}},
               {"id":"plans","type":"ProductList","props":{"layout":"vertical","style":"card"},"products":[
                 {"id":"monthly","key":"monthly","name":"Monthly Points","planGroup":"default","billingInterval":"month",
                  "intervalCount":1,"priceAmountCents":1399,"currency":"usd","trialDays":0,"priceLabel":"$13.99",
                  "periodLabel":"per month","purchaseOptions":[{"provider":"apple_app_store","flow":"storekit",
                  "productId":"test.monthly","productType":"auto_renewable_subscription"}]}]}
             ]}}}
            """
        } else {
            json = """
            {"user":{"id":"test","rxlabUserId":"subscription-ui-test","level":0},"plans":[],"roles":[],
             "permissions":[],"features":{},
             "balances":[{"unit":"points","name":"Points","precision":0,"amount":42,"available":42}],"usage":[]}
            """
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private final class FixtureVault: SharedTokenVaultProtocol, Sendable {
        func load() throws -> SharedTokenBundle? {
            .init(accessToken: "ui-test-token", expiresAt: .distantFuture, subject: "subscription-ui-test")
        }
        func replace(with bundle: SharedTokenBundle) throws {}
        func clear() throws {}
    }
}
#endif
