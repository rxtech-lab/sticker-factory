import XCTest
@testable import StickerGeniOS

@MainActor
final class PetMotionTests: XCTestCase {
    private func stats(happiness: Int = 60, hp: Int = 100, energy: Int = 60) -> PetStats {
        PetStats(happiness: happiness, hp: hp, energy: energy, gold: 0)
    }

    func testMoodFollowsTheWorstNeedFirst() {
        // Hurt outranks tired, and tired outranks cross.
        XCTAssertEqual(PetMood(stats: stats(happiness: 10, hp: 20, energy: 10), maxHp: 100), .sick)
        XCTAssertEqual(PetMood(stats: stats(happiness: 10, energy: 10), maxHp: 100), .sleepy)
        XCTAssertEqual(PetMood(stats: stats(happiness: 10), maxHp: 100), .grumpy)
        XCTAssertEqual(PetMood(stats: stats(happiness: 90), maxHp: 100), .joyful)
        XCTAssertEqual(PetMood(stats: stats(), maxHp: 100), .content)
    }

    func testSicknessIsMeasuredAgainstTheClassCeiling() {
        XCTAssertEqual(PetMood(stats: stats(hp: 50), maxHp: 200), .sick)
        XCTAssertEqual(PetMood(stats: stats(hp: 50), maxHp: 100), .content)
    }

    func testNatureChangesHowAHappyPetReacts() {
        let athlete = PetMotionProfile(mood: .joyful, petClass: .athlete)
        let trickster = PetMotionProfile(mood: .joyful, petClass: .trickster)
        XCTAssertTrue(athlete.move(forPat: 0).rebounds)
        XCTAssertTrue(trickster.move(forPat: 0).turns)
        XCTAssertNotEqual(athlete.particle, trickster.particle)
    }

    func testMoodOverridesNatureWhenThePetIsLow() {
        let tiredAthlete = PetMotionProfile(mood: .sleepy, petClass: .athlete)
        XCTAssertEqual(tiredAthlete.move(forPat: 0).hop, 0)
        XCTAssertEqual(tiredAthlete.particle.symbol, "zzz")
    }

    func testEachTouchGetsItsOwnReaction() {
        let pet = PetMotionProfile(mood: .content, petClass: nil)
        let touches: [PetTouch] = [.tap, .release, .heldTooLong, .swipe(.left), .swipe(.up), .swipe(.down), .overwhelmed]
        let reactions = touches.map { pet.reaction(to: $0) }
        for (index, reaction) in reactions.enumerated() {
            for other in reactions[(index + 1)...] { XCTAssertNotEqual(reaction, other) }
        }
    }

    func testStrokesLeanWithTheSwipe() {
        let pet = PetMotionProfile(mood: .content, petClass: nil)
        XCTAssertGreaterThan(pet.reaction(to: .swipe(.right)).move.tilts[0], 0)
        XCTAssertLessThan(pet.reaction(to: .swipe(.left)).move.tilts[0], 0)
    }

    func testHoldingTooLongDependsOnMoodAndNature() {
        XCTAssertTrue(PetMotionProfile(mood: .sleepy, petClass: .athlete).fallsAsleepWhenHeld)
        XCTAssertTrue(PetMotionProfile(mood: .content, petClass: .dreamer).fallsAsleepWhenHeld)
        XCTAssertFalse(PetMotionProfile(mood: .content, petClass: .athlete).fallsAsleepWhenHeld)
        XCTAssertLessThan(
            PetMotionProfile(mood: .grumpy, petClass: nil).holdPatience,
            PetMotionProfile(mood: .joyful, petClass: nil).holdPatience
        )
        XCTAssertLessThan(
            PetMotionProfile(mood: .content, petClass: .trickster).holdPatience,
            PetMotionProfile(mood: .content, petClass: .guardian).holdPatience
        )
    }

    func testGrumpyPetLeansAwayFromTheHand() {
        let grumpy = PetMotionProfile(mood: .grumpy, petClass: nil).holdPose(asleep: false, lean: 1)
        let content = PetMotionProfile(mood: .content, petClass: nil).holdPose(asleep: false, lean: 1)
        XCTAssertLessThan(grumpy.tilt, 0)
        XCTAssertGreaterThan(content.tilt, 0)
    }

    func testTiringEasilySlowsEveryMove() {
        let tireless = PetMotionProfile(mood: .content, petClass: nil, energyMultiplier: 0.5)
        let weary = PetMotionProfile(mood: .content, petClass: nil, energyMultiplier: 2)
        XCTAssertLessThan(tireless.move(forPat: 0).duration, weary.move(forPat: 0).duration)
        XCTAssertLessThan(tireless.breathPeriod, weary.breathPeriod)
    }

    func testGreetingSpeaksOnlyWhenNeededOrAfterAWhile() {
        // Back from a quick look elsewhere, a happy pet just hops.
        XCTAssertNil(PetBrain.greetingLine(for: .joyful, away: 60))
        XCTAssertNotNil(PetBrain.greetingLine(for: .content, away: PetBrain.quietReturn))
        XCTAssertNotNil(PetBrain.greetingLine(for: .content, away: nil))
        // A pet that needs something always says so.
        for mood in [PetMood.sick, .sleepy, .grumpy] {
            XCTAssertNotNil(PetBrain.greetingLine(for: mood, away: 10))
        }
    }

    func testGreetingHopsHigherWhenJoyful() {
        let joyful = PetMotionProfile(mood: .joyful, petClass: nil).greeting.move
        let content = PetMotionProfile(mood: .content, petClass: nil).greeting.move
        XCTAssertGreaterThan(joyful.hop, content.hop)
        XCTAssertGreaterThan(content.hop, 0)
    }
}
