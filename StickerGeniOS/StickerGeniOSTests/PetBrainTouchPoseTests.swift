import AnimatedView
import XCTest
@testable import StickerGeniOS

/// Answers every touch with the pose Jev would have picked.
private actor TouchPoseAPI: StickerAPIClientProtocol {
    private(set) var touches: [String] = []
    let pose: [String: AnimatedControlValue]

    init(pose: [String: AnimatedControlValue]) { self.pose = pose }

    func petTouchPose(_ touch: PetTouch, shown: [String: AnimatedControlValue]) async throws -> [String: AnimatedControlValue] {
        touches.append(touch.wireName)
        return pose
    }
}

@MainActor
final class PetBrainTouchPoseTests: XCTestCase {
    private let mood = AnimatedControl(
        id: "mood", label: "Mood", type: .choice, defaultValue: .string("calm"),
        options: [.init(id: "calm", label: "Calm"), .init(id: "giggle", label: "Giggling")]
    )
    private let blush = AnimatedControl(id: "blush", label: "Blush", type: .toggle, defaultValue: .bool(false))
    private let speed = AnimatedControl(
        id: "speed", label: "Speed", type: .number, defaultValue: .number(1), binding: "speed", minimum: 0.25, maximum: 2
    )
    private let single = AnimatedControl(
        id: "hat", label: "Hat", type: .choice, defaultValue: .string("cap"), options: [.init(id: "cap", label: "Cap")]
    )
    private let pet = Pet(sticker: PreviewFixtures.borrowedSticker, selectedAt: Date(timeIntervalSince1970: 0))

    func testOnlyControlsWithSomethingToChooseArePosable() {
        let posable = PetBrain.posableControls([mood, blush, speed, single])
        XCTAssertEqual(posable.map(\.id), ["mood", "blush"])
    }

    func testTouchesAreNamedAsTheServerExpects() {
        XCTAssertEqual(PetTouch.heldTooLong.wireName, "held_too_long")
        XCTAssertEqual(PetTouch.swipe(.up).wireName, "swipe_up")
    }

    func testTouchStrikesThePoseJevPicked() async {
        let api = TouchPoseAPI(pose: ["mood": .string("giggle")])
        let brain = PetBrain(api: api)
        let struck = expectation(description: "pose struck")
        brain.react(to: .tap, pet: pet, controls: [mood, blush]) { values in
            XCTAssertEqual(values, ["mood": .string("giggle")])
            struck.fulfill()
        }
        await fulfillment(of: [struck], timeout: 5)
        let touches = await api.touches
        XCTAssertEqual(touches, ["tap"])
    }

    func testNoPoseIsAskedForWithoutControlsToPose() async throws {
        let api = TouchPoseAPI(pose: ["hat": .string("cap")])
        let brain = PetBrain(api: api)
        brain.react(to: .tap, pet: pet, controls: [speed, single]) { _ in XCTFail("nothing to pose") }
        try await Task.sleep(for: .milliseconds(200))
        let touches = await api.touches
        XCTAssertTrue(touches.isEmpty)
    }
}
