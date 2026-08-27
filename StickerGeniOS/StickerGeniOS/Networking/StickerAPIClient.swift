import CryptoKit
import Foundation
import os

nonisolated protocol StickerAPIClientProtocol: Sendable {
    func listStickers(cursor: String?) async throws -> Page<Sticker>
    func createSticker(_ request: CreateStickerRequest, idempotencyKey: String) async throws -> CreateStickerResponse
    func sticker(id: String) async throws -> StickerDetail
    func deleteSticker(id: String, idempotencyKey: String) async throws -> DeleteStickerResponse
    func chatMessages(stickerID: String, beforeSequence: Int?) async throws -> ChatMessagePage
    func sendChatMessage(stickerID: String, request: SendChatMessageRequest, idempotencyKey: String) async throws -> SendChatMessageResponse
    func retryChatMessage(stickerID: String, messageID: String, idempotencyKey: String) async throws -> RetryChatMessageResponse
    func confirmPlan(stickerID: String, planID: String, idempotencyKey: String) async throws -> ConfirmPlanResponse
    func cancelPlan(stickerID: String, planID: String, reason: String?, idempotencyKey: String) async throws -> CancelPlanResponse
    func cancelGeneration(jobID: String, idempotencyKey: String) async throws -> CancelGenerationResponse
    func transitionRevision(stickerID: String, revisionID: String, action: RevisionAction, idempotencyKey: String) async throws -> RevisionTransitionResponse
    func registerExport(stickerID: String, request: PublishExportsRequest, idempotencyKey: String) async throws -> PublishExportsResponse
    func saveEditedDocument(stickerID: String, request: SaveEditedDocumentRequest, idempotencyKey: String) async throws -> SaveEditedDocumentResponse
    func upload(data: Data, stickerID: String?, kind: AssetKind, filename: String, mimeType: String, idempotencyKey: String) async throws -> String
    func assetDownload(assetID: String) async throws -> AssetDownload
    func generationEvents(jobID: String, after lastEventID: Int64?) -> AsyncThrowingStream<GenerationEvent, Error>

    // Marketplace
    func marketplacePacks(sort: PackSort, query: String?, cursor: String?) async throws -> Page<StickerPack>
    func myPacks(cursor: String?) async throws -> Page<StickerPack>
    func packsByCreator(handle: String, cursor: String?) async throws -> CreatorPacksResponse
    func pack(id: String) async throws -> StickerPackDetail
    func createPack(_ request: CreatePackRequest, idempotencyKey: String) async throws -> StickerPackDetail
    func updatePack(id: String, request: UpdatePackRequest, idempotencyKey: String) async throws -> StickerPackDetail
    func setPackItems(id: String, stickerIDs: [String], idempotencyKey: String) async throws -> StickerPackDetail
    func publishPack(id: String, idempotencyKey: String) async throws -> StickerPackDetail
    func unpublishPack(id: String, state: PackState, idempotencyKey: String) async throws -> StickerPackDetail
    func deletePack(id: String, idempotencyKey: String) async throws -> DeletePackResponse
    func installPack(id: String, idempotencyKey: String) async throws -> InstallPackResponse
    func uninstallPack(id: String, idempotencyKey: String) async throws -> InstallPackResponse
    func librarySections(status: LibrarySectionStatus) async throws -> LibrarySectionsResponse
}

nonisolated enum PackSort: String, Sendable, CaseIterable { case recent, popular }

/// `published` is what the Messages extension needs; the app's Library also wants drafts, which
/// are projects in progress rather than junk.
nonisolated enum LibrarySectionStatus: String, Sendable { case published, all }

nonisolated enum RevisionAction: String, Sendable { case accept, reject, revert }

actor StickerAPIClient: StickerAPIClientProtocol {
    nonisolated static let log = Logger(subsystem: "app.rxlab.sticker-factory", category: "events")

    private let baseURL: URL
    private let tokenBroker: SharedTokenBroker
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(baseURL: URL, tokenBroker: SharedTokenBroker, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.tokenBroker = tokenBroker
        self.session = session
        encoder = JSONEncoder.api
        decoder = JSONDecoder.api
    }

    func listStickers(cursor: String?) async throws -> Page<Sticker> {
        try await send(path: "api/v1/stickers", query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
    }

    func createSticker(_ request: CreateStickerRequest, idempotencyKey: String) async throws -> CreateStickerResponse {
        try await send(path: "api/v1/stickers", method: "POST", body: request, idempotencyKey: idempotencyKey)
    }

    func sticker(id: String) async throws -> StickerDetail {
        try await send(path: "api/v1/stickers/\(id)")
    }

    func deleteSticker(id: String, idempotencyKey: String) async throws -> DeleteStickerResponse {
        try await send(path: "api/v1/stickers/\(id)", method: "DELETE", idempotencyKey: idempotencyKey)
    }

    func chatMessages(stickerID: String, beforeSequence: Int?) async throws -> ChatMessagePage {
        try await send(
            path: "api/v1/stickers/\(stickerID)/chat/messages",
            query: beforeSequence.map { [URLQueryItem(name: "beforeSequence", value: String($0))] } ?? []
        )
    }

    func sendChatMessage(stickerID: String, request: SendChatMessageRequest, idempotencyKey: String) async throws -> SendChatMessageResponse {
        try await send(
            path: "api/v1/stickers/\(stickerID)/chat/messages",
            method: "POST",
            body: request,
            idempotencyKey: idempotencyKey
        )
    }

    func retryChatMessage(stickerID: String, messageID: String, idempotencyKey: String) async throws -> RetryChatMessageResponse {
        try await send(
            path: "api/v1/stickers/\(stickerID)/chat/messages/\(messageID)/retry",
            method: "POST",
            idempotencyKey: idempotencyKey
        )
    }

    func confirmPlan(stickerID: String, planID: String, idempotencyKey: String) async throws -> ConfirmPlanResponse {
        try await send(
            path: "api/v1/stickers/\(stickerID)/plans/\(planID)/confirm",
            method: "POST",
            idempotencyKey: idempotencyKey
        )
    }

    func cancelPlan(stickerID: String, planID: String, reason: String?, idempotencyKey: String) async throws -> CancelPlanResponse {
        // The body is omitted entirely when there is no reason: the server only parses one when
        // content-length is non-zero, and an empty `reason` is not a valid request.
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return try await send(
                path: "api/v1/stickers/\(stickerID)/plans/\(planID)/cancel",
                method: "POST",
                idempotencyKey: idempotencyKey
            )
        }
        return try await send(
            path: "api/v1/stickers/\(stickerID)/plans/\(planID)/cancel",
            method: "POST",
            body: CancelPlanRequest(reason: trimmed),
            idempotencyKey: idempotencyKey
        )
    }

    func cancelGeneration(jobID: String, idempotencyKey: String) async throws -> CancelGenerationResponse {
        try await send(
            path: "api/v1/jobs/\(jobID)/cancel",
            method: "POST",
            idempotencyKey: idempotencyKey
        )
    }

    func transitionRevision(stickerID: String, revisionID: String, action: RevisionAction, idempotencyKey: String) async throws -> RevisionTransitionResponse {
        try await send(
            path: "api/v1/stickers/\(stickerID)/revisions/\(revisionID)/\(action.rawValue)",
            method: "POST",
            idempotencyKey: idempotencyKey
        )
    }

    func registerExport(stickerID: String, request: PublishExportsRequest, idempotencyKey: String) async throws -> PublishExportsResponse {
        try await send(
            path: "api/v1/stickers/\(stickerID)/exports",
            method: "POST",
            body: request,
            idempotencyKey: idempotencyKey
        )
    }

    /// Saves an edited document as a new revision.
    ///
    /// The caller mints a fresh idempotency key per attempt, not per editing session: the server
    /// hashes the whole body against the key, so re-sending a *changed* document under a reused key
    /// is a conflict rather than a save.
    func saveEditedDocument(stickerID: String, request: SaveEditedDocumentRequest, idempotencyKey: String) async throws -> SaveEditedDocumentResponse {
        try await send(
            path: "api/v1/stickers/\(stickerID)/revisions",
            method: "POST",
            body: request,
            idempotencyKey: idempotencyKey
        )
    }

    // MARK: - Marketplace

    func marketplacePacks(sort: PackSort, query: String?, cursor: String?) async throws -> Page<StickerPack> {
        var items = [URLQueryItem(name: "sort", value: sort.rawValue)]
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send(path: "api/v1/packs", query: items)
    }

    /// The authoring list. Unlike browse it includes drafts, so it must never back a public view.
    func myPacks(cursor: String?) async throws -> Page<StickerPack> {
        var items = [URLQueryItem(name: "mine", value: "true")]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send(path: "api/v1/packs", query: items)
    }

    func packsByCreator(handle: String, cursor: String?) async throws -> CreatorPacksResponse {
        try await send(
            path: "api/v1/creators/\(handle)",
            query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []
        )
    }

    /// `id` accepts the uuid or the public slug, so a shared link resolves directly.
    func pack(id: String) async throws -> StickerPackDetail {
        try await send(path: "api/v1/packs/\(id)")
    }

    func createPack(_ request: CreatePackRequest, idempotencyKey: String) async throws -> StickerPackDetail {
        try await send(path: "api/v1/packs", method: "POST", body: request, idempotencyKey: idempotencyKey)
    }

    func updatePack(id: String, request: UpdatePackRequest, idempotencyKey: String) async throws -> StickerPackDetail {
        try await send(path: "api/v1/packs/\(id)", method: "PATCH", body: request, idempotencyKey: idempotencyKey)
    }

    /// Replaces the whole membership in order — this is both "set items" and "reorder".
    func setPackItems(id: String, stickerIDs: [String], idempotencyKey: String) async throws -> StickerPackDetail {
        try await send(
            path: "api/v1/packs/\(id)/items",
            method: "PUT",
            body: ReorderPackItemsRequest(stickerIds: stickerIDs),
            idempotencyKey: idempotencyKey
        )
    }

    func publishPack(id: String, idempotencyKey: String) async throws -> StickerPackDetail {
        try await send(path: "api/v1/packs/\(id)/publish", method: "POST", idempotencyKey: idempotencyKey)
    }

    func unpublishPack(id: String, state: PackState, idempotencyKey: String) async throws -> StickerPackDetail {
        try await send(
            path: "api/v1/packs/\(id)/unpublish",
            method: "POST",
            body: UnpublishPackRequest(state: state == .unlisted ? "unlisted" : "draft"),
            idempotencyKey: idempotencyKey
        )
    }

    func deletePack(id: String, idempotencyKey: String) async throws -> DeletePackResponse {
        try await send(path: "api/v1/packs/\(id)", method: "DELETE", idempotencyKey: idempotencyKey)
    }

    func installPack(id: String, idempotencyKey: String) async throws -> InstallPackResponse {
        try await send(path: "api/v1/packs/\(id)/install", method: "POST", idempotencyKey: idempotencyKey)
    }

    func uninstallPack(id: String, idempotencyKey: String) async throws -> InstallPackResponse {
        try await send(path: "api/v1/packs/\(id)/install", method: "DELETE", idempotencyKey: idempotencyKey)
    }

    func librarySections(status: LibrarySectionStatus) async throws -> LibrarySectionsResponse {
        try await send(path: "api/v1/library/sections", query: [URLQueryItem(name: "status", value: status.rawValue)])
    }

    // MARK: - Uploads

    func upload(data: Data, stickerID: String?, kind: AssetKind, filename: String, mimeType: String, idempotencyKey: String) async throws -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let intent: UploadIntentResponse = try await send(
            path: "api/v1/uploads",
            method: "POST",
            body: UploadIntentRequest(stickerId: stickerID, kind: kind, mimeType: mimeType, byteSize: data.count, filename: filename, sha256: digest),
            idempotencyKey: idempotencyKey
        )

        var upload = URLRequest(url: intent.upload.url)
        upload.httpMethod = "PUT"
        upload.httpBody = data
        upload.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        for (name, value) in intent.upload.headers { upload.setValue(value, forHTTPHeaderField: name) }
        let (_, response) = try await session.data(for: upload)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw StickerAPIError.uploadFailed
        }

        let _: AssetRecord = try await send(
            path: "api/v1/uploads/\(intent.asset.id)/complete",
            method: "POST",
            body: CompleteUploadRequest(sha256: digest),
            idempotencyKey: idempotencyKey
        )
        return intent.asset.id
    }

    func assetDownload(assetID: String) async throws -> AssetDownload {
        try await send(path: "api/v1/assets/\(assetID)/download")
    }

    nonisolated func generationEvents(jobID: String, after lastEventID: Int64?) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var cursor = lastEventID
                var failures = 0
                while !Task.isCancelled {
                    do {
                        let outcome = try await self.consumeEventStream(jobID: jobID, after: cursor) { event in
                            cursor = max(cursor ?? 0, event.id)
                            continuation.yield(event)
                        } advanceCursor: { eventID in
                            cursor = max(cursor ?? 0, eventID)
                        }
                        switch outcome {
                        case .terminal:
                            continuation.finish()
                            return
                        case .windowExpired:
                            // A healthy 25s SSE window closed; reconnect immediately from the cursor.
                            failures = 0
                        case .unauthorized:
                            // The token was force-refreshed. Back off like any other failure so a
                            // persistently rejecting endpoint cannot spin without limit.
                            failures += 1
                            if failures >= 5 {
                                continuation.finish(throwing: StickerAPIError.http(401))
                                return
                            }
                            try? await Task.sleep(for: .milliseconds(min(4_000, failures * 500)))
                        }
                    } catch is CancellationError {
                        continuation.finish()
                        return
                    } catch {
                        failures += 1
                        Self.log.error("event stream job=\(jobID, privacy: .public) attempt=\(failures) error=\(String(describing: error), privacy: .public)")
                        if failures >= 5 {
                            continuation.finish(throwing: error)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(min(4_000, failures * 500)))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Why a single SSE connection ended. The caller reconnects for anything but `.terminal`.
    private enum EventStreamOutcome {
        case terminal
        case windowExpired
        case unauthorized
    }

    /// Consumes one SSE connection.
    ///
    /// A malformed frame must never end the turn: the job's terminal `candidate`/`completed`
    /// event is what triggers the client's refetch, so throwing out of this loop on a single
    /// undecodable payload would strand the chat with no assistant message. Bad frames are
    /// logged, their id is still consumed so the reconnect does not replay them, and the loop
    /// continues.
    private func consumeEventStream(
        jobID: String,
        after lastEventID: Int64?,
        receive: (GenerationEvent) -> Void,
        advanceCursor: (Int64) -> Void
    ) async throws -> EventStreamOutcome {
        var request = try await authorizedRequest(path: "api/v1/jobs/\(jobID)/events")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Defeat any intermediary that would buffer a compressed body instead of flushing frames.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 60
        if let lastEventID { request.setValue(String(lastEventID), forHTTPHeaderField: "Last-Event-ID") }

        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw StickerAPIError.invalidResponse }
        Self.log.debug("event stream open job=\(jobID, privacy: .public) status=\(response.statusCode) after=\(lastEventID ?? 0)")
        if response.statusCode == 401 {
            _ = try await tokenBroker.validAccessToken(forceRefresh: true)
            return .unauthorized
        }
        guard (200...299).contains(response.statusCode) else { throw StickerAPIError.http(response.statusCode) }
        let terminalHeader = SSEStreamTermination.isTerminal(jobState: response.value(forHTTPHeaderField: "x-job-state"))

        var dataLines: [String] = []
        var frameID: Int64?
        var received = 0
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.isEmpty {
                defer {
                    dataLines.removeAll(keepingCapacity: true)
                    frameID = nil
                }
                guard !dataLines.isEmpty else { continue }
                let data = Data(dataLines.joined(separator: "\n").utf8)
                do {
                    let event = try decoder.decode(GenerationEvent.self, from: data)
                    received += 1
                    Self.log.debug("event job=\(jobID, privacy: .public) id=\(event.id) type=\(event.type.rawValue, privacy: .public)")
                    receive(event)
                    if event.type == .completed || event.type == .failed { return .terminal }
                } catch {
                    Self.log.error("undecodable event job=\(jobID, privacy: .public) id=\(frameID ?? -1) error=\(String(describing: error), privacy: .public)")
                    if let frameID { advanceCursor(frameID) }
                }
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("id:") {
                frameID = Int64(String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces))
            }
        }
        Self.log.debug("event stream closed job=\(jobID, privacy: .public) received=\(received) terminalHeader=\(terminalHeader)")
        return terminalHeader ? .terminal : .windowExpired
    }

    private func send<Response: Decodable & Sendable>(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        idempotencyKey: String? = nil
    ) async throws -> Response {
        try await send(path: path, method: method, query: query, bodyData: nil, idempotencyKey: idempotencyKey)
    }

    private func send<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: Body,
        idempotencyKey: String? = nil
    ) async throws -> Response {
        try await send(path: path, method: method, query: query, bodyData: try encoder.encode(body), idempotencyKey: idempotencyKey)
    }

    private func send<Response: Decodable & Sendable>(
        path: String,
        method: String,
        query: [URLQueryItem],
        bodyData: Data?,
        idempotencyKey: String?
    ) async throws -> Response {
        var request = try await authorizedRequest(path: path, query: query)
        request.httpMethod = method
        request.httpBody = bodyData
        if bodyData != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw StickerAPIError.invalidResponse }
        if response.statusCode == 401 {
            request.setValue("Bearer \(try await tokenBroker.validAccessToken(forceRefresh: true))", forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await session.data(for: request)
            return try decode(retryData, response: retryResponse)
        }
        return try decode(data, response: response)
    }

    private func authorizedRequest(path: String, query: [URLQueryItem] = []) async throws -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await tokenBroker.validAccessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func decode<Response: Decodable>(_ data: Data, response: URLResponse) throws -> Response {
        guard let response = response as? HTTPURLResponse else { throw StickerAPIError.invalidResponse }
        guard (200...299).contains(response.statusCode) else {
            if let envelope = try? decoder.decode(APIErrorEnvelope.self, from: data) { throw envelope }
            throw StickerAPIError.http(response.statusCode)
        }
        if Response.self == EmptyResponse.self, data.isEmpty { return EmptyResponse() as! Response }
        return try decoder.decode(Response.self, from: data)
    }
}

nonisolated enum SSEStreamTermination {
    static func isTerminal(jobState: String?) -> Bool {
        guard let jobState else { return false }
        return ["succeeded", "failed", "cancelled"].contains(jobState)
    }
}

nonisolated struct EmptyResponse: Codable, Sendable {}

nonisolated enum StickerAPIError: Error, LocalizedError, Equatable {
    case invalidResponse
    case http(Int)
    case uploadFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The server returned an invalid response."
        case .http(let code): "The request failed (HTTP \(code))."
        case .uploadFailed: "The media upload could not be completed."
        }
    }
}

extension JSONEncoder {
    nonisolated static var api: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    nonisolated static var api: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let whole = ISO8601DateFormatter()
            whole.formatOptions = [.withInternetDateTime]
            if let date = whole.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date")
        }
        return decoder
    }
}
