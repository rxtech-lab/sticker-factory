import Foundation
import UIKit

/// Every vibration the app produces, in one place.
///
/// Two rules keep it from buzzing at people. Feedback only ever accompanies something the user can
/// also see, so nothing fires from a background poll or a refetch they did not ask for. And anything
/// that repeats — the agent writing a reply, token by token — goes through `StreamHaptics`, which
/// rate-limits it into a texture rather than a stutter.
///
/// Generators are cached and re-prepared after every use: one built at the moment of the tap warms
/// the Taptic Engine only *after* being asked to fire, which lands late enough to feel detached from
/// the touch that caused it. Users who turn System Haptics off get nothing from any of this, because
/// UIKit already silences the generators — there is no separate switch to honour here.
@MainActor
enum Haptics {
    /// A direct answer to a tap: sending, stopping, opening the editor.
    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light, intensity: CGFloat = 1) {
        let generator = impactGenerators[style] ?? {
            let generator = UIImpactFeedbackGenerator(style: style)
            impactGenerators[style] = generator
            return generator
        }()
        generator.impactOccurred(intensity: intensity)
        generator.prepare()
    }

    /// A value changed under the user's finger — a reference chip removed, a sticker picked.
    static func selection() {
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    /// Something the user was waiting for landed: a candidate, an export, a saved edit.
    static func success() { notify(.success) }

    /// Something degraded but recoverable — the live connection dropped, the turn is still there.
    static func warning() { notify(.warning) }

    /// The action did not happen. Always paired with the message that says why.
    static func failure() { notify(.error) }

    private static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        notificationGenerator.notificationOccurred(type)
        notificationGenerator.prepare()
    }

    private static var impactGenerators: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let notificationGenerator = UINotificationFeedbackGenerator()
}

/// The agent writing, felt rather than watched.
///
/// Streamed text arrives in whatever chunks the model and the network happen to produce, which is
/// far too often — and far too unevenly — to map one chunk to one tick. So a tick needs both enough
/// new text behind it and enough time since the last one, which turns a ragged stream into a steady
/// pulse that stops when the writing does.
///
/// The clock and the tick are injectable so the throttle can be tested without a device; nothing in
/// the app passes them.
@MainActor
final class StreamHaptics {
    /// Characters that must accumulate before a tick is even considered.
    private static let charactersPerTick = 12
    /// The floor on the gap between two ticks. Below roughly this, successive taps stop reading as
    /// separate events and start reading as one continuous buzz.
    private static let minimumInterval: TimeInterval = 0.14

    private let now: () -> Date
    private let tick: () -> Void
    private var lastTick: Date = .distantPast
    private var lastCharacterCount = 0

    init(now: @escaping () -> Date = { Date() }, tick: @escaping () -> Void = { Haptics.tap(.soft, intensity: 0.32) }) {
        self.now = now
        self.tick = tick
    }

    /// Starts a fresh turn. Without this the first chunk of a new reply is measured against the
    /// length of the previous one and the whole opening of the message passes unfelt.
    func beginTurn() {
        lastTick = .distantPast
        lastCharacterCount = 0
    }

    /// Reports how much the assistant has written so far in this turn.
    func typed(characterCount: Int) {
        // A shorter message than last time is not backspacing — it is a different message, or a
        // refetch that replaced the streamed text. Re-baseline rather than tick.
        guard characterCount > lastCharacterCount else {
            lastCharacterCount = characterCount
            return
        }
        guard characterCount - lastCharacterCount >= Self.charactersPerTick else { return }
        let instant = now()
        guard instant.timeIntervalSince(lastTick) >= Self.minimumInterval else { return }
        lastCharacterCount = characterCount
        lastTick = instant
        tick()
    }
}
