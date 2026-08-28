import Foundation

/// How a subject is lifted out of a photo, and how much of a Live Photo comes with it.
///
/// Worth being honest about what these are: Vision's foreground-instance mask request exposes
/// essentially nothing to tune beyond its revision. Every knob here is *our* policy — what
/// resolution we segment at, how much we soften the alpha edge, how hard we smooth across frames,
/// how many frames we take. None of it is a Vision setting, and naming them as if they were would
/// invite someone to go looking for the API that backs them.
///
/// Only two of these are ever surfaced in the UI. The rest are defaults tuned once against real
/// footage; exposing them all would be a quality slider the user cannot evaluate.
nonisolated struct SubjectLiftSettings: Sendable, Equatable, Codable {
    /// What resolution the segmenter runs at.
    ///
    /// This is the single biggest lever on how long a lift takes, because the mask request runs
    /// once per frame. Downscaling also acts as a noise filter — a mask derived at 1280 and scaled
    /// up has softer, more stable edges than one derived at full camera resolution.
    enum Quality: String, Codable, CaseIterable, Sendable {
        /// Segment at 1280 on the long edge.
        case balanced
        /// Segment at the frame's native size. Slower, and not always better.
        case maximum

        var segmentationLongEdge: CGFloat? {
            switch self {
            case .balanced: 1280
            case .maximum: nil
            }
        }

        var label: String {
            switch self {
            case .balanced: String(localized: "Balanced")
            case .maximum: String(localized: "Maximum")
            }
        }
    }

    /// Which instance to keep when a frame contains several.
    enum InstanceSelection: String, Codable, Sendable {
        /// The one the user picked on the still, tracked forward and backward through the footage.
        case tapped
        /// Whatever occupies the most area. Used when there is no interactive pick to track.
        case largest
        /// Everything Vision considers foreground, merged into one cut-out.
        case allSubjects
    }

    var quality: Quality = .balanced
    var instanceSelection: InstanceSelection = .tapped
    /// Softens the alpha edge, in pixels of the segmented frame. Kills single-pixel edge crawl.
    var edgeFeatherPixels: Double = 1.25
    /// How much of the previous frame's alpha carries into this one. 0 disables it.
    var temporalSmoothing: Double = 0.35
    /// Instances smaller than this fraction of the frame are never candidates.
    var minimumInstanceAreaFraction: Double = 0.005
    /// How much of the paired video to keep, centred on the frame the user was shown.
    var windowSeconds: Double = 1.2
    var frameCount: Int = 12
    var frameRate: Double = 10
    /// The side of one square tile in the encoded atlas.
    var tilePixels: Int = 640

    static let `default` = SubjectLiftSettings()

    /// More frames, smaller tiles. Opt-in rather than default: photographic frames index badly to
    /// 256 colours, so a longer sequence is markedly harder to squeeze under Apple's 500 KB ceiling
    /// for a Messages sticker, and falls back to a still more often.
    static let smooth = SubjectLiftSettings(frameCount: 16, frameRate: 12, tilePixels: 512)

    /// A single still, for a photo with no paired video or when the user turns motion off.
    static let still = SubjectLiftSettings(windowSeconds: 0, frameCount: 1, frameRate: 1)

    /// The grid the encoder will pack `frameCount` tiles into.
    ///
    /// Wide rather than tall, and never more than 8 of either — the contract's bound, chosen so a
    /// sheet stays inside the 4096px-per-side limit that upload validation enforces.
    var grid: (columns: Int, rows: Int) {
        let count = max(1, frameCount)
        let columns = min(8, max(1, Int(Double(count).squareRoot().rounded(.up))))
        let rows = min(8, max(1, Int((Double(count) / Double(columns)).rounded(.up))))
        return (columns, rows)
    }

    /// Seconds of footage this produces, which becomes the sticker's authored duration.
    var captureSeconds: Double {
        frameRate > 0 ? Double(frameCount) / frameRate : 0
    }
}
