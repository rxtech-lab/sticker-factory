import CryptoKit
import Foundation
import UIKit

nonisolated enum MessagesStickerKind: String, Codable, CaseIterable, Sendable {
    case staticSticker = "static"
    case animated

    var label: String {
        switch self {
        case .staticSticker: String(localized: "Static")
        case .animated: String(localized: "Animated")
        }
    }
}

nonisolated struct MessagesReferenceImage: Identifiable, Sendable {
    static let maximumCount = 8
    static let maximumCombinedByteCount = 32 * 1024 * 1024

    let id: UUID
    let data: Data
    let filename: String
    let mimeType: String

    init(id: UUID = UUID(), data: Data, filename: String, mimeType: String) {
        self.id = id
        self.data = data
        self.filename = filename
        self.mimeType = mimeType
    }
}

nonisolated enum MessagesReferenceImageNormalizer {
    static let maximumDimension: CGFloat = 2_048
    static let maximumByteCount = 25 * 1024 * 1024
    static let minimumDimension: CGFloat = 64

    @MainActor
    static func normalize(_ data: Data, index: Int) throws -> MessagesReferenceImage {
        guard let source = UIImage(data: data) else {
            throw MessagesStickerCreationError.unreadableImage
        }
        guard source.size.width >= minimumDimension, source.size.height >= minimumDimension else {
            throw MessagesStickerCreationError.imageTooSmall
        }

        let hasAlpha = sourceMayContainAlpha(source)
        let image = resizedToFit(source, maximumDimension: maximumDimension, opaque: !hasAlpha)
        let encoded: Data
        let filename: String
        let mimeType: String
        if hasAlpha, let png = image.pngData() {
            encoded = png
            filename = "messages-reference-\(index).png"
            mimeType = "image/png"
        } else if let jpeg = image.jpegData(compressionQuality: 0.9) {
            encoded = jpeg
            filename = "messages-reference-\(index).jpg"
            mimeType = "image/jpeg"
        } else {
            throw MessagesStickerCreationError.unreadableImage
        }
        guard encoded.count <= maximumByteCount else {
            throw MessagesStickerCreationError.imageTooLarge
        }
        return MessagesReferenceImage(data: encoded, filename: filename, mimeType: mimeType)
    }

    @MainActor
    private static func resizedToFit(
        _ image: UIImage,
        maximumDimension: CGFloat,
        opaque: Bool
    ) -> UIImage {
        let scale = min(1, maximumDimension / max(image.size.width, image.size.height))
        let size = CGSize(
            width: max(1, image.size.width * scale),
            height: max(1, image.size.height * scale)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func sourceMayContainAlpha(_ image: UIImage) -> Bool {
        guard let alpha = image.cgImage?.alphaInfo else { return false }
        return [.first, .last, .premultipliedFirst, .premultipliedLast].contains(alpha)
    }
}

nonisolated struct MessagesCreatedSticker: Equatable, Sendable {
    let stickerID: String
    let jobID: String
}

nonisolated enum MessagesStickerCreationError: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case invalidResponse
    case unauthorized
    case server(statusCode: Int, message: String?)
    case uploadFailed(statusCode: Int)
    case unreadableImage
    case imageTooSmall
    case imageTooLarge
    case tooManyReferences
    case referencesTooLarge
    case timedOut
    case notPublished(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            String(localized: "The sticker service is not configured in this build.")
        case .invalidResponse:
            String(localized: "The sticker service returned an invalid response.")
        case .unauthorized:
            String(localized: "Open the main app and sign in before creating a sticker here.")
        case .server(let statusCode, let message):
            // The status code rides along when the server sent no words of its own. It is not
            // pretty, but "try again" with nothing behind it is untraceable — for the user
            // reporting it and for whoever reads the report.
            message ?? String(localized: "The sticker service could not be reached (HTTP \(statusCode)). Try again.")
        case .uploadFailed(let statusCode):
            String(localized: "A reference image could not be uploaded (HTTP \(statusCode)).")
        case .unreadableImage:
            String(localized: "That image format could not be read.")
        case .imageTooSmall:
            String(localized: "Reference images must be at least 64 pixels per side.")
        case .imageTooLarge:
            String(localized: "That reference image is too large.")
        case .tooManyReferences:
            String(localized: "You can attach up to eight reference images.")
        case .referencesTooLarge:
            String(localized: "Those reference images are too large together. Remove one and try again.")
        case .timedOut:
            String(localized: "This is taking longer than expected. It is still running — open the main app to pick it up.")
        case .notPublished(let reason):
            reason
        }
    }
}

/// Where this build talks to, resolved once.
///
/// Shared by the creation client and `MessagesJobWatcher` — the watcher needs the same host and the
/// same rules about which ones are allowed, and two copies of that check is one copy too many for
/// something that decides whether an access token may leave the device over plain HTTP.
nonisolated enum MessagesAPIConfiguration {
    static func baseURL(bundle: Bundle = .main) throws -> URL {
        guard let value = bundle.object(forInfoDictionaryKey: "StickerFactoryAPIBaseURL") as? String,
              !value.isEmpty,
              !value.contains("$("),
              let url = URL(string: value),
              isAllowed(url) else {
            throw MessagesStickerCreationError.invalidConfiguration
        }
        return url
    }

    private static func isAllowed(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        #if DEBUG
        return url.scheme?.lowercased() == "http" && url.host?.lowercased() == "localhost"
        #else
        return false
        #endif
    }
}

/// What quick mode knows about a sticker between generation and publication.
///
/// A narrow read of `GET /api/v1/stickers/{id}`: the extension needs the artwork to show and
/// whether the sticker is live yet, and nothing else on that response is its business.
nonisolated struct MessagesStickerSnapshot: Sendable {
    struct Revision: Sendable {
        let id: String
        let candidateState: String
        let previewAssetID: String?
        let kind: MessagesStickerKind
    }

    let stickerID: String
    let title: String
    let status: String
    let activeRevisionID: String?
    /// Newest first, as the endpoint orders them.
    let revisions: [Revision]

    var isPublished: Bool { status == "published" }

    /// The artwork the result screen should show: the outstanding candidate if the user has not
    /// published it yet, otherwise whatever is live.
    var displayRevision: Revision? {
        revisions.first { $0.candidateState == "candidate" }
            ?? revisions.first { $0.id == activeRevisionID }
            ?? revisions.first
    }
}

nonisolated struct MessagesUploadDestination: Sendable {
    let url: URL
    let headers: [String: String]
}

nonisolated struct MessagesUploadIntent: Sendable {
    let assetID: String
    let digest: String
    let upload: MessagesUploadDestination
}

/// Creation transport shared by Messages, the App Clip, and the full app quick screen.
/// Rich editing continues to use the full app project client.
nonisolated struct MessagesStickerCreationClient: Sendable {
    private let baseURL: URL
    private let transport: any StickerHTTPTransport
    private let useQuickModeAllowance: Bool
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(bundle: Bundle = .main, transport: any StickerHTTPTransport) throws {
        baseURL = try MessagesAPIConfiguration.baseURL(bundle: bundle)
        self.transport = transport
        useQuickModeAllowance = false
    }

    init(baseURL: URL, transport: any StickerHTTPTransport, useQuickModeAllowance: Bool = false) {
        self.baseURL = baseURL
        self.transport = transport
        self.useQuickModeAllowance = useQuickModeAllowance
    }

    func createUploadIntent(
        reference: MessagesReferenceImage,
        accessToken: String,
        idempotencyKey: String
    ) async throws -> MessagesUploadIntent {
        let digest = SHA256.hash(data: reference.data).map { String(format: "%02x", $0) }.joined()
        let body = QuickCreateUploadRequest(
            kind: "reference",
            mimeType: reference.mimeType,
            byteSize: reference.data.count,
            filename: reference.filename,
            sha256: digest
        )
        let data = try await send(
            path: "api/v1/uploads",
            method: "POST",
            body: body,
            accessToken: accessToken,
            idempotencyKey: idempotencyKey
        )
        let response: QuickCreateUploadResponse = try decode(data)
        return MessagesUploadIntent(
            assetID: response.asset.id,
            digest: digest,
            upload: MessagesUploadDestination(url: response.upload.url, headers: response.upload.headers)
        )
    }

    func upload(reference: MessagesReferenceImage, to destination: MessagesUploadDestination) async throws {
        var request = URLRequest(url: destination.url)
        request.httpMethod = "PUT"
        request.httpBody = reference.data
        request.timeoutInterval = 180
        request.setValue(reference.mimeType, forHTTPHeaderField: "Content-Type")
        for (name, value) in destination.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let result = try await transport.data(for: request)
        guard (200 ..< 300).contains(result.response.statusCode) else {
            throw MessagesStickerCreationError.uploadFailed(statusCode: result.response.statusCode)
        }
    }

    func completeUpload(
        assetID: String,
        digest: String,
        accessToken: String,
        idempotencyKey: String
    ) async throws {
        _ = try await send(
            path: "api/v1/uploads/\(assetID)/complete",
            method: "POST",
            body: QuickCompleteUploadRequest(sha256: digest),
            accessToken: accessToken,
            idempotencyKey: idempotencyKey
        )
    }

    func createSticker(
        kind: MessagesStickerKind,
        prompt: String,
        referenceAssetIDs: [String],
        accessToken: String,
        idempotencyKey: String
    ) async throws -> MessagesCreatedSticker {
        let data = try await send(
            path: "api/v1/stickers",
            method: "POST",
            body: QuickCreateStickerRequest(
                title: String(prompt.prefix(64)),
                kind: kind.rawValue,
                prompt: prompt,
                referenceAssetIds: referenceAssetIDs,
                useQuickModeAllowance: useQuickModeAllowance ? true : nil
            ),
            accessToken: accessToken,
            idempotencyKey: idempotencyKey
        )
        let response: QuickCreateStickerResponse = try decode(data)
        return MessagesCreatedSticker(stickerID: response.stickerId, jobID: response.job.id)
    }

    // MARK: - Quick mode

    /// The sticker's current shape: what to draw, and whether it is live yet.
    func fetchSticker(stickerID: String, accessToken: String) async throws -> MessagesStickerSnapshot {
        let data = try await get(path: "api/v1/stickers/\(stickerID)", accessToken: accessToken)
        let response: QuickStickerDetailResponse = try decode(data)
        return response.snapshot()
    }

    /// Asks for a change to the sticker, and returns the job that will make it.
    ///
    /// The chat endpoint, used without a chat: quick mode shows no transcript and offers no
    /// conversation, but a revision *is* a turn on the server and inventing a second way to ask for
    /// one would fork the two surfaces' history. What the extension leaves behind is a thread the
    /// main app can open and carry on.
    func revise(
        stickerID: String,
        prompt: String,
        accessToken: String,
        idempotencyKey: String
    ) async throws -> String {
        let data = try await send(
            path: "api/v1/stickers/\(stickerID)/chat/messages",
            method: "POST",
            body: QuickChatMessageRequest(text: prompt, intent: "edit", useQuickModeAllowance: useQuickModeAllowance ? true : nil),
            accessToken: accessToken,
            idempotencyKey: idempotencyKey
        )
        let response: QuickJobEnvelope = try decode(data)
        return try response.jobID()
    }

    /// Starts the server-rendered publish behind quick mode.
    func publish(
        stickerID: String,
        accessToken: String,
        idempotencyKey: String
    ) async throws -> String {
        let data = try await send(
            path: "api/v1/stickers/\(stickerID)/publish",
            method: "POST",
            body: QuickEmptyRequest(),
            accessToken: accessToken,
            idempotencyKey: idempotencyKey
        )
        let response: QuickJobEnvelope = try decode(data)
        return try response.jobID()
    }

    private func get(path: String, accessToken: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let result = try await transport.data(for: request)
        if result.response.statusCode == 401 || result.response.statusCode == 403 {
            throw MessagesStickerCreationError.unauthorized
        }
        guard (200 ..< 300).contains(result.response.statusCode) else {
            let envelope = try? decoder.decode(QuickAPIErrorEnvelope.self, from: result.data)
            throw MessagesStickerCreationError.server(
                statusCode: result.response.statusCode,
                message: envelope?.error.message
            )
        }
        return result.data
    }

    private func send<Body: Encodable>(
        path: String,
        method: String,
        body: Body,
        accessToken: String,
        idempotencyKey: String
    ) async throws -> Data {
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = try encoder.encode(body)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")

        let result = try await transport.data(for: request)
        if result.response.statusCode == 401 || result.response.statusCode == 403 {
            throw MessagesStickerCreationError.unauthorized
        }
        guard (200 ..< 300).contains(result.response.statusCode) else {
            let envelope = try? decoder.decode(QuickAPIErrorEnvelope.self, from: result.data)
            throw MessagesStickerCreationError.server(
                statusCode: result.response.statusCode,
                message: envelope?.error.message
            )
        }
        return result.data
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            throw MessagesStickerCreationError.invalidResponse
        }
    }
}

nonisolated private struct QuickCreateUploadRequest: Encodable {
    let stickerId: String? = nil
    let kind: String
    let mimeType: String
    let byteSize: Int
    let filename: String
    let sha256: String
    let sequence: String? = nil
}

nonisolated private struct QuickCreateUploadResponse: Decodable {
    struct Asset: Decodable { let id: String }
    struct Upload: Decodable {
        let url: URL
        let headers: [String: String]
    }

    let asset: Asset
    let upload: Upload
}

nonisolated private struct QuickCompleteUploadRequest: Encodable {
    let sha256: String
}

nonisolated private struct QuickCreateStickerRequest: Encodable {
    let title: String
    let kind: String
    let prompt: String
    let referenceAssetIds: [String]
    let useQuickModeAllowance: Bool?
    /// Always true here. It puts the turn on the server's quick image model, which draws in a
    /// fraction of the time the main one takes and is keyed out of a coloured background rather
    /// than arriving transparent. That is the right trade for someone holding a conversation open
    /// waiting to send something; the main app, where the artwork is going to be edited and
    /// published, keeps the slower model.
    let quick = true
}

nonisolated private struct QuickCreateStickerResponse: Decodable {
    struct Job: Decodable { let id: String }
    let stickerId: String
    let job: Job
}

nonisolated private struct QuickAPIErrorEnvelope: Decodable {
    struct Details: Decodable {
        let message: String
    }
    let error: Details
}

nonisolated private struct QuickEmptyRequest: Encodable {}

nonisolated private struct QuickChatMessageRequest: Encodable {
    let text: String
    /// Always an edit. Quick mode never asks for a plan or a chat reply — the one thing its Revise
    /// box means is "change the picture" — and `generate` would start a fresh concept rather than
    /// alter the one the user is looking at.
    let intent: String
    let useQuickModeAllowance: Bool?
    /// A revision is drawn by the same quick model that drew what the user is looking at, for the
    /// same reason and with the same trade.
    let quick = true
}

/// The `{ job: { id, state } }` both quick-mode POSTs answer with.
nonisolated private struct QuickJobEnvelope: Decodable {
    struct Job: Decodable {
        let id: String
        let state: String
    }

    let job: Job

    /// A dispatch that failed before the job ever ran. Watching it would wait out the whole
    /// deadline for a stream that will never produce a frame.
    func jobID() throws -> String {
        guard job.state != "failed" else {
            throw MessagesStickerCreationError.server(
                statusCode: 502,
                message: String(localized: "The sticker service could not start that. Try again.")
            )
        }
        return job.id
    }
}

nonisolated private struct QuickStickerDetailResponse: Decodable {
    struct Revision: Decodable {
        struct Document: Decodable { let kind: String }
        let id: String
        let candidateState: String
        let previewAssetId: String?
        let document: Document
    }

    let id: String
    let title: String
    let status: String
    let activeRevisionId: String?
    let revisions: [Revision]

    func snapshot() -> MessagesStickerSnapshot {
        MessagesStickerSnapshot(
            stickerID: id,
            title: title,
            status: status,
            activeRevisionID: activeRevisionId,
            revisions: revisions.map {
                MessagesStickerSnapshot.Revision(
                    id: $0.id,
                    candidateState: $0.candidateState,
                    previewAssetID: $0.previewAssetId,
                    // A document this build has no case for is treated as static: the kind only
                    // decides how the preview is labelled here, and refusing to show a sticker over
                    // a word we do not recognise would be a worse failure than mislabelling it.
                    kind: MessagesStickerKind(rawValue: $0.document.kind) ?? .staticSticker
                )
            }
        )
    }
}
