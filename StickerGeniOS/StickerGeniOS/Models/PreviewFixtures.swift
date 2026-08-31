import AnimatedView
import Foundation

nonisolated enum PreviewFixtures {
    static let imageAssetID = "11111111-1111-4111-8111-111111111111"

    /// A moving, multi-layer sticker.
    ///
    /// Built from the package's own preview documents rather than hand-assembled here: these are
    /// only ever used by SwiftUI previews, and a second set of fixtures is a second thing to keep
    /// in step with the document contract.
    static let animatedDocument: AnimatedDocument = {
        var document = AnimatedPreviewDocuments.composite
        document.mp4Background = .linearGradient("#FFE7A3", "#FF8FA3", angleDegrees: 35)
        return document
    }()

    static let staticDocument = AnimatedPreviewDocuments.staticDocument

    /// The accepted first stage of an animated project is still an animated document; it simply
    /// has no motion keyframes until the user confirms the base and describes motion in chat.
    static let animatedBaseDocument: AnimatedDocument = {
        var document = AnimatedDocument(
            kind: .animated,
            durationSeconds: 2,
            fps: 30,
            loop: .loop,
            mp4Background: .linearGradient("#FFE7A3", "#FF8FA3", angleDegrees: 35),
            layers: [
                .shape(.init(base: .init(id: "backdrop", name: "Backdrop"), shape: .burst, fill: .solid("#FFE7A3"))),
                .image(.init(base: .init(id: "hero", name: "Hero"), assetId: imageAssetID)),
            ]
        )
        document.canvas = .init(square: 1024)
        return document
    }()

    static let sticker = Sticker(
        id: "sticker-demo",
        title: "Happy bounce",
        kind: .animated,
        status: .published,
        activeRevisionId: "revision-accepted",
        createdAt: Date().addingTimeInterval(-3_600),
        updatedAt: Date(),
        previewAsset: nil,
        systemSticker: nil
    )

    /// A sticker owned by somebody else — what an installed pack's members look like.
    static let borrowedSticker = Sticker(
        id: "sticker-borrowed",
        title: "Loaf",
        kind: .static,
        status: .published,
        activeRevisionId: "revision-borrowed",
        createdAt: Date().addingTimeInterval(-7_200),
        updatedAt: Date().addingTimeInterval(-600),
        previewAsset: nil,
        systemSticker: nil
    )

    static let creator = PackCreator(
        handle: "mika-lin-4f2a9c",
        displayName: "Mika Lin",
        bio: "Draws cats, mostly.",
        packCount: 3,
        isSelf: false
    )

    static let pack = StickerPack(
        id: "pack-demo",
        slug: "cozy-cats-9f3a1c8d",
        title: "Cozy Cats",
        summary: "Twelve cats being extremely comfortable.",
        state: .published,
        creator: creator,
        itemCount: 1,
        installCount: 128,
        installed: false,
        isMine: false,
        coverStickers: [borrowedSticker],
        monetization: .init(kind: "free", priceCents: 0, currency: "USD"),
        publishedAt: Date().addingTimeInterval(-86_400),
        createdAt: Date().addingTimeInterval(-172_800),
        updatedAt: Date().addingTimeInterval(-600)
    )

    static let packDetail = StickerPackDetail(
        id: pack.id,
        slug: pack.slug,
        title: pack.title,
        summary: pack.summary,
        state: pack.state,
        creator: pack.creator,
        itemCount: pack.itemCount,
        installCount: pack.installCount,
        installed: pack.installed,
        isMine: pack.isMine,
        coverStickers: pack.coverStickers,
        monetization: pack.monetization,
        publishedAt: pack.publishedAt,
        createdAt: pack.createdAt,
        updatedAt: pack.updatedAt,
        stickers: [borrowedSticker]
    )

    static let mineSection = LibrarySection(
        id: "mine",
        kind: .mine,
        title: "My Stickers",
        packId: nil,
        packSlug: nil,
        creator: nil,
        installedAt: nil,
        updatedAt: Date(),
        stickers: [sticker]
    )

    static let installedSection = LibrarySection(
        id: "pack:\(pack.id)",
        kind: .pack,
        title: pack.title,
        packId: pack.id,
        packSlug: pack.slug,
        creator: creator,
        installedAt: Date().addingTimeInterval(-3_600),
        updatedAt: Date().addingTimeInterval(-600),
        stickers: [borrowedSticker]
    )

    static let candidate = StickerRevision(
        id: "revision-candidate",
        parentRevisionId: "revision-accepted",
        sourceMessageId: "message-user",
        candidateState: .candidate,
        document: animatedDocument,
        masterAssetId: imageAssetID,
        previewAssetId: nil,
        pngAssetId: nil,
        gifAssetId: nil,
        apngAssetId: nil,
        mp4AssetId: nil,
        systemAssetId: nil,
        createdAt: Date(),
        decidedAt: nil
    )

    static let accepted = StickerRevision(
        id: "revision-accepted",
        parentRevisionId: nil,
        sourceMessageId: nil,
        candidateState: .accepted,
        document: animatedBaseDocument,
        masterAssetId: imageAssetID,
        previewAssetId: nil,
        pngAssetId: nil,
        gifAssetId: nil,
        apngAssetId: nil,
        mp4AssetId: nil,
        systemAssetId: nil,
        createdAt: Date().addingTimeInterval(-600),
        decidedAt: Date().addingTimeInterval(-590)
    )

    static let detail = StickerDetail(
        id: sticker.id,
        title: sticker.title,
        kind: sticker.kind,
        status: sticker.status,
        activeRevisionId: sticker.activeRevisionId,
        createdAt: sticker.createdAt,
        updatedAt: sticker.updatedAt,
        previewAsset: nil,
        systemSticker: nil,
        revisions: [candidate, accepted]
    )

    static let messages: [ChatMessage] = [
        .init(
            id: "message-user",
            role: .user,
            kind: .animation,
            content: "Make the character bounce and add little sparkles.",
            targetLayerId: "hero",
            imagePlacement: .replace,
            baseRevisionId: "revision-accepted",
            sequence: 1,
            revisionId: nil,
            jobId: "22222222-2222-4222-8222-222222222222",
            status: .complete,
            createdAt: Date().addingTimeInterval(-60),
            attachments: []
        ),
        .init(
            id: "message-assistant",
            role: .assistant,
            kind: .animation,
            content: "I made a two-second bounce with deterministic sparkles. Preview it live, then accept or refine it.",
            targetLayerId: nil,
            imagePlacement: .replace,
            baseRevisionId: "revision-accepted",
            sequence: 2,
            revisionId: candidate.id,
            jobId: nil,
            status: .complete,
            createdAt: Date().addingTimeInterval(-40),
            attachments: []
        ),
    ]
}
