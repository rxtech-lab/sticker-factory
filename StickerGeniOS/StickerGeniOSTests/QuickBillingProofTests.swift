import Foundation
import Testing
@testable import StickerGeniOS

/// The quick creation client is the transport behind Messages, the App Clip, and the full app's
/// quick screen. All three hold and settle credits, so all three have to carry Apple's signed
/// environment or the server refuses the write — which is what these cover, in the one test target
/// that runs (`StickerMessagesTests` cannot be hosted by an `.appex`).
@Suite("Quick mode billing proof")
struct QuickBillingProofTests {
    @Test("Writes carry Apple's signed billing environment, as the full app's own client does")
    func writeCarriesProof() async throws {
        let transport = QuickProofTransport(statusCode: 202, body: #"{"job":{"id":"job-1","state":"queued"}}"#)
        let client = MessagesStickerCreationClient(
            baseURL: URL(string: "https://api.example/")!,
            transport: transport,
            appTransactionProvider: { "signed.app.transaction" }
        )

        _ = try await client.publish(stickerID: "sticker-1", accessToken: "access-token", idempotencyKey: "publish-key")

        let request = try #require(await transport.request())
        #expect(request.value(forHTTPHeaderField: "X-StoreKit-App-Transaction") == "signed.app.transaction")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
    }

    @Test("Reads carry it too, so the App Clip can ask what its allowance is")
    func readCarriesProof() async throws {
        let transport = QuickProofTransport(
            statusCode: 200,
            body: #"{"id":"sticker-1","title":"Cat","status":"draft","activeRevisionId":null,"revisions":[]}"#
        )
        let client = MessagesStickerCreationClient(
            baseURL: URL(string: "https://api.example/")!,
            transport: transport,
            appTransactionProvider: { "signed.app.transaction" }
        )

        _ = try await client.fetchSticker(stickerID: "sticker-1", accessToken: "access-token")

        let request = try #require(await transport.request())
        #expect(request.value(forHTTPHeaderField: "X-StoreKit-App-Transaction") == "signed.app.transaction")
    }

    @Test("A build without StoreKit proof sends no header rather than an empty one")
    func missingProofSendsNoHeader() async throws {
        let transport = QuickProofTransport(statusCode: 202, body: #"{"job":{"id":"job-1","state":"queued"}}"#)
        let client = MessagesStickerCreationClient(
            baseURL: URL(string: "https://api.example/")!,
            transport: transport,
            appTransactionProvider: { nil }
        )

        _ = try await client.publish(stickerID: "sticker-1", accessToken: "access-token", idempotencyKey: "publish-key")

        let request = try #require(await transport.request())
        #expect(request.value(forHTTPHeaderField: "X-StoreKit-App-Transaction") == nil)
    }

    @Test("A 403 keeps its own message instead of being retried as an expired token")
    func refusalIsNotUnauthorized() async throws {
        let message = "Update the app to verify its billing environment, then try again."
        let client = MessagesStickerCreationClient(
            baseURL: URL(string: "https://api.example/")!,
            transport: QuickProofTransport(
                statusCode: 403,
                body: #"{"error":{"code":"BILLING_ENVIRONMENT_REQUIRED","message":"\#(message)"}}"#
            ),
            appTransactionProvider: { nil }
        )

        await #expect(throws: MessagesStickerCreationError.server(statusCode: 403, message: message)) {
            _ = try await client.publish(stickerID: "sticker-1", accessToken: "access-token", idempotencyKey: "publish-key")
        }
    }
}

private actor QuickProofTransport: StickerHTTPTransport {
    private let statusCode: Int
    private let body: String
    private var capturedRequest: URLRequest?

    init(statusCode: Int, body: String) {
        self.statusCode = statusCode
        self.body = body
    }

    func data(for request: URLRequest) async throws -> StickerHTTPResult {
        capturedRequest = request
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return .init(data: Data(body.utf8), response: response)
    }

    func request() -> URLRequest? { capturedRequest }
}
