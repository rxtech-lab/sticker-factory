import AnimatedView
import CryptoKit
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import StickerGeniOS

/// Waits for background work to land instead of guessing how long it takes.
///
/// These stores finish their turns over several hops between the main actor and the network stub,
/// and a fixed sleep only holds while the machine is idle: adding a rendering test to the suite —
/// which occupies the main actor for a second at a time — was enough to make every fixed wait here
/// expire early. Polling keeps the tests measuring the store rather than the machine.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(10),
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@Suite("Sticker document and API contracts")
struct StickerContractTests {
    @Test("Static creation omits motion while animated creation sends the choice")
    func createStickerMotionPayload() throws {
        func payload(kind: StickerKind, motion: Bool?) throws -> [String: Any] {
            let request = CreateStickerRequest(
                presets: nil, title: "Cat", kind: kind, prompt: "A round orange cat",
                referenceAssetIds: [], motion: motion
            )
            return try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        }

        #expect(try payload(kind: .static, motion: nil)["motion"] == nil)
        #expect(try payload(kind: .animated, motion: false)["motion"] as? Bool == false)
        #expect(try payload(kind: .animated, motion: true)["motion"] as? Bool == true)
    }

    @Test("Authenticated requests carry iOS app version and language metadata")
    func clientMetadataHeaders() throws {
        var request = URLRequest(url: try #require(URL(string: "https://api.example/stickers")))
        StickerAPIClient.addClientMetadataHeaders(
            to: &request,
            appVersion: "1.2.3",
            acceptLanguage: "zh-Hans-CN"
        )

        #expect(request.value(forHTTPHeaderField: "X-iOS-App-Version") == "1.2.3")
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "zh-Hans-CN")
    }

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

    @MainActor
    @Test("Video layers reuse decoded keyed frames across asset stores")
    func videoLayerFrameCache() async throws {
        let context = try #require(CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let frames = KeyedVideoFrames(
            frames: [image],
            frameRate: 24,
            size: CGSize(width: 2, height: 2)
        )
        let probe = VideoFrameLoadProbe()
        let loader = StickerVideoFrameLoader(totalCostLimit: 1024) { _, _, _, _ in
            await probe.recordLoad()
            return .init(frames: frames, isVerified: true)
        }
        let api = VideoFrameCacheAPI()
        let firstStore = StickerAssetStore(videoFrameLoader: loader)
        let secondStore = StickerAssetStore(videoFrameLoader: loader)

        await firstStore.loadVideo(assetID: "video-asset", keyColor: .green, api: api)
        await secondStore.loadVideo(assetID: "video-asset", keyColor: .green, api: api)

        #expect(await probe.loadCount == 1)
        #expect(firstStore.videos["video-asset"]?.frameCount == 1)
        #expect(secondStore.videos["video-asset"]?.frameCount == 1)
        #expect(firstStore.verifiedAssetIDs.contains("video-asset"))
        #expect(secondStore.verifiedAssetIDs.contains("video-asset"))
    }

    /// The v2 fixture, which is what every already-stored revision looks like.
    ///
    /// `document_json` is immutable, so v2 rows outlive every version bump and the client has to
    /// keep reading them forever. It is *not* rewritten to v3 on the way in — v3 only added a layer
    /// kind, so a v2 document is already a valid v3 one and `validated()` simply accepts both.
    @Test("Canonical server fixture decodes, validates, and round-trips")
    func canonicalDocumentFixture() throws {
        let data = try fixtureData("sticker-document-v2")
        let document = try JSONDecoder.api.decode(AnimatedDocument.self, from: data)
        let validated = try document.validated()

        #expect(validated.version == 2)
        #expect(AnimatedDocument.readableVersions.contains(validated.version))
        #expect(validated.canvas.coordinateSpace == "normalized")
        #expect(validated.kind == .animated)
        #expect(validated.layers.count == 2)
        // The MP4 fill is spelled `colors: [from, to]` on the wire while the artwork background uses
        // located stops. Reading it as an artwork background threw, which failed the whole document
        // rather than the one field, so every sticker with a gradient video background was
        // unopenable.
        #expect(validated.mp4Background == .linearGradient("#FFE7A3", "#FF8FA3", angleDegrees: 35))
        let reencoded = try JSONEncoder.api.encode(validated)
        let wire = try #require(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        let mp4Background = try #require(wire["mp4Background"] as? [String: Any])
        // Encoded back in the shape the server accepts, or saving an edited document is rejected.
        #expect(mp4Background["colors"] as? [String] == ["#FFE7A3", "#FF8FA3"])
        #expect(mp4Background["stops"] == nil)
        #expect(try JSONDecoder.api.decode(AnimatedDocument.self, from: reencoded) == validated)
    }

    /// The v4 fixture, which is what the server writes today.
    ///
    /// The round trip is the load-bearing half: the client sends whole documents back through
    /// `saveEditedDocument`, so a video layer that decoded but re-encoded with the wrong playback
    /// contract would be rejected by the server on save — or worse, silently saved incorrectly.
    @Test("Current server fixture decodes its video layer and round-trips")
    func currentDocumentFixture() throws {
        let data = try fixtureData("sticker-document-v4")
        let document = try JSONDecoder.api.decode(AnimatedDocument.self, from: data)
        let validated = try document.validated()

        #expect(validated.version == AnimatedDocument.currentVersion)
        #expect(validated.kind == .animated)
        #expect(validated.loop == .pingPong)
        guard case .video(let hero) = validated.layers[0] else {
            #expect(Bool(false), "Fixture must lead with its video layer")
            return
        }
        #expect(hero.keyColor == .green)
        #expect(hero.frameCount == 48)
        #expect(hero.frameRate == 24)
        #expect(hero.playback == .loop)
        #expect(hero.posterAssetId == "66666666-6666-4666-8666-666666666666")

        let reencoded = try JSONEncoder.api.encode(validated)
        #expect(try JSONDecoder.api.decode(AnimatedDocument.self, from: reencoded) == validated)
        let wire = try #require(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        let layers = try #require(wire["layers"] as? [[String: Any]])
        #expect(layers[0]["type"] as? String == "video")
        #expect(layers[0]["frameCount"] as? Int == 48)
        #expect(layers[0]["keyColor"] as? String == "green")
    }

    /// A layer kind from a future version must not take the whole document down with it.
    ///
    /// Before `AnimatedLayer.unsupported` existed, an unknown `type` threw out of the layer decoder,
    /// which failed the document, which failed the enclosing `StickerDetail` — leaving the user with
    /// a project they could not open at all. Round-tripping the raw object is the other half: saving
    /// an edit must not silently delete the layer either.
    @Test("An unknown layer kind is carried, not fatal")
    func unknownLayerKindSurvives() throws {
        var wire = try #require(
            JSONSerialization.jsonObject(with: try fixtureData("sticker-document-v3")) as? [String: Any]
        )
        var layers = try #require(wire["layers"] as? [[String: Any]])
        layers[0]["type"] = "hologram"
        layers[0]["depthMetres"] = 4
        wire["layers"] = layers
        let data = try JSONSerialization.data(withJSONObject: wire)

        let document = try JSONDecoder.api.decode(AnimatedDocument.self, from: data)
        #expect(document.layers.count == 2)
        guard case .unsupported = document.layers[0] else {
            #expect(Bool(false), "An unknown layer kind should decode as unsupported")
            return
        }
        // Reported so the editor can block publishing, rather than quietly shipping a sticker with
        // a layer this build could not draw.
        #expect(!document.layers[0].isValid)
        #expect(document.editorIssues.contains { $0.severity == .blocking })

        let reencoded = try JSONEncoder.api.encode(document)
        let roundTripped = try #require(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        let outLayers = try #require(roundTripped["layers"] as? [[String: Any]])
        #expect(outLayers[0]["type"] as? String == "hologram")
        #expect(outLayers[0]["depthMetres"] as? Int == 4)
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
        #expect(layer.base.animation.opacity.map(\.timeSeconds) == [0.4, 0.9])
        #expect(layer.base.animation.opacity.map(\.value) == [0, 1])
        #expect(layer.base.animation.scale.map(\.timeSeconds) == [0.4, 0.9])
        // Layout rides on a single t=0 anchor keyframe, exactly as a static layout would.
        #expect(layer.base.animation.position.count == 1)
        #expect(layer.base.animation.position[0].timeSeconds == 0)

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
        layer.base.animation.position[0].x = 2.01
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
        {"stickerId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","threadId":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",\
        "initialMessageId":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","job":\(job)}
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
        {"id":3,"jobId":"11111111-1111-4111-8111-111111111111","type":"progress","createdAt":"2026-08-24T12:00:00Z",\
        "data":{"toolCallId":"22222222-2222-4222-8222-222222222222","toolName":"show-sticker","toolStatus":"streaming"}}
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
        {"id":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","stickerId":null,"kind":"gif","state":"ready",\
        "mimeType":"image/gif","byteSize":100,"width":300,"height":300,"frameCount":60,\
        "durationSeconds":1.8,"fps":33.3333333333,"sha256":null,"hasAlpha":true,\
        "createdAt":"2026-08-24T12:00:00Z"}
        """.utf8))
        #expect(abs((fractionalAsset.fps ?? 0) - 33.3333333333) < 0.000_000_001)

        let deletion = try JSONDecoder.api.decode(DeleteStickerResponse.self, from: Data("""
        {"stickerId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","status":"deleting","job":{"id":"ffffffff-ffff-4fff-8fff-ffffffffffff",\
        "state":"queued","workflowRunId":"cleanup-run","retryable":false}}
        """.utf8))
        #expect(deletion.status == .deleting)
        #expect(deletion.job.retryable == false)
    }

    @Test("Static export registration uses pngAssetId, not source masterAssetId")
    func staticExportRequestField() throws {
        let value = PublishExportsRequest(
            revisionId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            pngAssetId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            apngAssetId: nil,
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
            apngAssetId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
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
        {"error":{"code":"VALIDATION_FAILED","message":"Invalid request","requestId":"request-1",\
        "details":{"issues":[{"path":["attachments",0,"assetId"],"message":"Invalid UUID"}],"retryable":false}}}
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

    /// The server's message has to survive the trip to a banner.
    ///
    /// `Error.localizedDescription` on a type that is only `Error` synthesises "The operation
    /// couldn't be completed. (StickerGeniOS.APIErrorEnvelope error 1.)" — so every message the API
    /// took care to write was discarded at the very last step, and every failure looked identical.
    /// Nothing about that is visible at the throw site, which is why it needs a test rather than a
    /// reading.
    @Test("An API error reaches the user in the server's own words")
    func apiErrorDescribesItself() throws {
        let envelope = try JSONDecoder.api.decode(APIErrorEnvelope.self, from: Data("""
        {"error":{"code":"SEQUENCE_INVALID","message":"frameCount must not exceed rows × columns","requestId":"request-7"}}
        """.utf8))

        #expect(envelope.localizedDescription == "frameCount must not exceed rows × columns")
        #expect(!envelope.localizedDescription.contains("couldn’t be completed"))
        #expect(!envelope.localizedDescription.contains("couldn't be completed"))

        // Thrown and caught as an opaque `Error`, which is how every call site actually sees it.
        let caught: String
        do { throw envelope } catch { caught = error.localizedDescription }
        #expect(caught == "frameCount must not exceed rows × columns")
    }

    @Test("A rejected upload says which status it was rejected with")
    func uploadFailureCarriesItsStatus() {
        let error: Error = StickerAPIError.uploadFailed(status: 403)
        #expect(error.localizedDescription.contains("403"))
    }
}
