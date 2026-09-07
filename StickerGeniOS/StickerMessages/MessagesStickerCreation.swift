import Foundation

/// Starts generation from the Messages extension while keeping every long-running generation step
/// on the server. Once `create` returns, the job survives the extension closing or being reclaimed.
actor MessagesStickerCreationService {
    private let tokenBroker: SharedTokenBroker
    private let client: MessagesStickerCreationClient
    /// Quick mode's two extra needs: watching a job to its end, and fetching the candidate's
    /// artwork. Absent under the test init, which stubs the HTTP transport and never reaches them.
    private let watcher: MessagesJobWatcher?
    private let assets: StickerLibraryClient?

    init(bundle: Bundle = .main, session: URLSession = .shared) throws {
        let authConfiguration = try SharedAuthConfiguration(bundle: bundle)
        tokenBroker = SharedTokenBroker(configuration: authConfiguration, session: session)
        client = try MessagesStickerCreationClient(
            bundle: bundle,
            transport: URLSessionStickerHTTPTransport(session: session)
        )
        watcher = MessagesJobWatcher(
            baseURL: try MessagesAPIConfiguration.baseURL(bundle: bundle),
            session: session
        )
        assets = try StickerLibraryClient(bundle: bundle, session: session)
    }

    init(
        tokenBroker: SharedTokenBroker,
        client: MessagesStickerCreationClient,
        watcher: MessagesJobWatcher? = nil,
        assets: StickerLibraryClient? = nil
    ) {
        self.tokenBroker = tokenBroker
        self.client = client
        self.watcher = watcher
        self.assets = assets
    }

    func create(
        kind: MessagesStickerKind,
        prompt: String,
        references: [MessagesReferenceImage]
    ) async throws -> MessagesCreatedSticker {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.count <= 4_000 else {
            throw MessagesStickerCreationError.invalidResponse
        }
        guard references.count <= MessagesReferenceImage.maximumCount else {
            throw MessagesStickerCreationError.tooManyReferences
        }
        guard references.reduce(0, { $0 + $1.data.count }) <= MessagesReferenceImage.maximumCombinedByteCount else {
            throw MessagesStickerCreationError.referencesTooLarge
        }

        var assetIDs: [String] = []
        for reference in references {
            let intentKey = UUID().uuidString
            let intent = try await authorized { token in
                try await client.createUploadIntent(
                    reference: reference,
                    accessToken: token,
                    idempotencyKey: intentKey
                )
            }
            try await client.upload(reference: reference, to: intent.upload)
            let completeKey = UUID().uuidString
            try await authorized { token in
                try await client.completeUpload(
                    assetID: intent.assetID,
                    digest: intent.digest,
                    accessToken: token,
                    idempotencyKey: completeKey
                )
            }
            assetIDs.append(intent.assetID)
        }

        let creationKey = UUID().uuidString
        let referenceAssetIDs = assetIDs
        return try await authorized { token in
            try await client.createSticker(
                kind: kind,
                prompt: prompt,
                referenceAssetIDs: referenceAssetIDs,
                accessToken: token,
                idempotencyKey: creationKey
            )
        }
    }

    // MARK: - Quick mode

    /// Waits for a job to finish, and turns anything but success into a thrown error.
    ///
    /// Quick mode has one path through the screen and no place to put a half-finished job, so a
    /// failure is raised where the caller already handles errors rather than returned as a state
    /// every call site would have to remember to check.
    func awaitJob(
        _ jobID: String,
        onProgress: @Sendable @escaping (MessagesJobProgress) -> Void
    ) async throws {
        guard let watcher else { throw MessagesStickerCreationError.invalidConfiguration }
        let outcome = try await authorized { token in
            try await watcher.watch(jobID: jobID, accessToken: token, onProgress: onProgress)
        }
        switch outcome {
        case .succeeded:
            return
        case .failed(let message):
            throw MessagesStickerCreationError.notPublished(message)
        case .cancelled:
            throw CancellationError()
        }
    }

    func snapshot(stickerID: String) async throws -> MessagesStickerSnapshot {
        try await authorized { token in
            try await client.fetchSticker(stickerID: stickerID, accessToken: token)
        }
    }

    /// Asks for a change and hands back the job that will make it.
    func revise(stickerID: String, prompt: String) async throws -> String {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.count <= 4_000 else {
            throw MessagesStickerCreationError.invalidResponse
        }
        let key = UUID().uuidString
        return try await authorized { token in
            try await client.revise(
                stickerID: stickerID,
                prompt: prompt,
                accessToken: token,
                idempotencyKey: key
            )
        }
    }

    /// Starts the publish that makes the sticker sendable, and hands back its job.
    func publish(stickerID: String) async throws -> String {
        let key = UUID().uuidString
        return try await authorized { token in
            try await client.publish(stickerID: stickerID, accessToken: token, idempotencyKey: key)
        }
    }

    /// The candidate's artwork, for the preview shown before it is published.
    ///
    /// The master rendition rather than a thumbnail: it is the only rendition a candidate has, and
    /// the ceiling below is the full-size surface's, not Apple's 500 KB sticker limit — this file
    /// is being drawn on screen, not inserted into a conversation.
    func preview(assetID: String) async throws -> Data {
        guard let assets else { throw MessagesStickerCreationError.invalidConfiguration }
        return try await authorized { token in
            do {
                return try await assets.download(
                    assetID: assetID,
                    accessToken: token,
                    maximumByteCount: 12 * 1024 * 1024
                ).data
            } catch StickerLibraryError.unauthorized {
                // Restated in this file's vocabulary so `authorized` recognises it and refreshes,
                // rather than surfacing an expired token as a dead preview.
                throw MessagesStickerCreationError.unauthorized
            }
        }
    }

    private func authorized<Value: Sendable>(
        _ operation: @Sendable (String) async throws -> Value
    ) async throws -> Value {
        let session = try await tokenBroker.authenticatedSession()
        do {
            return try await operation(session.accessToken)
        } catch MessagesStickerCreationError.unauthorized {
            let refreshed = try await tokenBroker.authenticatedSession(forceRefresh: true)
            return try await operation(refreshed.accessToken)
        }
    }
}
