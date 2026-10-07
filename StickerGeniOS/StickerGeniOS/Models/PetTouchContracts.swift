import AnimatedView
import Foundation

/// A touch on the pet, for its decision model on the server to strike a pose in reaction to.
nonisolated struct PetTouchRequest: Codable, Equatable, Sendable {
    var touch: String
    /// The pose the phone shows now, when an earlier touch moved it off the stored pose.
    var pose: [String: AnimatedControlValue]?
}

/// The controls the pet changed in reaction to a touch; empty when it holds its pose.
nonisolated struct PetTouchResponse: Codable, Equatable, Sendable {
    var values: [String: AnimatedControlValue]
}

extension PetTouch {
    /// How the server names this touch.
    nonisolated var wireName: String {
        switch self {
        case .tap: "tap"
        case .release: "release"
        case .heldTooLong: "held_too_long"
        case .swipe(.left): "swipe_left"
        case .swipe(.right): "swipe_right"
        case .swipe(.up): "swipe_up"
        case .swipe(.down): "swipe_down"
        case .overwhelmed: "overwhelmed"
        case .shaken: "shaken"
        }
    }
}
