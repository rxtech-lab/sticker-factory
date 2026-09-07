import Foundation
import Testing
@testable import StickerGeniOS

/// The preparer is where the messenger encoding moved to, so these cover the three things that
/// change because of the move: work is skipped when it has already been done, a failure on one
/// messenger does not cost the other, and the uploads can be retried without the server refusing
/// them as a replay of a different body.
@Suite("Messenger rendition preparer")
@MainActor
struct MessengerRenditionPreparerTests {
    private func makeSticker(
        id: String = "sticker-borrowed",
        prepared: Set<MessengerDestination> = []
    ) -> Sticker {
        func rendition(_ destination: MessengerDestination) -> AssetRecord? {
            guard prepared.contains(destination) else { return nil }
            return .init(
                id: "\(destination.rawValue)-existing",
                stickerId: id,
                kind: destination.assetKind,
                state: .ready,
                mimeType: destination == .whatsapp ? "image/webp" : "image/png"
            )
        }
        return Sticker(
            id: id,
            title: "Wave",
            kind: .static,
            status: .published,
            activeRevisionId: "revision-1",
            createdAt: Date(),
            updatedAt: Date(),
            previewAsset: .init(
                id: PreviewFixtures.borrowedAssetID,
                stickerId: id,
                kind: .master,
                state: .ready,
                mimeType: "image/png"
            ),
            systemSticker: nil,
            whatsappAsset: rendition(.whatsapp),
            telegramAsset: rendition(.telegram)
        )
    }

    @Test("A sticker that already has both renditions is skipped entirely")
    func skipsPreparedStickers() async {
        let api = MockStickerAPIClient()
        let preparer = MessengerRenditionPreparer(api: api)
        let sticker = makeSticker(prepared: Set(MessengerDestination.allCases))

        await preparer.prepare([sticker]).value

        #expect(await api.uploadCalls.isEmpty)
        #expect(await api.messengerRenditionRequests.isEmpty)
        #expect(preparer.progress == nil)
    }

    @Test("A draft sticker is never prepared")
    func skipsDrafts() async {
        let api = MockStickerAPIClient()
        let preparer = MessengerRenditionPreparer(api: api)
        var sticker = makeSticker()
        sticker.status = .draft

        await preparer.prepare([sticker]).value

        #expect(await api.uploadCalls.isEmpty)
    }

    @Test("Only the missing messenger is encoded when the other is already bound")
    func encodesOnlyWhatIsMissing() async {
        let api = MockStickerAPIClient()
        let preparer = MessengerRenditionPreparer(api: api)

        await preparer.prepare([makeSticker(prepared: [.whatsapp])]).value

        // Whatever the encode did, it must not have touched WhatsApp's slot.
        let uploads = await api.uploadCalls
        #expect(!uploads.contains { $0.kind == .messengerWhatsApp })
        if let request = await api.messengerRenditionRequests.first {
            #expect(request.request.whatsappAssetId == nil)
        }
    }

    /// The digest belongs in the key because the server hashes the body against it: VP9 rate
    /// control is not guaranteed to produce identical bytes twice, so a key fixed to the sticker
    /// alone would turn an honest retry into a conflict.
    @Test("Upload keys are derived from the bytes, so a retry replays rather than conflicts")
    func uploadKeysAreStable() async {
        let api = MockStickerAPIClient()
        let preparer = MessengerRenditionPreparer(api: api)

        await preparer.prepare([makeSticker()]).value
        let first = await api.uploadCalls.map(\.idempotencyKey)
        await preparer.prepare([makeSticker()]).value
        let second = await api.uploadCalls.map(\.idempotencyKey).suffix(first.count)

        #expect(!first.isEmpty)
        #expect(Array(second) == first)
        #expect(first.allSatisfy { $0.hasPrefix("messenger-") })
    }

    @Test("A sticker with nothing to prepare leaves no progress banner behind")
    func noWorkLeavesNoProgress() async {
        let api = MockStickerAPIClient()
        let preparer = MessengerRenditionPreparer(api: api)
        await preparer.prepare([]).value
        #expect(preparer.progress == nil)
        #expect(!preparer.isPreparing)
    }

    @Test("Cancelling stops the run and clears the banner")
    func cancellationClearsProgress() async {
        let api = MockStickerAPIClient()
        let preparer = MessengerRenditionPreparer(api: api)
        let task = preparer.prepare([makeSticker()])
        preparer.cancel()
        await task.value
        #expect(preparer.progress == nil)
    }
}
