import Foundation
import Testing
import UIKit
@testable import StickerMessages

@Suite("Messages sticker creation")
struct MessagesStickerCreationTests {
    @MainActor
    @Test("Reference photos are normalized to the server's input budget")
    func referenceNormalization() throws {
        let input = UIGraphicsImageRenderer(size: CGSize(width: 3_000, height: 1_500))
            .jpegData(withCompressionQuality: 1) { context in
                UIColor.systemBlue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 3_000, height: 1_500))
            }
        let reference = try MessagesReferenceImageNormalizer.normalize(input, index: 2)
        let decoded = try #require(UIImage(data: reference.data))

        #expect(decoded.size.width == 2_048)
        #expect(decoded.size.height == 1_024)
        #expect(reference.filename == "messages-reference-2.jpg")
        #expect(reference.mimeType == "image/jpeg")
        #expect(reference.data.count <= MessagesReferenceImageNormalizer.maximumByteCount)
    }

    @Test("Creation request keeps the prompt, kind, references, and idempotency key")
    func creationRequest() async throws {
        let transport = CreationRequestTransport()
        let client = MessagesStickerCreationClient(
            baseURL: URL(string: "https://api.example/")!,
            transport: transport,
            appTransactionProvider: { nil }
        )
        let prompt = String(repeating: "A", count: 70)
        let created = try await client.createSticker(
            kind: .animated,
            prompt: prompt,
            referenceAssetIDs: ["asset-1", "asset-2"],
            accessToken: "access-token",
            idempotencyKey: "creation-key"
        )

        #expect(created.stickerID == "4a1ef35b-436f-481a-b733-43a890da6154")
        #expect(created.jobID == "job-1")
        let request = try #require(await transport.request())
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "creation-key")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["title"] as? String == String(prompt.prefix(64)))
        #expect(json["kind"] as? String == "animated")
        #expect(json["prompt"] as? String == prompt)
        #expect(json["referenceAssetIds"] as? [String] == ["asset-1", "asset-2"])
    }
}

private actor CreationRequestTransport: StickerHTTPTransport {
    private var capturedRequest: URLRequest?

    func data(for request: URLRequest) async throws -> StickerHTTPResult {
        capturedRequest = request
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 202,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return .init(
            data: Data("""
            {"stickerId":"4a1ef35b-436f-481a-b733-43a890da6154","job":{"id":"job-1"}}
            """.utf8),
            response: response
        )
    }

    func request() -> URLRequest? { capturedRequest }
}
