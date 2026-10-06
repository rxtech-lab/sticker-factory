import XCTest
@testable import StickerGeniOS

@MainActor
final class PetDialogueLayoutTests: XCTestCase {
    private let stage = CGRect(x: 20, y: 100, width: 350, height: 420)
    private let bubble = CGSize(width: 320, height: 80)

    func testClearSpaceKeepsDialogueBelow() {
        XCTAssertEqual(PetDialoguePlacement.preferred(in: stage, bubbleSize: bubble, avoiding: []), .below)
    }

    func testWindowBehindUpperBubbleKeepsDialogueBelow() {
        let window = CGRect(x: 150, y: 100, width: 200, height: 200)
        XCTAssertEqual(PetDialoguePlacement.preferred(in: stage, bubbleSize: bubble, avoiding: [window]), .below)
    }

    func testLowerBoardMovesDialogueAbove() {
        let board = PetDialoguePlacement.below.frames(in: stage, bubbleSize: bubble).bubble
        XCTAssertEqual(PetDialoguePlacement.preferred(in: stage, bubbleSize: bubble, avoiding: [board]), .above)
    }

    func testChoosesLessObstructedSideWhenBothAreCovered() {
        let upper = PetDialoguePlacement.above.frames(in: stage, bubbleSize: bubble).bubble
        let lower = PetDialoguePlacement.below.frames(in: stage, bubbleSize: bubble).bubble
        let smallUpperBoard = CGRect(x: upper.minX, y: upper.minY, width: 40, height: 40)
        XCTAssertEqual(PetDialoguePlacement.preferred(in: stage, bubbleSize: bubble,
                                                    avoiding: [smallUpperBoard, lower]), .above)
        XCTAssertEqual(PetDialoguePlacement.preferred(in: stage, bubbleSize: bubble,
                                                    avoiding: [upper, lower]), .below)
    }

    func testSideBoardsAndSmallMeasurementDifferencesKeepDialogueBelow() {
        let beside = CGRect(x: stage.maxX + 20, y: stage.minY, width: 100, height: stage.height)
        XCTAssertEqual(PetDialoguePlacement.preferred(in: stage, bubbleSize: bubble, avoiding: [beside]), .below)
        let lower = PetDialoguePlacement.below.frames(in: stage, bubbleSize: bubble).bubble
        let almostOutside = CGRect(x: lower.maxX + 7.5, y: lower.minY, width: 40, height: 40)
        XCTAssertEqual(PetDialoguePlacement.preferred(in: stage, bubbleSize: bubble, avoiding: [almostOutside]), .below)
    }

    func testLongDialogueFitsShortStageOnEitherSideWithoutCoveringPetBody() {
        let shortStage = CGRect(x: 40, y: 80, width: 200, height: 220)
        let longBubble = CGSize(width: 200, height: 140)
        for placement in [PetDialoguePlacement.above, .below] {
            let frames = placement.frames(in: shortStage, bubbleSize: longBubble)
            XCTAssertTrue(shortStage.contains(frames.bubble))
            XCTAssertTrue(shortStage.contains(frames.pet))
            XCTAssertEqual(frames.pet.intersection(frames.bubble).height, placement.overlap, accuracy: 0.01)
        }
    }
}
