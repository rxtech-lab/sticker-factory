import Foundation

/// Which source frames an exported animation shows, for how long — after it has been fitted into
/// the messenger's duration and frame-rate ceilings.
///
/// A sticker that runs longer than the messenger allows is sped up rather than cut: the whole
/// motion is kept and plays faster. The alternative, dropping the tail, throws away the part of a
/// loop that makes it a loop. Pure so the arithmetic can be tested without decoding anything.
nonisolated struct MessengerAnimationSchedule: Equatable, Sendable {
    struct Frame: Equatable, Sendable {
        var sourceIndex: Int
        var durationMilliseconds: Int
    }

    var frames: [Frame]
    /// How much faster the export plays than the source. 1 when nothing had to change.
    var speedFactor: Double

    var durationMilliseconds: Int { frames.reduce(0) { $0 + $1.durationMilliseconds } }
    var isAccelerated: Bool { speedFactor > 1.001 }

    /// - Parameter sourceDelaysMilliseconds: each source frame's display time, in order.
    /// - Parameter maximumDurationMilliseconds: the messenger's ceiling on the whole animation.
    /// - Parameter maximumFramesPerSecond: the densest the export samples the (compressed)
    ///   timeline. A source at 30 FPS exported at 24 keeps its speed and drops every fifth frame.
    /// - Parameter minimumFrameDurationMilliseconds: the messenger's floor per frame.
    static func plan(
        sourceDelaysMilliseconds: [Int],
        maximumDurationMilliseconds: Int,
        maximumFramesPerSecond: Int,
        minimumFrameDurationMilliseconds: Int
    ) -> MessengerAnimationSchedule {
        let delays = sourceDelaysMilliseconds.map { max(1, $0) }
        guard !delays.isEmpty else { return .init(frames: [], speedFactor: 1) }
        let sourceTotal = delays.reduce(0, +)
        let speed = max(1, Double(sourceTotal) / Double(maximumDurationMilliseconds))
        let compressedTotal = min(maximumDurationMilliseconds, Int((Double(sourceTotal) / speed).rounded()))
        let step = max(minimumFrameDurationMilliseconds, Int((1_000 / Double(max(1, maximumFramesPerSecond))).rounded()))

        // Source frame boundaries on the compressed timeline.
        var starts: [Int] = []
        var cursor = 0
        for delay in delays {
            starts.append(cursor)
            cursor += delay
        }

        var frames: [Frame] = []
        var time = 0
        var sourceIndex = 0
        while time < compressedTotal {
            let sourceTime = Double(time) * speed
            // Advance to the source frame showing at this instant; the timeline only moves forward.
            while sourceIndex + 1 < delays.count, Double(starts[sourceIndex + 1]) <= sourceTime {
                sourceIndex += 1
            }
            let end = min(compressedTotal, time + step)
            if let last = frames.indices.last, frames[last].sourceIndex == sourceIndex {
                // The same source frame is still showing: extend it rather than repeating it, so a
                // slow source is not padded out to the sampling rate with duplicate frames.
                frames[last].durationMilliseconds += end - time
            } else {
                frames.append(.init(sourceIndex: sourceIndex, durationMilliseconds: end - time))
            }
            time = end
        }
        // A trailing sliver shorter than the floor is folded into the frame before it.
        if frames.count > 1, let last = frames.last, last.durationMilliseconds < minimumFrameDurationMilliseconds {
            frames[frames.count - 2].durationMilliseconds += last.durationMilliseconds
            frames.removeLast()
        }
        return .init(frames: frames, speedFactor: speed)
    }
}
