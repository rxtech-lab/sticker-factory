import Foundation
import Testing
@testable import StickerGeniOS

@Suite("Messenger pack splitting")
struct MessengerPackSplitterTests {
    /// A pack member that is ready for both messengers unless told otherwise.
    ///
    /// `prepared` is what decides whether a sticker can be sent now: since the export sheet stopped
    /// encoding, published artwork is no longer enough on its own.
    private func sticker(
        _ index: Int,
        kind: StickerKind,
        published: Bool = true,
        prepared: Set<MessengerDestination> = Set(MessengerDestination.allCases)
    ) -> Sticker {
        func rendition(_ destination: MessengerDestination) -> AssetRecord? {
            guard published, prepared.contains(destination) else { return nil }
            return .init(
                id: "\(destination.rawValue)-\(index)",
                stickerId: nil,
                kind: destination.assetKind,
                state: .ready,
                mimeType: destination == .whatsapp ? "image/webp" : (kind == .animated ? "video/webm" : "image/png")
            )
        }
        return Sticker(
            id: "sticker-\(kind.rawValue)-\(index)",
            title: "Sticker \(index)",
            kind: kind,
            status: published ? .published : .draft,
            activeRevisionId: "revision-\(index)",
            createdAt: Date(),
            updatedAt: Date(),
            previewAsset: published ? .init(
                id: "asset-\(index)",
                stickerId: nil,
                kind: kind == .static ? .master : .apng,
                state: .ready,
                mimeType: "image/png"
            ) : nil,
            systemSticker: nil,
            whatsappAsset: rendition(.whatsapp),
            telegramAsset: rendition(.telegram)
        )
    }

    private func split(_ stickers: [Sticker], _ destination: MessengerDestination, excluding: Set<String> = []) -> MessengerSplitOutcome {
        MessengerPackSplitter.split(
            packID: "pack",
            packTitle: "Cozy Cats",
            stickers: stickers,
            destination: destination,
            excluding: excluding
        )
    }

    @Test("A small single-kind pack becomes one part with the pack's own name")
    func singlePart() {
        let outcome = split((1...5).map { sticker($0, kind: .static) }, .whatsapp)
        #expect(outcome.parts.count == 1)
        #expect(outcome.parts[0].title == "Cozy Cats")
        #expect(outcome.parts[0].kind == .static)
        #expect(outcome.parts[0].stickers.count == 5)
        #expect(outcome.skipped.isEmpty)
    }

    @Test("Still and animated stickers are split into separate parts, named by kind")
    func splitsByKind() {
        let stickers = (1...4).map { sticker($0, kind: .static) } + (1...3).map { sticker($0, kind: .animated) }
        let outcome = split(stickers, .whatsapp)
        #expect(outcome.parts.map(\.kind) == [.static, .animated])
        #expect(outcome.parts.map(\.title) == ["Cozy Cats · Static", "Cozy Cats · Animated"])
        #expect(outcome.parts[0].stickers.allSatisfy { $0.kind == .static })
        #expect(outcome.parts[1].stickers.allSatisfy { $0.kind == .animated })
    }

    @Test("More stickers than WhatsApp allows are cut into balanced parts, none below its minimum")
    func balancedWhatsAppParts() {
        let outcome = split((1...31).map { sticker($0, kind: .static) }, .whatsapp)
        #expect(outcome.parts.count == 2)
        #expect(outcome.parts.map { $0.stickers.count } == [16, 15])
        #expect(outcome.parts.map(\.title) == ["Cozy Cats (1/2)", "Cozy Cats (2/2)"])
        #expect(outcome.parts.map(\.index) == [1, 2])
        #expect(outcome.parts.allSatisfy { $0.count == 2 })
        // Order is preserved across the cut.
        #expect(outcome.parts.flatMap(\.stickers).map(\.id) == (1...31).map { "sticker-static-\($0)" })
    }

    @Test("Telegram takes up to 120 of a kind in one set and splits evenly past that")
    func telegramLimits() {
        #expect(split((1...120).map { sticker($0, kind: .animated) }, .telegram).parts.count == 1)
        let outcome = split((1...121).map { sticker($0, kind: .animated) }, .telegram)
        #expect(outcome.parts.map { $0.stickers.count } == [61, 60])
        // A single Telegram sticker is a valid set.
        #expect(split([sticker(1, kind: .static)], .telegram).parts.count == 1)
    }

    @Test("Fewer than three of a kind cannot go to WhatsApp, and say why")
    func belowWhatsAppMinimum() {
        let stickers = (1...4).map { sticker($0, kind: .static) } + [sticker(1, kind: .animated), sticker(2, kind: .animated)]
        let outcome = split(stickers, .whatsapp)
        #expect(outcome.parts.count == 1)
        #expect(outcome.parts[0].kind == .static)
        #expect(outcome.skipped.count == 2)
        #expect(outcome.skipped.allSatisfy { $0.reason == .belowMinimum(kind: .animated, count: 2, minimum: 3) })
        #expect(outcome.skipped[0].reason.message(for: .whatsapp).contains("at least 3"))
    }

    @Test("Unpublished members and excluded members are left out, and exclusion re-cuts the parts")
    func skippedAndExcluded() {
        var stickers = (1...4).map { sticker($0, kind: .static) }
        stickers.append(sticker(9, kind: .static, published: false))
        let outcome = split(stickers, .whatsapp)
        #expect(outcome.parts[0].stickers.count == 4)
        #expect(outcome.skipped.map(\.id) == ["sticker-static-9"])
        #expect(outcome.skipped[0].reason == .notPublished)

        let excluded = split(stickers, .whatsapp, excluding: ["sticker-static-1", "sticker-static-2"])
        // Two left of four: under WhatsApp's minimum, so the part disappears and the rest are
        // reported rather than silently sent short.
        #expect(excluded.parts.isEmpty)
        #expect(excluded.skipped.contains { $0.id == "sticker-static-3" })
    }

    /// The case the two independent renditions exist for: WhatsApp gives an animation 500 KB and
    /// Telegram 256 KB, so artwork routinely clears one ceiling and misses the other.
    @Test("A sticker prepared for one messenger is sendable there and skipped for the other")
    func perDestinationPreparation() {
        var stickers = (1...4).map { sticker($0, kind: .static) }
        stickers.append(sticker(9, kind: .static, prepared: [.whatsapp]))

        let whatsapp = split(stickers, .whatsapp)
        #expect(whatsapp.parts[0].stickers.count == 5)
        #expect(whatsapp.skipped.isEmpty)

        let telegram = split(stickers, .telegram)
        #expect(telegram.parts[0].stickers.count == 4)
        #expect(telegram.skipped.map(\.id) == ["sticker-static-9"])
        #expect(telegram.skipped[0].reason == .notPrepared)
        #expect(telegram.skipped[0].reason.message(for: .telegram).contains("Telegram"))
    }

    /// Everything published before the app stored renditions. Published artwork is no longer enough
    /// on its own, and the reason has to say so rather than claim the sticker is unpublished.
    @Test("A member with artwork but no rendition is skipped as not prepared")
    func legacyMemberIsNotPrepared() {
        let stickers = (1...4).map { sticker($0, kind: .static) }
            + [sticker(9, kind: .static, prepared: [])]
        for destination in MessengerDestination.allCases {
            let outcome = split(stickers, destination)
            #expect(outcome.skipped.map(\.id) == ["sticker-static-9"])
            #expect(outcome.skipped[0].reason == .notPrepared)
        }
    }

    @Test("An unpublished member is reported as unpublished, not as unprepared")
    func unpublishedBeatsUnprepared() {
        let outcome = split([sticker(9, kind: .static, published: false)], .telegram)
        #expect(outcome.skipped[0].reason == .notPublished)
    }

    @Test("Balanced runs never exceed the maximum and always add up")
    func balancedRuns() {
        for count in 1...250 {
            let runs = MessengerPackSplitter.balancedRuns(Array(0..<count), maximum: 30)
            #expect(runs.flatMap { $0 } == Array(0..<count))
            #expect(runs.allSatisfy { $0.count <= 30 })
            let sizes = runs.map(\.count)
            #expect((sizes.max() ?? 0) - (sizes.min() ?? 0) <= 1)
        }
    }
}
