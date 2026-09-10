import Foundation
import SwiftUI
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

extension View {
    /// Fires a tap the moment a button style reports its press, rather than when its action runs.
    ///
    /// Touch-down is the only moment that feels *caused* by the finger. An action-time buzz lands
    /// after the press animation and reads as a separate reply to the tap — and for anything that
    /// awaits, it lands whenever the network gets around to it. The button styles in the design
    /// system all feed this, which is what makes the whole app answer to touch without every call
    /// site remembering to ask.
    ///
    /// Firing on the press rather than on the action does mean a touch dragged off the control has
    /// already buzzed. That is the same bargain the system keyboard makes, and the alternative — a
    /// button that stays silent until you commit — is the thing being fixed here.
    func hapticPress(_ isPressed: Bool, style: UIImpactFeedbackGenerator.FeedbackStyle) -> some View {
        onChange(of: isPressed) { _, pressed in
            if pressed { Haptics.tap(style) }
        }
    }
}

/// The UIKit half of the same bargain the button styles make in SwiftUI.
///
/// The Messages extension is the only place in the app that builds buttons by hand, and wiring the
/// feel into the same call that wires the action is what keeps the two from drifting apart — a
/// button added later cannot pick up one without the other.
extension UIButton {
    /// Runs `action` on release, and answers the press on the way down.
    ///
    /// Touch-down for the reason argued above: the feel belongs to the press, not to whatever the
    /// press eventually starts.
    func addHapticAction(
        _ target: Any?,
        action: Selector,
        feedback: UIImpactFeedbackGenerator.FeedbackStyle = .light
    ) {
        addTarget(target, action: action, for: .touchUpInside)
        addAction(UIAction { _ in Haptics.tap(feedback) }, for: .touchDown)
    }

    /// The same, for a button that changes a value rather than starting something — removing a
    /// reference photo, say. A selection tick on the release, which is when the value changes.
    func addHapticSelection(_ target: Any?, action: Selector) {
        addTarget(target, action: action, for: .touchUpInside)
        addAction(UIAction { _ in Haptics.selection() }, for: .touchUpInside)
    }
}
