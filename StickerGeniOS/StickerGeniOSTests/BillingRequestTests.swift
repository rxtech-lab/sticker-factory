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

/// The proof cache is what keeps a billing write from ever going out unsigned.
///
/// Before it, every request read `AppTransaction.shared` afresh on the calling task, so one
/// StoreKit hiccup — or one cancelled caller, which stopping a turn produces — sent the next write
/// with no proof and earned a 403 the user had to retype their message past.
@Suite("Billing proof cache")
struct BillingProofCacheTests {
    @Test("Everyone waiting on the first resolution shares it, rather than each reading StoreKit")
    func concurrentCallersShareOneResolution() async throws {
        let resolver = ScriptedProofResolver(["signed.proof"], delay: .milliseconds(50))
        let cache = QuickAppTransaction.Cache()

        let proofs = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<8 {
                group.addTask { await cache.value(refreshing: false) { await resolver.next() } }
            }
            return await group.reduce(into: [String?]()) { $0.append($1) }
        }

        #expect(proofs == Array(repeating: "signed.proof", count: 8))
        #expect(await resolver.count == 1)
    }

    @Test("A resolved proof is kept, so no later request pays StoreKit again")
    func resolvedProofIsReused() async throws {
        let resolver = ScriptedProofResolver(["signed.proof", "never.asked.for"])
        let cache = QuickAppTransaction.Cache()

        #expect(await cache.value(refreshing: false) { await resolver.next() } == "signed.proof")
        #expect(await cache.value(refreshing: false) { await resolver.next() } == "signed.proof")
        #expect(await resolver.count == 1)
    }

    @Test("A failed resolution is not kept, so a first attempt made offline can still succeed later")
    func failureIsNotCached() async throws {
        let resolver = ScriptedProofResolver([nil, "signed.proof"])
        let cache = QuickAppTransaction.Cache()

        #expect(await cache.value(refreshing: false) { await resolver.next() } == nil)
        #expect(await cache.value(refreshing: false) { await resolver.next() } == "signed.proof")
        #expect(await resolver.count == 2)
    }

    @Test("Refreshing discards the cached proof, which is what a refusal asks for")
    func refreshResolvesAgain() async throws {
        let resolver = ScriptedProofResolver(["first.proof", "second.proof"])
        let cache = QuickAppTransaction.Cache()

        #expect(await cache.value(refreshing: false) { await resolver.next() } == "first.proof")
        #expect(await cache.value(refreshing: true) { await resolver.next() } == "second.proof")
        #expect(await cache.value(refreshing: false) { await resolver.next() } == "second.proof")
        #expect(await resolver.count == 2)
    }

    @Test("A caller cancelled mid-resolve still gets a proof, because the resolution is not its own")
    func cancelledCallerStillResolves() async throws {
        let cache = QuickAppTransaction.Cache()
        let caller = Task {
            await cache.value(refreshing: false) {
                // Reports what the *resolving* task saw. Resolved on the caller's task — as every
                // request used to — this returns nil the moment that caller is cancelled.
                try? await Task.sleep(for: .milliseconds(50))
                return Task.isCancelled ? nil : "signed.proof"
            }
        }
        try await Task.sleep(for: .milliseconds(5))
        caller.cancel()

        #expect(await caller.value == "signed.proof")
    }
}

private actor ScriptedProofResolver {
    private var answers: [String?]
    private let delay: Duration
    private(set) var count = 0

    init(_ answers: [String?], delay: Duration = .zero) {
        self.answers = answers
        self.delay = delay
    }

    func next() async -> String? {
        count += 1
        if delay != .zero { try? await Task.sleep(for: delay) }
        return answers.isEmpty ? nil : answers.removeFirst()
    }
}

/// A write the server refused only because it arrived without Apple's signed environment is the one
/// 403 worth a second attempt: nothing was reserved, nothing was charged, and the request still
/// carries its idempotency key. Recovering it here is what the user sees as the message simply
/// going through.
@Suite("Billing proof refusal recovery", .serialized)
struct BillingProofRetryTests {
    @Test("A write refused for want of proof is retried carrying a freshly resolved one")
    func retriesWithRefreshedProof() async throws {
        BillingRetryProtocol.reset(refusalCode: "BILLING_ENVIRONMENT_REQUIRED")
        let response = try await sendChatMessage(proof: nil, refreshed: "refreshed.proof")

        #expect(response.job.id == "job-1")
        let attempts = BillingRetryProtocol.attempts()
        #expect(attempts.count == 2)
        #expect(attempts.first?.value(forHTTPHeaderField: "X-StoreKit-App-Transaction") == nil)
        #expect(attempts.last?.value(forHTTPHeaderField: "X-StoreKit-App-Transaction") == "refreshed.proof")
        // The retry is the same request, so the server's idempotency key must survive it.
        #expect(attempts.last?.value(forHTTPHeaderField: "Idempotency-Key") == "send-key")
    }

    @Test("A 403 a new proof cannot fix is reported as it stands, not retried")
    func doesNotRetryUnrelatedRefusals() async throws {
        BillingRetryProtocol.reset(refusalCode: "OAUTH_CLIENT_NOT_ALLOWED")

        await #expect(throws: APIErrorEnvelope.self) {
            _ = try await sendChatMessage(proof: "signed.proof", refreshed: "refreshed.proof")
        }
        #expect(BillingRetryProtocol.attempts().count == 1)
    }

    @Test("A refusal that StoreKit still cannot answer keeps the server's own words")
    func keepsRefusalWhenStoreKitStaysUnavailable() async throws {
        BillingRetryProtocol.reset(refusalCode: "BILLING_ENVIRONMENT_REQUIRED")

        await #expect(throws: APIErrorEnvelope.self) {
            _ = try await sendChatMessage(proof: nil, refreshed: nil)
        }
        #expect(BillingRetryProtocol.attempts().count == 1)
    }

    private func sendChatMessage(proof: String?, refreshed: String?) async throws -> SendChatMessageResponse {
        let vault = InMemoryTokenVault(.init(accessToken: "access-token", refreshToken: "refresh",
            idToken: nil, expiresAt: .distantFuture, subject: "user"))
        let broker = SharedTokenBroker(vault: vault, transport: RejectingRefreshTransport(),
            tokenURL: URL(string: "https://auth.example/token")!, clientID: "ios", lockURL: nil)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BillingRetryProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = StickerAPIClient(baseURL: URL(string: "https://billing-retry.example")!,
            tokenBroker: broker, session: session,
            appTransactionProvider: { proof }, appTransactionRefresher: { refreshed })
        return try await api.sendChatMessage(
            stickerID: "sticker-1",
            request: .init(text: "make it blue", intent: .chat, attachments: [],
                targetLayerId: nil, imagePlacement: .replace, baseRevisionId: nil),
            idempotencyKey: "send-key"
        )
    }
}

private final class BillingRetryState: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var code = "BILLING_ENVIRONMENT_REQUIRED"

    func reset(refusalCode: String) { lock.withLock { requests = []; code = refusalCode } }
    func attempts() -> [URLRequest] { lock.withLock { requests } }
    /// The first attempt is refused; a second one has, by definition, come back with a new proof.
    func record(_ request: URLRequest) -> (status: Int, body: String) {
        lock.withLock {
            requests.append(request)
            guard requests.count == 1 else { return (status: 200, body: Self.accepted) }
            let refusal = """
                {"error":{"code":"\(code)",\
                "message":"Update the app to verify its billing environment, then try again.",\
                "requestId":"request-1"}}
                """
            return (status: 403, body: refusal)
        }
    }

    private static let accepted = """
        {"message":{"id":"message-1","status":"streaming"},\
        "job":{"id":"job-1","state":"queued","workflowRunId":null,\
        "eventsUrl":"/api/v1/jobs/job-1/events"}}
        """
}

private final class BillingRetryProtocol: URLProtocol, @unchecked Sendable {
    private static let state = BillingRetryState()
    static func reset(refusalCode: String) { state.reset(refusalCode: refusalCode) }
    static func attempts() -> [URLRequest] { state.attempts() }

    override static func canInit(with request: URLRequest) -> Bool { request.url?.host == "billing-retry.example" }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.state.record(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
