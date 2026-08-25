import Foundation

nonisolated enum PreviewFixtures {
    static let imageAssetID = "11111111-1111-4111-8111-111111111111"

    static let animatedDocument = StickerDocumentV1(
        kind: .animated,
        durationSeconds: 2,
        fps: 30,
        loop: .loop,
        mp4Background: .linearGradient(colors: ["#FFE7A3", "#FF8FA3"], angleDegrees: 35),
        layers: [
            .shape(.init(
                id: "backdrop",
                name: "Backdrop",
                shape: .burst,
                fill: "#FFE7A3"
            )),
            .image(.init(
                id: "hero",
                name: "Hero",
                animation: .init(
                    position: [
                        .init(timeSeconds: 0, x: 0.5, y: 0.5, easing: .easeOut),
                        .init(timeSeconds: 1, x: 0.5, y: 0.42, easing: .springBouncy),
                        .init(timeSeconds: 2, x: 0.5, y: 0.5, easing: .easeIn),
                    ],
                    scale: [
                        .init(timeSeconds: 0, x: 0.92, y: 0.92, easing: .easeOut),
                        .init(timeSeconds: 1, x: 1.08, y: 1.08, easing: .springSoft),
                        .init(timeSeconds: 2, x: 0.92, y: 0.92, easing: .easeIn),
                    ]
                ),
                assetId: imageAssetID
            )),
            .particle(.init(
                id: "sparkles",
                name: "Sparkles",
                preset: .sparkles,
                count: 16,
                color: "#FFFFFF",
                seed: 42
            )),
        ]
    )

    static let staticDocument = StickerDocumentV1(
        kind: .static,
        layers: [
            .shape(.init(id: "bubble", name: "Bubble", shape: .roundedRectangle, fill: "#A88BFF", cornerRadius: 0.2)),
            .text(.init(id: "caption", name: "Caption", text: "YES!", font: .rounded, weight: .bold, color: "#FFFFFF")),
        ]
    )

    /// The accepted first stage of an animated project is still an animated
    /// document; it simply has no motion keyframes until the user confirms the
    /// base and describes motion in chat.
    static let animatedBaseDocument = StickerDocumentV1(
        kind: .animated,
        durationSeconds: 2,
        fps: 30,
        loop: .loop,
        mp4Background: .linearGradient(colors: ["#FFE7A3", "#FF8FA3"], angleDegrees: 35),
        layers: [
            .shape(.init(id: "backdrop", name: "Backdrop", shape: .burst, fill: "#FFE7A3")),
            .image(.init(id: "hero", name: "Hero", assetId: imageAssetID)),
        ]
    )

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
