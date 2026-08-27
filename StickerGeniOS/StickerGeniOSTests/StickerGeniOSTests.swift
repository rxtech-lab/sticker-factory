import AnimatedView
import CryptoKit
import Foundation
import Testing
import UIKit
@testable import StickerGeniOS

@Suite("Sticker document and API contracts")
struct StickerContractTests {
    @Test("Sticker image cache processor rejects checksum mismatches")
    func cachedStickerVerification() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.purple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let data = try #require(image.pngData())
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        #expect(VerifiedStickerImageProcessor(expectedSHA256: digest).accepts(data))
        #expect(!VerifiedStickerImageProcessor(expectedSHA256: String(repeating: "0", count: 64)).accepts(data))
    }

    @Test("Canonical server fixture decodes, validates, and round-trips")
    func canonicalDocumentFixture() throws {
        let data = try fixtureData("sticker-document-v2")
        let document = try JSONDecoder.api.decode(AnimatedDocument.self, from: data)
        let validated = try document.validated()

        #expect(validated.version == AnimatedDocument.currentVersion)
        #expect(validated.canvas.coordinateSpace == "normalized")
        #expect(validated.kind == .animated)
        #expect(validated.layers.count == 2)
        #expect(try JSONDecoder.api.decode(AnimatedDocument.self, from: JSONEncoder.api.encode(validated)) == validated)
    }

    /// The server authors motion declaratively and ships both representations: `animations` (the
    /// named effects) alongside `animation` (their compiled keyframes). The renderer only ever
    /// reads the compiled keyframes. The app used to *drop* the declarative half on decode, which
    /// was safe only because it never sent a document back; now that it can, both halves round-trip
    /// and this pins that the compiled keyframes are still what plays.
    @Test("A server-compiled declarative layer decodes into playable keyframes")
    func declarativeLayerCompilesToKeyframes() throws {
        let document = try JSONDecoder.api.decode(AnimatedDocument.self, from: fixtureData("sticker-document-v2"))
        guard case .particle(let layer) = document.layers[1] else {
            #expect(Bool(false), "Fixture must contain its declarative particle layer")
            return
        }
        // popIn with a 0.4s delay over 0.5s: invisible until 0.4, fully present by 0.9.
        #expect(layer.animation.opacity.map(\.timeSeconds) == [0.4, 0.9])
        #expect(layer.animation.opacity.map(\.value) == [0, 1])
        #expect(layer.animation.scale.map(\.timeSeconds) == [0.4, 0.9])
        // Layout rides on a single t=0 anchor keyframe, exactly as a static layout would.
        #expect(layer.animation.position.count == 1)
        #expect(layer.animation.position[0].timeSeconds == 0)

        let state = AnimationInterpolator.state(for: document.layers[1], atDocumentTime: 0.2)
        #expect(state.opacity == 0)
        let settled = AnimationInterpolator.state(for: document.layers[1], atDocumentTime: 0.9)
        #expect(settled.opacity == 1)
    }

    @Test("Validation rejects an out-of-bounds streamed keyframe")
    func rejectsOutOfBoundsKeyframe() throws {
        var document = try JSONDecoder.api.decode(AnimatedDocument.self, from: fixtureData("sticker-document-v2"))
        guard case .image(var layer) = document.layers[0] else {
            #expect(Bool(false), "Fixture must contain its canonical image layer")
            return
        }
        layer.animation.position[0].x = 2.01
        document.layers[0] = .image(layer)

        #expect(throws: AnimatedDocumentError.self) { try document.validated() }
    }

    @Test("Canonical API fixture preserves system sticker limits and dates")
    func apiFixture() throws {
        let root = try JSONDecoder.api.decode(APIFixture.self, from: fixtureData("api-responses-v1"))
        #expect(root.stickerList.items.count == 1)
        #expect(root.stickerList.items[0].systemSticker?.byteSize == 482_100)
        #expect((root.stickerList.items[0].systemSticker?.byteSize ?? 500_000) < 500_000)
        #expect(root.assetDownload.asset.state == .ready)
        #expect(root.assetDownload.asset.frameCount == 60)
        #expect(root.assetDownload.asset.durationSeconds == 2)
        #expect(root.assetDownload.asset.fps == 30)
        #expect(root.chatMessages.nextBeforeSequence == nil)
        #expect(root.publishExports.mp4Background == .linearGradient(colors: ["#112233", "#445566"], angleDegrees: 30))
        #expect(root.publishExports.mp4AssetId == "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")
    }

    @Test("Marketplace fixtures decode with their creator byline and install count")
    func marketplaceFixture() throws {
        let root = try JSONDecoder.api.decode(APIFixture.self, from: fixtureData("api-responses-v1"))

        let pack = try #require(root.packList.items.first)
        #expect(pack.installCount == 128)
        #expect(pack.installCountLabel == "128 installs")
        #expect(pack.installed == false)
        #expect(pack.isMine == false)
        #expect(pack.creator.byline == "Mika Lin")
        #expect(pack.state == .published)
        #expect(pack.monetization.priceCents == 0)

        #expect(root.packDetail.installed)
        #expect(root.packDetail.stickers.count == 1)
        // A pack member is a plain Sticker — the server reuses StickerSummaryV1 verbatim, which is
        // why no second sticker model exists on this side.
        #expect(root.packDetail.stickers[0].systemSticker?.assetId == "44444444-4444-4444-8444-444444444444")

        let sections = root.librarySections.sections
        #expect(sections.map(\.kind) == [.mine, .pack])
        // "My Stickers" is always first and carries no byline.
        #expect(sections[0].creator == nil)
        #expect(sections[0].packId == nil)
        #expect(sections[1].creator?.handle == "mika-lin-4f2a9c")
        #expect(sections[1].packId == "11111111-1111-4111-8111-111111111111")
        #expect(root.librarySections.packSections.count == 1)
        // The section's system rendition is the same asset the download envelope describes, so a
        // section can be taken straight to a download without another lookup.
        #expect(sections[0].stickers[0].systemSticker?.assetId == root.assetDownload.asset.id)
    }

    @Test("An unrecognized pack state degrades instead of failing the page")
    func unknownPackStateDecodes() throws {
        // A newer server adding a state must not poison a whole page of packs.
        let state = try JSONDecoder.api.decode(PackState.self, from: Data("\"archived\"".utf8))
        #expect(state == .unknown)
        let kind = try JSONDecoder.api.decode(LibrarySectionKind.self, from: Data("\"bundle\"".utf8))
        // Falling back to `.pack` is the safe reading: treating it as "mine" would imply the user
        // can edit stickers they do not own.
        #expect(kind == .pack)
    }

    @Test("Async response envelopes and chat pagination match the backend")
    func asyncResponseEnvelopes() throws {
        let job = """
        {"id":"11111111-1111-4111-8111-111111111111","state":"queued","workflowRunId":"run-1","eventsUrl":"/api/v1/jobs/111/events"}
        """
        let create = try JSONDecoder.api.decode(CreateStickerResponse.self, from: Data("""
        {"stickerId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","threadId":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","initialMessageId":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","job":\(job)}
        """.utf8))
        let chat = try JSONDecoder.api.decode(SendChatMessageResponse.self, from: Data("""
        {"message":{"id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","status":"complete"},"job":\(job)}
        """.utf8))
        let retry = try JSONDecoder.api.decode(RetryChatMessageResponse.self, from: Data("""
        {"messageId":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","job":\(job)}
        """.utf8))
        let cancelled = try JSONDecoder.api.decode(CancelGenerationResponse.self, from: Data("""
        {"jobId":"11111111-1111-4111-8111-111111111111","state":"cancelled"}
        """.utf8))
        let toolEvent = try JSONDecoder.api.decode(GenerationEvent.self, from: Data("""
        {"id":3,"jobId":"11111111-1111-4111-8111-111111111111","type":"progress","createdAt":"2026-08-24T12:00:00Z","data":{"toolCallId":"22222222-2222-4222-8222-222222222222","toolName":"show-sticker","toolStatus":"streaming"}}
        """.utf8))
        let exports = try JSONDecoder.api.decode(PublishExportsResponse.self, from: Data(("{\"job\":" + job + "}").utf8))
        let page = try JSONDecoder.api.decode(ChatMessagePage.self, from: Data("{\"data\":[],\"nextBeforeSequence\":41}".utf8))

        #expect(create.job.id == chat.job.id)
        #expect(retry.messageId == chat.message.id)
        #expect(cancelled.state == .cancelled)
        #expect(toolEvent.data.toolName == "show-sticker")
        #expect(toolEvent.data.toolStatus == .streaming)
        #expect(exports.job.state == .queued)
        #expect(page.nextBeforeSequence == 41)

        let fractionalAsset = try JSONDecoder.api.decode(AssetRecord.self, from: Data("""
        {"id":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","stickerId":null,"kind":"gif","state":"ready","mimeType":"image/gif","byteSize":100,"width":300,"height":300,"frameCount":60,"durationSeconds":1.8,"fps":33.3333333333,"sha256":null,"hasAlpha":true,"createdAt":"2026-08-24T12:00:00Z"}
        """.utf8))
        #expect(abs((fractionalAsset.fps ?? 0) - 33.3333333333) < 0.000_000_001)

        let deletion = try JSONDecoder.api.decode(DeleteStickerResponse.self, from: Data("""
        {"stickerId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","status":"deleting","job":{"id":"ffffffff-ffff-4fff-8fff-ffffffffffff","state":"queued","workflowRunId":"cleanup-run","retryable":false}}
        """.utf8))
        #expect(deletion.status == .deleting)
        #expect(deletion.job.retryable == false)
    }

    @Test("Static export registration uses pngAssetId, not source masterAssetId")
    func staticExportRequestField() throws {
        let value = PublishExportsRequest(
            revisionId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            pngAssetId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            gifAssetId: nil,
            mp4AssetId: nil,
            systemAssetId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            mp4Background: nil
        )
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder.api.encode(value)) as? [String: Any])
        #expect(object["pngAssetId"] as? String == value.pngAssetId)
        #expect(object["masterAssetId"] == nil)
        #expect(object["mp4Background"] == nil)
    }

    @Test("Animated export registration preserves its rendered MP4 background")
    func animatedExportBackgroundField() throws {
        let value = PublishExportsRequest(
            revisionId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            pngAssetId: nil,
            gifAssetId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            mp4AssetId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            systemAssetId: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            mp4Background: .linearGradient(colors: ["#112233", "#AABBCC"], angleDegrees: 42)
        )
        let data = try JSONEncoder.api.encode(value)
        let decoded = try JSONDecoder.api.decode(PublishExportsRequest.self, from: data)
        #expect(decoded.mp4Background == value.mp4Background)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let background = try #require(object["mp4Background"] as? [String: Any])
        #expect(background["type"] as? String == "linearGradient")
        #expect(background["angleDegrees"] as? Double == 42)
    }

    @Test("Nested validation details remain decodable")
    func nestedAPIErrorDetails() throws {
        let envelope = try JSONDecoder.api.decode(APIErrorEnvelope.self, from: Data("""
        {"error":{"code":"VALIDATION_FAILED","message":"Invalid request","requestId":"request-1","details":{"issues":[{"path":["attachments",0,"assetId"],"message":"Invalid UUID"}],"retryable":false}}}
        """.utf8))
        guard case .object(let details) = envelope.error.details,
              case .array(let issues) = details["issues"]
        else {
            #expect(Bool(false), "Nested error details should decode as JSON values")
            return
        }
        #expect(issues.count == 1)
        #expect(details["retryable"] == .bool(false))
    }
}

@Suite("Interpolation and export policy")
struct StickerRenderingPolicyTests {
    @Test("Linear interpolation and ping-pong timing are deterministic")
    func interpolationAndPingPong() {
        let animation = StickerLayerAnimationV1(position: [
            .init(timeSeconds: 0, x: 0, y: 0.25, easing: .linear),
            .init(timeSeconds: 2, x: 1, y: 0.75, easing: .linear),
        ])
        let layer = StickerLayerV1.shape(.init(id: "shape", name: "Shape", animation: animation, shape: .circle, fill: "#FFFFFF"))
        let document = AnimatedDocument(kind: .animated, durationSeconds: 2, fps: 30, loop: .pingPong, layers: [layer])
        let midpoint = StickerInterpolator.state(for: layer, at: 1, in: document)

        #expect(abs(midpoint.position.x - 0.5) < 0.000_001)
        #expect(abs(StickerInterpolator.mappedTime(3, document: document) - 1) < 0.000_001)
        #expect(StickerInterpolator.renderedCycleDuration(document) == 4)
        #expect(StickerExportMetadataPolicy.frameCount(document: document, fps: 30) == 120)
    }

    @Test("MP4 is opaque and adaptive system renditions use the expected presets")
    func exportMetadataPolicy() {
        #expect(!StickerExportMetadataPolicy.hasAlpha(for: .mp4))
        #expect(StickerExportMetadataPolicy.hasAlpha(for: .gif))
        // Dimension is what the recipient perceives as sticker size, so the ladder spends frame
        // rate and color depth first and only concedes pixels once those are exhausted.
        #expect(SystemStickerPreset.adaptive.map(\.dimension) == [618, 618, 618, 408, 408, 300, 300, 300])
        // Monotonic: a rung never costs more bytes than the one it falls back from.
        #expect(zip(SystemStickerPreset.adaptive, SystemStickerPreset.adaptive.dropFirst()).allSatisfy {
            $1.dimension <= $0.dimension && ($1.dimension < $0.dimension || $1.fps <= $0.fps)
        })
        // Dense art needs the 300 @ 8 floor; without it the export fails instead of shrinking.
        #expect(SystemStickerPreset.adaptive.last == .init(dimension: 300, fps: 8, colorLevels: 8))
        // The server's adaptive floor is 8 FPS; no rung may fall through it.
        #expect(SystemStickerPreset.adaptive.allSatisfy { $0.fps >= 8 })
    }

    @Test("GIF centisecond delays preserve a 30 FPS cycle duration")
    func gifCentisecondTiming() {
        let delays = StickerExportMetadataPolicy.gifFrameDelays(frameCount: 60, fps: 30)
        #expect(delays.count == 60)
        #expect(delays.filter { abs($0 - 0.03) < 0.000_001 }.count == 40)
        #expect(delays.filter { abs($0 - 0.04) < 0.000_001 }.count == 20)
        #expect(abs(delays.reduce(0, +) - 2) < 0.000_001)
    }

    @Test("The loop hold lingers on the last frame without adding one")
    func loopHoldTiming() {
        let held = StickerExportMetadataPolicy.gifFrameDelays(frameCount: 60, fps: 30, holdSeconds: 0.6)
        let plain = StickerExportMetadataPolicy.gifFrameDelays(frameCount: 60, fps: 30)
        // Same grid: a hold is display time on a frame that already exists, never an extra frame.
        #expect(held.count == plain.count)
        #expect(Array(held.dropLast()) == Array(plain.dropLast()))
        #expect(abs(held[59] - (plain[59] + 0.6)) < 0.000_001)
        #expect(abs(held.reduce(0, +) - 2.6) < 0.000_001)

        // A play-once export has no repeat to separate, so it is never held.
        #expect(StickerExportMetadataPolicy.holdSeconds(for: .once) == 0)
        #expect(StickerExportMetadataPolicy.holdSeconds(for: .loop) == StickerExportMetadataPolicy.loopHoldSeconds)
        #expect(StickerExportMetadataPolicy.holdSeconds(for: .pingPong) == StickerExportMetadataPolicy.loopHoldSeconds)
    }

    @Test("Rendered duration is the motion cycle plus the hold, and the frame grid is unchanged")
    func renderedDurationIncludesHold() {
        let layer = StickerLayerV1.shape(.init(id: "shape", name: "Shape", shape: .circle, fill: "#FFFFFF"))
        let pingPong = AnimatedDocument(kind: .animated, durationSeconds: 2, fps: 30, loop: .pingPong, layers: [layer])
        let once = AnimatedDocument(kind: .animated, durationSeconds: 2, fps: 30, loop: .once, layers: [layer])

        #expect(abs(StickerExportMetadataPolicy.renderedDuration(pingPong) - 4.6) < 0.000_001)
        #expect(abs(StickerExportMetadataPolicy.renderedDuration(once) - 2) < 0.000_001)
        // The server recovers the grid by dividing frames by the cycle, so this must not move.
        #expect(StickerExportMetadataPolicy.frameCount(document: pingPong, fps: 30) == 120)
    }

    @Test("Empty resumed terminal SSE responses stop reconnecting")
    func terminalSSEState() {
        #expect(SSEStreamTermination.isTerminal(jobState: "succeeded"))
        #expect(SSEStreamTermination.isTerminal(jobState: "failed"))
        #expect(!SSEStreamTermination.isTerminal(jobState: "running"))
    }
}

@Suite("Shared OAuth storage and refresh")
struct SharedAuthenticationTests {
    @Test("Extension ISO-8601 fractional date bundle decodes")
    func fractionalTokenBundle() throws {
        let bundle = try TokenBundleCodec.decode(Data("""
        {"accessToken":"a.b.c","refreshToken":"refresh","idToken":"id","expiresAt":"2030-01-02T03:04:05.123Z","subject":"user-a"}
        """.utf8))
        #expect(bundle.subject == "user-a")
        #expect(bundle.refreshToken == "refresh")
    }

    @Test("RxAuth callbacks expose no half-rotated bundle and hide refresh from its timer")
    func atomicRxAuthStorageCommit() throws {
        let old = SharedTokenBundle(accessToken: "old", refreshToken: "old-refresh", idToken: "old-id", expiresAt: .distantFuture, subject: "user-a")
        let vault = InMemoryTokenVault(old)
        let storage = RxAuthSharedTokenStorage(vault: vault, processLockURL: uniqueLockURL())
        let access = try jwt(subject: "user-a", expiresAt: Date().addingTimeInterval(3_600))

        try storage.saveAccessToken(access)
        #expect(try vault.load() == old)
        try storage.saveRefreshToken("new-refresh")
        #expect(try vault.load() == old)
        try storage.saveExpiresAt(Date().addingTimeInterval(3_600))

        #expect(try vault.load()?.accessToken == access)
        #expect(try vault.load()?.refreshToken == "new-refresh")
        #expect(storage.getRefreshToken() == nil)
    }

    @Test("Subject changes never combine a new access token with the prior account")
    func subjectChangeIsAtomic() throws {
        let old = SharedTokenBundle(accessToken: "old", refreshToken: "user-a-refresh", idToken: "user-a-id", expiresAt: .distantFuture, subject: "user-a")
        let vault = InMemoryTokenVault(old)
        let storage = RxAuthSharedTokenStorage(vault: vault, processLockURL: uniqueLockURL())
        let access = try jwt(subject: "user-b", expiresAt: Date().addingTimeInterval(3_600))

        try storage.saveAccessToken(access)
        #expect(try vault.load() == old)
        try storage.saveRefreshToken("user-b-refresh")
        try storage.saveExpiresAt(Date().addingTimeInterval(3_600))

        let loaded = try vault.load()
        let committed = try #require(loaded)
        #expect(committed.subject == "user-b")
        #expect(committed.refreshToken == "user-b-refresh")
        #expect(committed.idToken == nil)
    }

    @Test("Concurrent callers rotate a refresh token only once")
    func concurrentRefreshIsSerialized() async throws {
        let vault = InMemoryTokenVault(.init(accessToken: "expired", refreshToken: "refresh-1", idToken: nil, expiresAt: .distantPast, subject: "user-a"))
        let response = OAuthRefreshResponse(
            accessToken: try jwt(subject: "user-a", expiresAt: Date().addingTimeInterval(3_600)),
            refreshToken: "refresh-2",
            idToken: nil,
            expiresIn: 3_600
        )
        let transport = CountingRefreshTransport(response: response)
        let broker = SharedTokenBroker(vault: vault, transport: transport, tokenURL: URL(string: "https://auth.example/token")!, clientID: "ios", lockURL: uniqueLockURL())

        let values = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 { group.addTask { try await broker.validAccessToken() } }
            var values: [String] = []
            for try await value in group { values.append(value) }
            return values
        }
        let calls = await transport.callCount()

        #expect(Set(values) == Set([response.accessToken]))
        #expect(calls == 1)
        #expect(try vault.load()?.refreshToken == "refresh-2")
    }

    @Test("Logout waits for an in-flight cross-process rotation, then clears")
    func logoutWinsRefreshRace() async throws {
        let vault = InMemoryTokenVault(.init(accessToken: "expired", refreshToken: "refresh-1", idToken: nil, expiresAt: .distantPast, subject: "user-a"))
        let response = OAuthRefreshResponse(accessToken: "new-access", refreshToken: "refresh-2", idToken: nil, expiresIn: 3_600)
        let transport = CountingRefreshTransport(response: response, delay: .milliseconds(60))
        let broker = SharedTokenBroker(vault: vault, transport: transport, tokenURL: URL(string: "https://auth.example/token")!, clientID: "ios", lockURL: uniqueLockURL())

        let refresh = Task { try await broker.validAccessToken() }
        try await Task.sleep(for: .milliseconds(10))
        try await broker.logout()
        do {
            _ = try await refresh.value
            #expect(Bool(false), "An API caller must not escape with a rotated token after logout starts")
        } catch {
            #expect(error as? TokenBrokerError == .missingSession)
        }

        #expect(try vault.load() == nil)
    }

    @Test("Rejected refresh clears the session and emits expiry")
    func rejectedRefreshRevokesSession() async throws {
        let vault = InMemoryTokenVault(.init(accessToken: "expired", refreshToken: "refresh", idToken: nil, expiresAt: .distantPast, subject: "user-a"))
        let probe = NotificationProbe()
        let token = NotificationCenter.default.addObserver(forName: Notification.Name("rxAuthSessionExpired"), object: nil, queue: nil) { _ in probe.mark() }
        defer { NotificationCenter.default.removeObserver(token) }
        let broker = SharedTokenBroker(vault: vault, transport: RejectingRefreshTransport(), tokenURL: URL(string: "https://auth.example/token")!, clientID: "ios", lockURL: uniqueLockURL())

        do {
            _ = try await broker.validAccessToken()
            #expect(Bool(false), "A rejected refresh must throw")
        } catch {
            #expect(error as? TokenBrokerError == .refreshRejected(400))
        }
        #expect(try vault.load() == nil)
        #expect(probe.value == 1)
    }

    @Test("Production storage has no private-Keychain or temporary-lock fallback")
    func sharedConfigurationFailsClosed() throws {
        let vault = SharedKeychainTokenVault(service: "test", account: UUID().uuidString, accessGroup: nil, allowUnsharedFallback: false)
        #expect(throws: TokenVaultError.self) { try vault.load() }
        let temporary = FileManager.default.temporaryDirectory
        #expect(SharedTokenBroker.lockURL(containerURL: nil, temporaryDirectory: temporary, allowTemporaryFallback: false) == nil)
        #expect(SharedTokenBroker.lockURL(containerURL: nil, temporaryDirectory: temporary, allowTemporaryFallback: true) != nil)
    }
}

@Suite("Store and publisher regressions")
@MainActor
struct StoreAndPublisherTests {
    @Test("A chat message appears before the network request completes")
    func chatSendIsOptimistic() async throws {
        let api = SlowChatAPI()
        let store = StickerStore(api: api)
        let send = Task {
            try await store.sendMessage(
                stickerID: api.stickerID,
                content: "Add particles",
                references: [],
                mask: nil,
                targetLayerID: nil,
                intent: .chat
            )
        }

        await api.waitUntilSending()
        let optimistic = try #require(store.messages[api.stickerID]?.first)
        #expect(optimistic.id.hasPrefix("local-"))
        #expect(optimistic.content == "Add particles")
        #expect(optimistic.status == .streaming)

        await api.finishSending()
        try await send.value
        let persisted = try #require(store.messages[api.stickerID]?.first)
        #expect(persisted.id == "slow-source-message")
        #expect(persisted.jobId == "slow-job")
    }

    /// A send the server refused created nothing, so the composer is safe to repopulate.
    @Test("A rejected send reports that nothing was delivered")
    func rejectedSendIsNotDelivered() async throws {
        let failure = try await #require(await sendFailure(StickerAPIError.http(422)))
        #expect(failure.mayHaveBeenDelivered == false)
    }

    @Test("A server error envelope also reports that nothing was delivered")
    func envelopeSendIsNotDelivered() async throws {
        let envelope = try JSONDecoder.api.decode(APIErrorEnvelope.self, from: Data("""
        {"error":{"code":"AI_TURN_IN_PROGRESS","message":"Already running","requestId":"req-1"}}
        """.utf8))
        let failure = try await #require(await sendFailure(envelope))
        #expect(failure.mayHaveBeenDelivered == false)
    }

    /// A dropped connection may still have created the turn, so the composer must NOT restore the
    /// text — the user would see their message twice and could send a duplicate.
    @Test("A transport failure reports that the send may have landed")
    func ambiguousSendIsTreatedAsDelivered() async throws {
        let failure = try await #require(await sendFailure(URLError(.timedOut)))
        #expect(failure.mayHaveBeenDelivered == true)
    }

    @MainActor
    private func sendFailure(_ error: any Error) async -> SendMessageFailure? {
        let api = FailingChatAPI(error: error)
        let store = StickerStore(api: api)
        do {
            try await store.sendMessage(
                stickerID: api.stickerID, content: "Add particles",
                references: [], mask: nil, targetLayerID: nil, intent: .chat
            )
            return nil
        } catch let failure as SendMessageFailure {
            // The optimistic row is rolled back however the send failed.
            #expect(store.messages[api.stickerID]?.isEmpty != false)
            return failure
        } catch {
            return nil
        }
    }

    @Test("Mask normalization rejects opaque padding tricks and empty masks")
    func maskSourceAlphaValidation() throws {
        let opaqueFormat = UIGraphicsImageRendererFormat()
        opaqueFormat.opaque = true
        opaqueFormat.scale = 1
        let opaque = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 60), format: opaqueFormat).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
        }
        #expect(throws: MediaNormalizationError.self) {
            try MediaNormalizer.mask(data: try #require(opaque.jpegData(compressionQuality: 0.9)))
        }

        let alphaFormat = UIGraphicsImageRendererFormat()
        alphaFormat.opaque = false
        alphaFormat.scale = 1
        let empty = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 60), format: alphaFormat).image { _ in }
        #expect(throws: MediaNormalizationError.self) {
            try MediaNormalizer.mask(data: try #require(empty.pngData()))
        }

        let valid = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 60), format: alphaFormat).image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 60))
        }
        let normalized = try MediaNormalizer.mask(data: try #require(valid.pngData()))
        #expect(normalized.mimeType == "image/png")
        #expect(UIImage(data: normalized.data)?.size == CGSize(width: 1_024, height: 1_024))
    }

    @Test("A failed pre-observe chat request never leaves the sticker computing")
    func preObserveFailureClearsComputing() async throws {
        let api = TurnFailureAPI()
        let store = StickerStore(api: api)
        let stickerID = api.stickerID

        try await store.sendMessage(stickerID: stickerID, content: "first", references: [], mask: nil, targetLayerID: nil)
        try await Task.sleep(for: .milliseconds(80))
        #expect(store.jobs[stickerID]?.isFailed == true)
        #expect(!store.computingStickerIDs.contains(stickerID))

        do {
            try await store.sendMessage(stickerID: stickerID, content: "retry later", references: [], mask: nil, targetLayerID: nil)
            #expect(Bool(false), "The stub's second request must fail")
        } catch {
            #expect(!store.computingStickerIDs.contains(stickerID))
        }
    }

    @Test("Loading a transcript resumes the latest unfinished job for replay and Retry")
    func transcriptResumesSSE() async throws {
        let api = ResumeJobAPI()
        let store = StickerStore(api: api)
        await store.loadMessages(stickerID: api.stickerID)
        try await Task.sleep(for: .milliseconds(80))

        #expect(store.jobs[api.stickerID]?.jobID == "resume-job")
        #expect(store.jobs[api.stickerID]?.sourceMessageID == "resume-source")
        #expect(store.jobs[api.stickerID]?.isFailed == true)
        #expect(!store.computingStickerIDs.contains(api.stickerID))
    }

    @Test("A failed transcript reconstructs Retry without reconnecting")
    func failedTranscriptRestoresRetry() async {
        let api = FailedTranscriptAPI()
        let store = StickerStore(api: api)
        await store.loadMessages(stickerID: api.stickerID)

        #expect(store.jobs[api.stickerID]?.jobID == "failed-transcript-job")
        #expect(store.jobs[api.stickerID]?.sourceMessageID == "failed-transcript-source")
        #expect(store.jobs[api.stickerID]?.isFailed == true)
        #expect(!store.computingStickerIDs.contains(api.stickerID))
    }

    @Test("An event this client cannot use never strands the turn")
    func undecodableEventStillResolvesTheTurn() async throws {
        let api = PoisonEventAPI()
        let store = StickerStore(api: api)

        try await store.sendMessage(stickerID: api.stickerID, content: "Make it blue", references: [], mask: nil, targetLayerID: nil)
        try await Task.sleep(for: .milliseconds(150))

        // The candidate event carries an invalid document. Dropping that one field must not stop
        // the turn from resolving, which is what leaves the chat silent until a manual refresh.
        #expect(store.messages[api.stickerID]?.contains { $0.role == .assistant } == true)
        #expect(!store.computingStickerIDs.contains(api.stickerID))
        #expect(store.jobs[api.stickerID]?.streamErrorMessage == nil)
    }

    @Test("A stream that dies mid-turn still reconciles against the server")
    func brokenStreamStillReconciles() async throws {
        let api = BrokenStreamAPI()
        let store = StickerStore(api: api)

        try await store.sendMessage(stickerID: api.stickerID, content: "Make it blue", references: [], mask: nil, targetLayerID: nil)
        try await Task.sleep(for: .milliseconds(150))

        #expect(store.messages[api.stickerID]?.contains { $0.role == .assistant } == true)
        #expect(!store.computingStickerIDs.contains(api.stickerID))
        // The refetch found the assistant turn, so this is not a user-visible failure.
        #expect(store.jobs[api.stickerID]?.streamErrorMessage == nil)
    }

    @Test("A dead observation can be re-attached instead of staying pinned to a finished job")
    func deadObservationReattaches() async throws {
        let api = BrokenStreamAPI()
        let store = StickerStore(api: api)

        try await store.sendMessage(stickerID: api.stickerID, content: "Make it blue", references: [], mask: nil, targetLayerID: nil)
        try await Task.sleep(for: .milliseconds(150))
        let first = await api.streamCount()

        store.reattach(stickerID: api.stickerID)
        try await Task.sleep(for: .milliseconds(150))

        #expect(await api.streamCount() > first)
    }

    @Test("Library refresh consumes every cursor before replacing state")
    func libraryPagination() async {
        let store = StickerStore(api: PaginatedLibraryAPI())
        await store.refresh()
        #expect(store.stickers.map(\.id) == ["page-1", "page-2", "page-3"])
    }

    @Test("A cancelled Library refresh keeps its content and does not show an error")
    func cancelledLibraryRefreshIsSilent() async {
        let api = CancelledLibraryAPI()
        let store = StickerStore(api: api)
        await store.refresh()

        await store.refresh()

        #expect(store.stickers.map(\.id) == [api.stickerID])
        #expect(store.errorMessage == nil)
        #expect(!store.isLoading)
    }

    @Test("Failed cleanup dispatch keeps the local sticker and surfaces retry")
    func failedDeletionKeepsSticker() async {
        let api = DeleteFailureAPI()
        let store = StickerStore(api: api)
        await store.refresh()

        let deleted = await store.delete(stickerID: api.stickerID)

        #expect(!deleted)
        #expect(store.stickers.contains { $0.id == api.stickerID })
        #expect(store.errorMessage?.contains("unchanged") == true)
    }

    @Test("Publisher refuses a missing or unverified image asset")
    func publisherRequiresVerifiedAssets() async {
        var revision = PreviewFixtures.candidate
        revision.candidateState = .accepted
        let publisher = StickerPublisher(api: MockStickerAPIClient())
        do {
            _ = try await publisher.publish(stickerID: PreviewFixtures.sticker.id, revision: revision, assets: [:], verifiedAssetIDs: [])
            #expect(Bool(false), "Publishing with a placeholder must fail")
        } catch let error as StickerPublishError {
            guard case .missingVerifiedAssets(let missing) = error else {
                #expect(Bool(false), "Expected missing verified assets")
                return
            }
            #expect(missing == [PreviewFixtures.imageAssetID])
        } catch {
            #expect(Bool(false), "Unexpected publisher error: \(error)")
        }
    }

    @Test("Animated base images cannot publish until motion exists")
    func animatedPublishGate() async {
        let base = PreviewFixtures.accepted
        #expect(!base.containsMotion)
        #expect(!base.canPublishExports)

        var animated = PreviewFixtures.candidate
        animated.candidateState = .accepted
        #expect(animated.containsMotion)
        #expect(animated.canPublishExports)

        let publisher = StickerPublisher(api: MockStickerAPIClient())
        do {
            _ = try await publisher.publish(
                stickerID: PreviewFixtures.sticker.id,
                revision: base,
                assets: [:],
                verifiedAssetIDs: []
            )
            #expect(Bool(false), "Publishing an animation-free base must fail before upload")
        } catch let error as StickerPublishError {
            guard case .animationRequired = error else {
                #expect(Bool(false), "Expected the animation publish gate")
                return
            }
        } catch {
            #expect(Bool(false), "Unexpected publisher error: \(error)")
        }
    }

    @Test("Animation-free local export produces one PNG without publishing")
    func animationFreeLocalExport() async throws {
        var revision = PreviewFixtures.accepted
        revision.document.layers = [
            .shape(.init(id: "base", name: "Base", shape: .roundedRectangle, fill: "#A88BFF", cornerRadius: 0.2)),
        ]
        let exports = try await StickerPublisher(api: MockStickerAPIClient()).export(
            revision: revision,
            assets: [:],
            verifiedAssetIDs: []
        )
        defer { exports.forEach { try? FileManager.default.removeItem(at: $0.url) } }

        #expect(exports.count == 1)
        #expect(exports.first?.metadata.format == .png)
        #expect(exports.first?.metadata.hasAlpha == true)
    }

    @Test("Published export state requires the complete rendition set")
    func publishedExportStateRequiresAllRenditions() {
        var revision = PreviewFixtures.candidate
        revision.candidateState = .accepted
        revision.gifAssetId = "gif"
        revision.mp4AssetId = "mp4"
        revision.systemAssetId = "system"
        #expect(revision.hasPublishedExports)

        revision.mp4AssetId = nil
        #expect(!revision.hasPublishedExports)
    }

    @Test("Accepting a candidate updates the active revision")
    func revisionTransition() async throws {
        let store = StickerStore(api: MockStickerAPIClient())
        await store.loadDetail(stickerID: PreviewFixtures.sticker.id)
        try await store.transition(stickerID: PreviewFixtures.sticker.id, revisionID: PreviewFixtures.candidate.id, action: .accept)
        #expect(store.details[PreviewFixtures.sticker.id]?.activeRevisionId == PreviewFixtures.candidate.id)
    }
}

private struct APIFixture: Decodable {
    var stickerList: Page<Sticker>
    var assetDownload: AssetDownload
    var chatMessages: ChatMessagePage
    var publishExports: PublishExportsRequest
    var packList: Page<StickerPack>
    var packDetail: StickerPackDetail
    var librarySections: LibrarySectionsResponse
}

private final class FixtureBundleToken: NSObject {}
private enum TestFixtureError: Error { case missing(String), stub }

private func fixtureData(_ name: String) throws -> Data {
    let bundle = Bundle(for: FixtureBundleToken.self)
    guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        ?? bundle.url(forResource: name, withExtension: "json")
    else { throw TestFixtureError.missing(name) }
    return try Data(contentsOf: url)
}

private func uniqueLockURL() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "sticker-auth-test-\(UUID().uuidString).lock")
}

private func jwt(subject: String, expiresAt: Date) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: ["sub": subject, "exp": expiresAt.timeIntervalSince1970])
    let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "header.\(payload).signature"
}

private final class InMemoryTokenVault: SharedTokenVaultProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var bundle: SharedTokenBundle?

    init(_ bundle: SharedTokenBundle? = nil) { self.bundle = bundle }

    func load() throws -> SharedTokenBundle? {
        lock.lock(); defer { lock.unlock() }
        return bundle
    }

    func replace(with bundle: SharedTokenBundle) throws {
        lock.lock(); defer { lock.unlock() }
        self.bundle = bundle
    }

    func clear() throws {
        lock.lock(); defer { lock.unlock() }
        bundle = nil
    }
}

private actor CountingRefreshTransport: OAuthRefreshTransport {
    let response: OAuthRefreshResponse
    let delay: Duration?
    private var calls = 0

    init(response: OAuthRefreshResponse, delay: Duration? = nil) {
        self.response = response
        self.delay = delay
    }

    func refresh(tokenURL: URL, clientID: String, refreshToken: String) async throws -> OAuthRefreshResponse {
        calls += 1
        if let delay { try await Task.sleep(for: delay) }
        return response
    }

    func callCount() -> Int { calls }
}

private struct RejectingRefreshTransport: OAuthRefreshTransport {
    func refresh(tokenURL: URL, clientID: String, refreshToken: String) async throws -> OAuthRefreshResponse {
        throw TokenBrokerError.refreshRejected(400)
    }
}

private final class NotificationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func mark() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private extension StickerAPIClientProtocol {
    func listStickers(cursor: String?) async throws -> Page<Sticker> { throw TestFixtureError.stub }
    func createSticker(_ request: CreateStickerRequest, idempotencyKey: String) async throws -> CreateStickerResponse { throw TestFixtureError.stub }
    func sticker(id: String) async throws -> StickerDetail { throw TestFixtureError.stub }
    func deleteSticker(id: String, idempotencyKey: String) async throws -> DeleteStickerResponse { throw TestFixtureError.stub }
    func chatMessages(stickerID: String, beforeSequence: Int?) async throws -> ChatMessagePage { throw TestFixtureError.stub }
    func sendChatMessage(stickerID: String, request: SendChatMessageRequest, idempotencyKey: String) async throws -> SendChatMessageResponse { throw TestFixtureError.stub }
    func retryChatMessage(stickerID: String, messageID: String, idempotencyKey: String) async throws -> RetryChatMessageResponse { throw TestFixtureError.stub }
    func confirmPlan(stickerID: String, planID: String, idempotencyKey: String) async throws -> ConfirmPlanResponse { throw TestFixtureError.stub }
    func cancelPlan(stickerID: String, planID: String, reason: String?, idempotencyKey: String) async throws -> CancelPlanResponse { throw TestFixtureError.stub }
    func cancelGeneration(jobID: String, idempotencyKey: String) async throws -> CancelGenerationResponse { throw TestFixtureError.stub }
    func transitionRevision(stickerID: String, revisionID: String, action: RevisionAction, idempotencyKey: String) async throws -> RevisionTransitionResponse { throw TestFixtureError.stub }
    func registerExport(stickerID: String, request: PublishExportsRequest, idempotencyKey: String) async throws -> PublishExportsResponse { throw TestFixtureError.stub }
    func saveEditedDocument(stickerID: String, request: SaveEditedDocumentRequest, idempotencyKey: String) async throws -> SaveEditedDocumentResponse { throw TestFixtureError.stub }
    func upload(data: Data, stickerID: String?, kind: AssetKind, filename: String, mimeType: String, idempotencyKey: String) async throws -> String { throw TestFixtureError.stub }
    func assetDownload(assetID: String) async throws -> AssetDownload { throw TestFixtureError.stub }
    nonisolated func generationEvents(jobID: String, after lastEventID: Int64?) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func marketplacePacks(sort: PackSort, query: String?, cursor: String?) async throws -> Page<StickerPack> { throw TestFixtureError.stub }
    func myPacks(cursor: String?) async throws -> Page<StickerPack> { throw TestFixtureError.stub }
    func packsByCreator(handle: String, cursor: String?) async throws -> CreatorPacksResponse { throw TestFixtureError.stub }
    func pack(id: String) async throws -> StickerPackDetail { throw TestFixtureError.stub }
    func createPack(_ request: CreatePackRequest, idempotencyKey: String) async throws -> StickerPackDetail { throw TestFixtureError.stub }
    func updatePack(id: String, request: UpdatePackRequest, idempotencyKey: String) async throws -> StickerPackDetail { throw TestFixtureError.stub }
    func setPackItems(id: String, stickerIDs: [String], idempotencyKey: String) async throws -> StickerPackDetail { throw TestFixtureError.stub }
    func publishPack(id: String, idempotencyKey: String) async throws -> StickerPackDetail { throw TestFixtureError.stub }
    func unpublishPack(id: String, state: PackState, idempotencyKey: String) async throws -> StickerPackDetail { throw TestFixtureError.stub }
    func deletePack(id: String, idempotencyKey: String) async throws -> DeletePackResponse { throw TestFixtureError.stub }
    func installPack(id: String, idempotencyKey: String) async throws -> InstallPackResponse { throw TestFixtureError.stub }
    func uninstallPack(id: String, idempotencyKey: String) async throws -> InstallPackResponse { throw TestFixtureError.stub }
    /// Empty rather than throwing: `StickerStore.refresh()` now reloads sections alongside the
    /// paged library, and a stub that has nothing to say about packs must not turn every existing
    /// library test into a failure.
    func librarySections(status: LibrarySectionStatus) async throws -> LibrarySectionsResponse {
        .init(sections: [], generatedAt: Date())
    }
}

private actor PaginatedLibraryAPI: StickerAPIClientProtocol {
    func listStickers(cursor: String?) async throws -> Page<Sticker> {
        let index = cursor.flatMap(Int.init) ?? 1
        let sticker = Sticker(
            id: "page-\(index)", title: "Page \(index)", kind: .static, status: .published,
            activeRevisionId: nil, createdAt: Date(), updatedAt: Date(), previewAsset: nil, systemSticker: nil
        )
        return .init(data: [sticker], nextCursor: index < 3 ? String(index + 1) : nil)
    }
}

private actor CancelledLibraryAPI: StickerAPIClientProtocol {
    nonisolated let stickerID = "cancelled-refresh-sticker"
    private var calls = 0

    func listStickers(cursor: String?) async throws -> Page<Sticker> {
        calls += 1
        guard calls == 1 else { throw URLError(.cancelled) }
        return .init(data: [
            .init(
                id: stickerID, title: "Keep me", kind: .animated, status: .draft,
                activeRevisionId: nil, createdAt: Date(), updatedAt: Date(), previewAsset: nil, systemSticker: nil
            ),
        ], nextCursor: nil)
    }
}

private actor TurnFailureAPI: StickerAPIClientProtocol {
    nonisolated let stickerID = "turn-failure-sticker"
    private var sends = 0

    func sendChatMessage(stickerID: String, request: SendChatMessageRequest, idempotencyKey: String) async throws -> SendChatMessageResponse {
        sends += 1
        guard sends == 1 else { throw StickerAPIError.http(503) }
        return .init(
            message: .init(id: "source-message", status: .complete),
            job: .init(id: "failed-job", state: .queued, workflowRunId: nil, eventsUrl: "/api/v1/jobs/failed-job/events")
        )
    }

    nonisolated func generationEvents(jobID: String, after lastEventID: Int64?) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.init(
                id: 1, jobId: jobID, type: .failed, createdAt: Date(),
                data: .init(message: "Generation failed", progress: 1, messageId: "source-message", revisionId: nil, document: nil)
            ))
            continuation.finish()
        }
    }
}

private actor SlowChatAPI: StickerAPIClientProtocol {
    nonisolated let stickerID = "slow-chat-sticker"
    private var sendStarted = false
    private var canFinish = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    func sendChatMessage(stickerID: String, request: SendChatMessageRequest, idempotencyKey: String) async throws -> SendChatMessageResponse {
        sendStarted = true
        let waiters = startWaiters
        startWaiters = []
        waiters.forEach { $0.resume() }
        if !canFinish {
            await withCheckedContinuation { finishWaiters.append($0) }
        }
        return .init(
            message: .init(id: "slow-source-message", status: .streaming),
            job: .init(id: "slow-job", state: .queued, workflowRunId: nil, eventsUrl: "/api/v1/jobs/slow-job/events")
        )
    }

    func waitUntilSending() async {
        guard !sendStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finishSending() {
        canFinish = true
        let waiters = finishWaiters
        finishWaiters = []
        waiters.forEach { $0.resume() }
    }
}

/// Fails the send with a supplied error, to exercise how the store classifies delivery.
private actor FailingChatAPI: StickerAPIClientProtocol {
    nonisolated let stickerID = "failing-chat-sticker"
    private let error: any Error

    init(error: any Error) { self.error = error }

    func sendChatMessage(stickerID: String, request: SendChatMessageRequest, idempotencyKey: String) async throws -> SendChatMessageResponse {
        throw error
    }
}

private actor DeleteFailureAPI: StickerAPIClientProtocol {
    nonisolated let stickerID = "delete-failure-sticker"

    func listStickers(cursor: String?) async throws -> Page<Sticker> {
        .init(data: [
            .init(
                id: stickerID, title: "Keep me", kind: .static, status: .published,
                activeRevisionId: nil, createdAt: Date(), updatedAt: Date(), previewAsset: nil, systemSticker: nil
            ),
        ], nextCursor: nil)
    }

    func deleteSticker(id: String, idempotencyKey: String) async throws -> DeleteStickerResponse {
        .init(
            stickerId: id,
            status: .deleteFailed,
            job: .init(id: "failed-cleanup", state: .failed, workflowRunId: nil, retryable: true)
        )
    }
}

private actor ResumeJobAPI: StickerAPIClientProtocol {
    nonisolated let stickerID = "resume-sticker"

    func chatMessages(stickerID: String, beforeSequence: Int?) async throws -> ChatMessagePage {
        .init(data: [
            .init(
                id: "resume-source", role: .user, kind: .imageEdit, content: "Make it blue",
                targetLayerId: "hero", imagePlacement: .replace, baseRevisionId: nil, sequence: 1,
                revisionId: nil, jobId: "resume-job", status: .streaming, createdAt: Date(), attachments: []
            ),
        ], nextBeforeSequence: nil)
    }

    nonisolated func generationEvents(jobID: String, after lastEventID: Int64?) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.init(
                id: 8, jobId: jobID, type: .failed, createdAt: Date(),
                data: .init(message: "Generation failed", progress: 1, messageId: "resume-source", revisionId: nil, document: nil)
            ))
            continuation.finish()
        }
    }
}

private actor FailedTranscriptAPI: StickerAPIClientProtocol {
    nonisolated let stickerID = "failed-transcript-sticker"

    func chatMessages(stickerID: String, beforeSequence: Int?) async throws -> ChatMessagePage {
        .init(data: [
            .init(
                id: "failed-transcript-source", role: .user, kind: .imageEdit, content: "Make it blue",
                targetLayerId: "hero", imagePlacement: .replace, baseRevisionId: nil, sequence: 1,
                revisionId: nil, jobId: "failed-transcript-job", status: .failed, createdAt: Date(), attachments: []
            ),
        ], nextBeforeSequence: nil)
    }
}

/// Streams a `candidate` whose document cannot be decoded into `AnimatedDocument`.
private actor PoisonEventAPI: StickerAPIClientProtocol {
    nonisolated let stickerID = "poison-sticker"

    func sendChatMessage(stickerID: String, request: SendChatMessageRequest, idempotencyKey: String) async throws -> SendChatMessageResponse {
        .init(
            message: .init(id: "poison-source", status: .streaming),
            job: .init(id: "poison-job", state: .queued, workflowRunId: nil, eventsUrl: "/events")
        )
    }

    func sticker(id: String) async throws -> StickerDetail { PreviewFixtures.detail }

    func chatMessages(stickerID: String, beforeSequence: Int?) async throws -> ChatMessagePage {
        .init(data: [
            .init(
                id: "poison-source", role: .user, kind: .text, content: "Make it blue",
                targetLayerId: nil, imagePlacement: .replace, baseRevisionId: nil, sequence: 1,
                revisionId: nil, jobId: "poison-job", status: .complete, createdAt: Date(), attachments: []
            ),
            .init(
                id: "poison-assistant", role: .assistant, kind: .image, content: "Here it is",
                targetLayerId: nil, imagePlacement: .replace, baseRevisionId: nil, sequence: 2,
                revisionId: nil, jobId: "poison-job", status: .complete, createdAt: Date(), attachments: []
            ),
        ], nextBeforeSequence: nil)
    }

    nonisolated func generationEvents(jobID: String, after lastEventID: Int64?) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let poisoned = Data("""
            {"id":1,"jobId":"poison-job","type":"candidate","createdAt":"2026-01-01T00:00:00Z",
             "data":{"revisionId":"r1","document":{"version":9,"nope":true}}}
            """.utf8)
            if let event = try? JSONDecoder.api.decode(GenerationEvent.self, from: poisoned) {
                continuation.yield(event)
            }
            continuation.yield(.init(
                id: 2, jobId: jobID, type: .completed, createdAt: Date(), data: .init(message: "Done", progress: 1)
            ))
            continuation.finish()
        }
    }
}

/// Throws partway through the stream, as a dropped connection does.
private actor BrokenStreamAPI: StickerAPIClientProtocol {
    nonisolated let stickerID = "broken-sticker"
    private nonisolated let streams = StreamCounter()

    func streamCount() -> Int { streams.value }

    func sendChatMessage(stickerID: String, request: SendChatMessageRequest, idempotencyKey: String) async throws -> SendChatMessageResponse {
        .init(
            message: .init(id: "broken-source", status: .streaming),
            job: .init(id: "broken-job", state: .queued, workflowRunId: nil, eventsUrl: "/events")
        )
    }

    func sticker(id: String) async throws -> StickerDetail { PreviewFixtures.detail }

    func chatMessages(stickerID: String, beforeSequence: Int?) async throws -> ChatMessagePage {
        .init(data: [
            .init(
                id: "broken-source", role: .user, kind: .text, content: "Make it blue",
                targetLayerId: nil, imagePlacement: .replace, baseRevisionId: nil, sequence: 1,
                revisionId: nil, jobId: "broken-job", status: .complete, createdAt: Date(), attachments: []
            ),
            .init(
                id: "broken-assistant", role: .assistant, kind: .image, content: "Here it is",
                targetLayerId: nil, imagePlacement: .replace, baseRevisionId: nil, sequence: 2,
                revisionId: nil, jobId: "broken-job", status: .complete, createdAt: Date(), attachments: []
            ),
        ], nextBeforeSequence: nil)
    }

    nonisolated func generationEvents(jobID: String, after lastEventID: Int64?) -> AsyncThrowingStream<GenerationEvent, Error> {
        streams.mark()
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(
                id: 1, jobId: jobID, type: .progress, createdAt: Date(), data: .init(message: "Working", progress: 0.4)
            ))
            continuation.finish(throwing: TestFixtureError.stub)
        }
    }
}

private final class StreamCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func mark() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
