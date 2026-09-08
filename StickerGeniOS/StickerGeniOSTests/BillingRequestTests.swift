import Foundation
import Testing
@testable import StickerGeniOS

@Suite("Billing request proof", .serialized)
struct BillingRequestTests {
    @Test("The real API client sends the signed proof alongside OAuth", arguments: ["signed.sandbox.proof", "signed.production.proof"])
    func signedProofHeader(proof: String) async throws {
        let request = try await performRead(proof: proof)
        #expect(request.value(forHTTPHeaderField: "X-StoreKit-App-Transaction") == proof)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        #expect(request.value(forHTTPHeaderField: "X-Subscription-Environment") == nil)
    }

    @Test("Reads remain available when StoreKit cannot supply proof")
    func missingProofRead() async throws {
        let request = try await performRead(proof: nil)
        #expect(request.value(forHTTPHeaderField: "X-StoreKit-App-Transaction") == nil)
    }

    private func performRead(proof: String?) async throws -> URLRequest {
        let vault = InMemoryTokenVault(.init(accessToken: "access-token", refreshToken: "refresh",
            idToken: nil, expiresAt: .distantFuture, subject: "user"))
        let broker = SharedTokenBroker(vault: vault, transport: RejectingRefreshTransport(),
            tokenURL: URL(string: "https://auth.example/token")!, clientID: "ios", lockURL: nil)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BillingRequestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = StickerAPIClient(baseURL: URL(string: "https://billing-request.example")!,
            tokenBroker: broker, session: session, appTransactionProvider: { proof })
        let page = try await api.listStickers(cursor: nil)
        #expect(page.items.isEmpty)
        return try #require(BillingRequestProtocol.capture.get())
    }
}

private final class BillingRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?
    func set(_ value: URLRequest) { lock.withLock { request = value } }
    func get() -> URLRequest? { lock.withLock { request } }
}

private final class BillingRequestProtocol: URLProtocol, @unchecked Sendable {
    static let capture = BillingRequestCapture()
    override static func canInit(with request: URLRequest) -> Bool { request.url?.host == "billing-request.example" }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.capture.set(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":[],"nextCursor":null}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
