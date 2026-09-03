import Foundation
import Testing

@testable import StickerGeniOS

/// Which planned sources the build squares off, so the plan card draws the box the sticker gets.
///
/// The server fits pixels and glyphs inside their box and stretches nothing else; a schematic that
/// disagreed would show the user a wide caption the build shrinks to a square, and every layer
/// placed around that caption would look wrong for a reason nobody could see in the plan.
@Suite("Plan layer sources")
struct PlanLayerSourceTests {
    @Test("Artwork, captures, clips, and text keep their aspect", arguments: [
        PlanLayerSource.generate(prompt: "A cat"),
        .existing(assetId: "asset"),
        .sequence(assetId: "atlas", frameCount: 12),
        .video(prompt: "A cat waving", motion: "wave", durationSeconds: 2),
        .text(text: "HI", color: "#FF0055"),
    ])
    func fittedSourcesAreLocked(_ source: PlanLayerSource) {
        #expect(source.isAspectLocked)
    }

    @Test("Primitives may fill a non-square box", arguments: [
        PlanLayerSource.shape(shape: "roundedRectangle", fill: "#FF8800"),
        .particle(preset: "sparkles", color: "#FFD400"),
        .unknown(kind: "hologram"),
    ])
    func primitivesAreFree(_ source: PlanLayerSource) {
        #expect(!source.isAspectLocked)
    }
}
