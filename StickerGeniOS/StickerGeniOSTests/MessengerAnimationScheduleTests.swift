import Foundation
import Testing
@testable import StickerGeniOS

@Suite("Messenger animation schedule")
struct MessengerAnimationScheduleTests {
    @Test("An animation within the limits keeps its speed and its frames")
    func unchanged() {
        let delays = [Int](repeating: 100, count: 20) // 2 s at 10 fps
        let schedule = MessengerAnimationSchedule.plan(
            sourceDelaysMilliseconds: delays,
            maximumDurationMilliseconds: 3_000,
            maximumFramesPerSecond: 30,
            minimumFrameDurationMilliseconds: 33
        )
        #expect(schedule.speedFactor == 1)
        #expect(!schedule.isAccelerated)
        #expect(schedule.frames.count == 20)
        #expect(schedule.frames.map(\.sourceIndex) == Array(0..<20))
        #expect(schedule.durationMilliseconds == 2_000)
    }

    @Test("An animation past the limit is sped up to fit exactly, keeping its whole cycle")
    func accelerated() {
        let delays = [Int](repeating: 40, count: 150) // 6 s at 25 fps
        let schedule = MessengerAnimationSchedule.plan(
            sourceDelaysMilliseconds: delays,
            maximumDurationMilliseconds: 3_000,
            maximumFramesPerSecond: 30,
            minimumFrameDurationMilliseconds: 33
        )
        #expect(abs(schedule.speedFactor - 2) < 0.001)
        #expect(schedule.isAccelerated)
        #expect(schedule.durationMilliseconds == 3_000)
        // The first and the last source frames both survive: the loop is compressed, not cut.
        #expect(schedule.frames.first?.sourceIndex == 0)
        #expect(schedule.frames.last!.sourceIndex >= 145)
        #expect(schedule.frames.allSatisfy { $0.durationMilliseconds >= 33 })
        // Monotonic through the source.
        #expect(zip(schedule.frames, schedule.frames.dropFirst()).allSatisfy { $0.sourceIndex < $1.sourceIndex })
    }

    @Test("A dense source is thinned to the frame-rate ceiling without changing its length")
    func thinned() {
        let delays = [Int](repeating: 17, count: 120) // ~2 s at 60 fps
        let schedule = MessengerAnimationSchedule.plan(
            sourceDelaysMilliseconds: delays,
            maximumDurationMilliseconds: 10_000,
            maximumFramesPerSecond: 24,
            minimumFrameDurationMilliseconds: 8
        )
        #expect(schedule.speedFactor == 1)
        #expect(schedule.durationMilliseconds == 2_040)
        #expect(schedule.frames.count <= 50)
        #expect(schedule.frames.count >= 45)
    }

    @Test("The loop hold on the last frame is compressed with everything else")
    func loopHold() {
        var delays = [Int](repeating: 33, count: 90) // ~3 s
        delays[delays.count - 1] += 600 // the exporter's loop hold
        let schedule = MessengerAnimationSchedule.plan(
            sourceDelaysMilliseconds: delays,
            maximumDurationMilliseconds: 3_000,
            maximumFramesPerSecond: 30,
            minimumFrameDurationMilliseconds: 33
        )
        #expect(schedule.isAccelerated)
        #expect(schedule.durationMilliseconds == 3_000)
        #expect(schedule.frames.last!.durationMilliseconds > 33)
    }

    @Test("Empty input yields an empty schedule")
    func empty() {
        let schedule = MessengerAnimationSchedule.plan(sourceDelaysMilliseconds: [], maximumDurationMilliseconds: 3_000, maximumFramesPerSecond: 30, minimumFrameDurationMilliseconds: 33)
        #expect(schedule.frames.isEmpty)
    }
}
