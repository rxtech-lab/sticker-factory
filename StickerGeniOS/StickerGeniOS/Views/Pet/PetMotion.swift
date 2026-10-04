import SwiftUI

/// How the pet feels right now, read from its stats. Drives how it moves at rest and how it takes
/// a pat: a joyful pet bounces into it, a sleepy one barely stirs, a grumpy one shakes it off.
///
/// The worst need wins, in the order a carer would notice it: a hurt pet is hurt before it is
/// tired, and a tired pet is tired before it is cross.
enum PetMood: Equatable {
    case sick
    case sleepy
    case grumpy
    case content
    case joyful

    init(stats: PetStats, maxHp: Int) {
        if Double(stats.hp) < Double(max(maxHp, 1)) * 0.3 {
            self = .sick
        } else if stats.energy < 25 {
            self = .sleepy
        } else if stats.happiness < 35 {
            self = .grumpy
        } else if stats.happiness >= 75 {
            self = .joyful
        } else {
            self = .content
        }
    }
}

/// Everything the pet's body does: its resting motion, its reactions to a pat, and what a pat
/// sends up. Mood sets how much it moves; nature — its class and stamina — sets how.
struct PetMotionProfile: Equatable {
    let mood: PetMood
    let petClass: PetClass?
    /// Scales every duration: a pet that tires easily moves slower, a tireless one snappier.
    let tempo: Double

    init(mood: PetMood, petClass: PetClass?, energyMultiplier: Double = 1) {
        self.mood = mood
        self.petClass = petClass
        tempo = min(max(energyMultiplier, 0.8), 1.3)
    }

    init(pet: Pet) {
        self.init(
            mood: PetMood(stats: pet.stats, maxHp: pet.maxHp),
            petClass: pet.identity?.petClass,
            energyMultiplier: pet.identity?.energyMultiplier ?? 1
        )
    }

    // MARK: Resting

    /// Seconds for one breath.
    var breathPeriod: Double {
        let base: Double = switch mood {
        case .joyful: 2.0
        case .content: 2.6
        case .grumpy: 2.9
        case .sleepy: 4.2
        case .sick: 3.4
        }
        let nature: Double = switch petClass {
        case .athlete?, .trickster?: 0.8
        case .dreamer?: 1.2
        default: 1
        }
        return base * nature * tempo
    }

    /// How far a breath stretches the pet, as a fraction of its height.
    var breathDepth: Double {
        switch mood {
        case .joyful: 0.026
        case .content: 0.022
        case .grumpy: 0.014
        case .sleepy: 0.034
        case .sick: 0.01
        }
    }

    /// Degrees the pet sways either way.
    var swayAngle: Double {
        let base: Double = switch mood {
        case .joyful: 2.2
        case .content: 1.6
        case .grumpy: 0.5
        case .sleepy: 1.2
        case .sick: 0.8
        }
        let nature: Double = switch petClass {
        case .guardian?: 0.5
        case .explorer?, .trickster?: 1.4
        default: 1
        }
        return base * nature
    }

    /// Points the pet floats up and down at rest. Dreamers drift; a joyful pet has a spring in it.
    var floatHeight: Double {
        switch (mood, petClass) {
        case (.sick, _), (.sleepy, _), (.grumpy, _): 0
        case (_, .dreamer?): 5
        case (.joyful, _): 2.5
        default: 0
        }
    }

    /// A tired or hurt pet slumps a little all the time.
    var slump: Double {
        switch mood {
        case .sick: 0.96
        case .sleepy: 0.98
        default: 1
        }
    }

    // MARK: Reacting

    /// The reaction to the `pat`th pat. Each mood and nature offers a couple, taken in turn, so
    /// patting again is not a replay.
    func move(forPat pat: Int) -> PetMove {
        let moves = availableMoves
        return moves[pat % moves.count].scaled(by: tempo)
    }

    private var availableMoves: [PetMove] {
        switch mood {
        case .sick:
            // Too weak to hop: a wince and a wobble.
            return [PetMove(squash: 0.06, stretch: 1.0, hop: 0, tilts: [-3, 2, -1, 0], duration: 1.4)]
        case .sleepy:
            // A drowsy nod: sinks, lifts its head, sinks again.
            return [PetMove(squash: 0.1, stretch: 1.02, hop: 0, tilts: [4, 4, -2, 0], duration: 1.6)]
        case .grumpy:
            // Shakes the pat off, quick and stiff, and stamps.
            return [
                PetMove(squash: 0.04, stretch: 1.0, hop: 0, tilts: [-7, 7, -6, 4], duration: 0.8),
                PetMove(squash: 0.12, stretch: 1.04, hop: 4, tilts: [0, 0, 0, 0], duration: 0.6)
            ]
        case .content, .joyful:
            let joy = mood == .joyful ? 1.4 : 1.0
            return natureMoves.map { $0.amplified(by: joy) }
        }
    }

    /// The happy reactions, in the pet's own style.
    private var natureMoves: [PetMove] {
        switch petClass {
        case .guardian?:
            // Stands proud: puffs up, a firm nod, no nonsense.
            return [
                PetMove(squash: 0.05, stretch: 1.08, hop: 0, tilts: [0, 0, 0, 0], duration: 0.8),
                PetMove(squash: 0.08, stretch: 1.05, hop: 6, tilts: [2, -2, 0, 0], duration: 0.7)
            ]
        case .explorer?:
            // Looks this way and that, then bounds forward.
            return [
                PetMove(squash: 0.05, stretch: 1.04, hop: 4, tilts: [-9, -9, 9, 0], duration: 1.0),
                PetMove(squash: 0.1, stretch: 1.1, hop: 18, tilts: [6, 0, 0, 0], duration: 0.8)
            ]
        case .dreamer?:
            // Floats up slowly and settles like a feather.
            return [PetMove(squash: 0.04, stretch: 1.06, hop: 20, tilts: [3, -3, 2, 0], duration: 1.4, settles: true)]
        case .trickster?:
            // Spins around to face away and back, or a cheeky wiggle.
            return [
                PetMove(squash: 0.08, stretch: 1.06, hop: 10, tilts: [0, 0, 0, 0], duration: 0.8, turns: true),
                PetMove(squash: 0.06, stretch: 1.05, hop: 6, tilts: [-10, 10, -8, 5], duration: 0.8)
            ]
        case .scholar?:
            // Tilts its head thoughtfully, then a small, pleased bob.
            return [
                PetMove(squash: 0.04, stretch: 1.03, hop: 0, tilts: [8, 8, 8, 0], duration: 1.1),
                PetMove(squash: 0.06, stretch: 1.05, hop: 6, tilts: [0, 0, 0, 0], duration: 0.6)
            ]
        case .athlete?:
            // Big springy hops, landing with a second bounce.
            return [
                PetMove(squash: 0.12, stretch: 1.12, hop: 24, tilts: [0, 0, 0, 0], duration: 0.8, rebounds: true),
                PetMove(squash: 0.1, stretch: 1.1, hop: 16, tilts: [-6, 6, 0, 0], duration: 0.7, rebounds: true)
            ]
        default:
            return [
                PetMove(squash: 0.1, stretch: 1.1, hop: 20, tilts: [0, 0, 0, 0], duration: 0.65),
                PetMove(squash: 0.08, stretch: 1.06, hop: 8, tilts: [-9, 9, -5, 3], duration: 0.75)
            ]
        }
    }

    /// What floats up from a pat.
    var particle: PetParticle {
        switch mood {
        case .sick: PetParticle(symbol: "drop.fill", color: .teal, count: 2, rise: 34)
        case .sleepy: PetParticle(symbol: "zzz", color: .indigo, count: 1, rise: 44)
        case .grumpy: PetParticle(symbol: "cloud.bolt.fill", color: .gray, count: 1, rise: 30)
        case .content: PetParticle(symbol: "heart.fill", color: .pink, count: 2, rise: 50)
        case .joyful:
            switch petClass {
            case .dreamer?: PetParticle(symbol: "sparkles", color: .purple, count: 3, rise: 60)
            case .trickster?: PetParticle(symbol: "star.fill", color: .yellow, count: 3, rise: 60)
            default: PetParticle(symbol: "heart.fill", color: .pink, count: 3, rise: 60)
            }
        }
    }

    /// How the pat feels in the hand: a happy pet bounces back, a tired one barely answers.
    var tapHaptic: PetHaptic {
        switch mood {
        case .joyful: .impact(.medium)
        case .content: .impact(.soft)
        case .grumpy: .impact(.rigid, intensity: 0.7)
        case .sleepy: .impact(.soft, intensity: 0.4)
        case .sick: .impact(.soft, intensity: 0.3)
        }
    }

    // MARK: Touching

    /// The pet's whole reaction to one kind of touch. `variant` counts touches, so a pet with more
    /// than one answer to a touch takes them in turn.
    func reaction(to touch: PetTouch, variant: Int = 0) -> PetReaction {
        let joy = mood == .joyful ? 1.3 : 1.0
        switch touch {
        case .tap:
            return PetReaction(move: move(forPat: variant), particle: particle, haptic: tapHaptic)

        case .release:
            // Let go after a cuddle: a happy pet shakes itself out pleased, the rest just settle.
            switch mood {
            case .joyful:
                return reacting(PetMove(squash: 0.08, stretch: 1.08, hop: 12, tilts: [-5, 5, -3, 0], duration: 0.8),
                                PetParticle(symbol: "heart.fill", color: .pink, count: 2, rise: 50), .impact(.light))
            case .grumpy:
                // Glad to be free of it.
                return reacting(PetMove(squash: 0.04, stretch: 1.03, hop: 0, tilts: [-6, 6, -3, 0], duration: 0.6),
                                nil, .impact(.rigid, intensity: 0.5))
            default:
                return reacting(PetMove(squash: 0.05, stretch: 1.03, hop: 0, tilts: [0, 0, 0, 0], duration: 0.9),
                                nil, .impact(.soft, intensity: 0.5))
            }

        case .heldTooLong:
            if fallsAsleepWhenHeld {
                // Dozes off right there in the hand.
                return reacting(PetMove(squash: 0.12, stretch: 1.0, hop: 0, tilts: [3, 5, 5, 4], duration: 1.8),
                                PetParticle(symbol: "zzz", color: .indigo, count: 2, rise: 50), .impact(.soft, intensity: 0.4))
            }
            if mood == .grumpy {
                // Had enough: tears itself free in a huff.
                return reacting(PetMove(squash: 0.12, stretch: 1.08, hop: 10, tilts: [-14, 14, -12, 8], duration: 0.6),
                                PetParticle(symbol: "cloud.bolt.fill", color: .gray, count: 3, rise: 44), .warning)
            }
            // Squirms and wriggles out of the hand.
            return reacting(PetMove(squash: 0.1, stretch: 1.08, hop: 14, tilts: [-12, 12, -10, 6], duration: 0.7),
                            PetParticle(symbol: "exclamationmark.2", color: .orange, count: 1, rise: 40), .impact(.rigid))

        case .swipe(let direction) where direction == .left || direction == .right:
            // A stroke along the side: the pet leans into it, or bristles.
            let side: Double = direction == .right ? 1 : -1
            switch mood {
            case .grumpy:
                return reacting(PetMove(squash: 0.06, stretch: 1.04, hop: 0, tilts: [-side * 8, side * 8, -side * 6, 0], duration: 0.6),
                                PetParticle(symbol: "cloud.bolt.fill", color: .gray, count: 1, rise: 30), .impact(.rigid, intensity: 0.6))
            case .sick:
                // Soothed by it.
                return reacting(PetMove(squash: 0.03, stretch: 1.02, hop: 0, tilts: [side * 4, side * 4, side * 2, 0], duration: 1.4),
                                PetParticle(symbol: "bandage.fill", color: .pink, count: 1, rise: 36), .impact(.soft, intensity: 0.4))
            case .sleepy:
                return reacting(PetMove(squash: 0.04, stretch: 1.0, hop: 0, tilts: [side * 6, side * 7, side * 4, 0], duration: 1.6),
                                nil, .impact(.soft, intensity: 0.3))
            case .content, .joyful:
                return reacting(PetMove(squash: 0.04, stretch: 1.04, hop: 0,
                                        tilts: [side * 10, side * 12, side * 5, -side * 2], duration: 1.0)
                                    .amplified(by: joy),
                                PetParticle(symbol: "sparkles", color: .yellow, count: 2, rise: 44), .impact(.light))
            }

        case .swipe(.up):
            // Lifted up: a happy pet leaps for it, in its own style.
            switch mood {
            case .sleepy:
                // A long, stretching yawn instead.
                return reacting(PetMove(squash: 0.04, stretch: 1.16, hop: 0, tilts: [-3, 3, 0, 0], duration: 1.6),
                                PetParticle(symbol: "zzz", color: .indigo, count: 1, rise: 50), .impact(.soft, intensity: 0.4))
            case .sick:
                // Tries, and does not get far.
                return reacting(PetMove(squash: 0.08, stretch: 1.04, hop: 4, tilts: [-2, 2, 0, 0], duration: 1.2),
                                PetParticle(symbol: "drop.fill", color: .teal, count: 1, rise: 30), .impact(.soft, intensity: 0.3))
            case .grumpy:
                // Refuses and stamps its feet.
                return reacting(PetMove(squash: 0.16, stretch: 1.0, hop: 0, tilts: [0, 0, 0, 0], duration: 0.5),
                                PetParticle(symbol: "cloud.bolt.fill", color: .gray, count: 1, rise: 30), .impact(.heavy, intensity: 0.7))
            case .content, .joyful:
                var leap = PetMove(squash: 0.14, stretch: 1.16, hop: 34, tilts: [0, 0, 0, 0], duration: 0.9).amplified(by: joy)
                leap.turns = petClass == .trickster
                leap.rebounds = petClass == .athlete
                leap.settles = petClass == .dreamer
                return reacting(leap, PetParticle(symbol: "star.fill", color: .yellow, count: 3, rise: 64), .impact(.medium))
            }

        case .swipe:
            // Pressed down from above: squished flat, then pops back up.
            switch mood {
            case .sleepy:
                // Takes it as a cue to lie down.
                return reacting(PetMove(squash: 0.2, stretch: 1.0, hop: 0, tilts: [2, 2, 2, 0], duration: 1.6),
                                PetParticle(symbol: "zzz", color: .indigo, count: 1, rise: 40), .impact(.soft, intensity: 0.4))
            case .sick:
                return reacting(PetMove(squash: 0.1, stretch: 1.0, hop: 0, tilts: [-2, 2, 0, 0], duration: 1.2),
                                PetParticle(symbol: "drop.fill", color: .teal, count: 1, rise: 30), .impact(.soft, intensity: 0.3))
            case .grumpy:
                // Springs back up indignant.
                return reacting(PetMove(squash: 0.24, stretch: 1.1, hop: 6, tilts: [0, -6, 6, 0], duration: 0.7),
                                PetParticle(symbol: "cloud.bolt.fill", color: .gray, count: 1, rise: 34), .impact(.rigid))
            case .content, .joyful:
                return reacting(PetMove(squash: 0.26, stretch: 1.12, hop: 8, tilts: [0, 0, -3, 0], duration: 0.8),
                                PetParticle(symbol: "sparkle", color: .yellow, count: 2, rise: 40), .impact(.soft))
            }

        case .overwhelmed:
            if mood == .grumpy {
                // Patience gone: a hard, angry shake.
                return reacting(PetMove(squash: 0.1, stretch: 1.06, hop: 6, tilts: [-16, 16, -14, 10], duration: 0.8),
                                PetParticle(symbol: "cloud.bolt.fill", color: .gray, count: 3, rise: 50), .warning)
            }
            // Too many pats at once leave the pet dizzy, reeling round and round.
            return reacting(PetMove(squash: 0.06, stretch: 1.02, hop: 0, tilts: [-14, 12, -12, 10], duration: 1.6),
                            PetParticle(symbol: "tornado", color: .purple, count: 3, rise: 46), .warning)
        }
    }

    /// How the pet welcomes its owner back when the app opens: its happiest pat move and what a pat
    /// sends up. A tired or hurt pet still stirs, just less.
    var greeting: PetReaction {
        switch mood {
        case .sick, .sleepy, .grumpy:
            return PetReaction(move: move(forPat: 0), particle: particle, haptic: tapHaptic)
        case .content, .joyful:
            // The biggest of its moves: someone it loves just walked in.
            let move = natureMoves.max { $0.hop < $1.hop } ?? move(forPat: 0)
            return reacting(move.amplified(by: mood == .joyful ? 1.4 : 1.15), particle, tapHaptic)
        }
    }

    private func reacting(_ move: PetMove, _ particle: PetParticle?, _ haptic: PetHaptic) -> PetReaction {
        PetReaction(move: move.scaled(by: tempo), particle: particle, haptic: haptic)
    }

    /// Seconds the pet puts up with being held before it has had enough. Mood sets it, and so does
    /// nature: a guardian is patient, a trickster or athlete restless.
    var holdPatience: Double {
        let base: Double = switch mood {
        case .joyful: 5
        case .content: 4
        case .grumpy: 1.6
        case .sleepy: 3
        case .sick: 3.5
        }
        let nature: Double = switch petClass {
        case .guardian?: 1.3
        case .dreamer?: 1.2
        case .trickster?, .athlete?: 0.7
        default: 1
        }
        return base * nature
    }

    /// Whether being held too long sends the pet to sleep rather than squirming free.
    var fallsAsleepWhenHeld: Bool {
        mood == .sleepy || mood == .sick || (petClass == .dreamer && mood != .grumpy)
    }

    /// How the pet holds itself while held: it nestles into the hand, or leans away from it.
    /// `lean` is -1 when held on its left, 1 on its right.
    func holdPose(asleep: Bool, lean: Double) -> PetReactionFrame {
        if asleep { return PetReactionFrame(scaleX: 1.05, scaleY: 0.9, tilt: lean * 8) }
        return switch mood {
        case .joyful, .content: PetReactionFrame(scaleX: 1.04, scaleY: 0.94, tilt: lean * 5)
        case .grumpy: PetReactionFrame(scaleX: 0.97, scaleY: 0.97, tilt: -lean * 7)
        case .sleepy: PetReactionFrame(scaleX: 1.03, scaleY: 0.93, tilt: lean * 6)
        case .sick: PetReactionFrame(scaleX: 1.02, scaleY: 0.96, tilt: lean * 3)
        }
    }

    /// What the pet gives off, and how often, while it is held: purring hearts, or grumbles.
    var purr: (particle: PetParticle?, haptic: PetHaptic, interval: Double) {
        switch mood {
        case .joyful: (PetParticle(symbol: "heart.fill", color: .pink, count: 1, rise: 50), .impact(.soft, intensity: 0.6), 0.6)
        case .content: (PetParticle(symbol: "heart.fill", color: .pink, count: 1, rise: 44), .impact(.soft, intensity: 0.5), 0.8)
        case .grumpy: (PetParticle(symbol: "cloud.fill", color: .gray, count: 1, rise: 30), .impact(.rigid, intensity: 0.4), 0.9)
        case .sleepy: (PetParticle(symbol: "zzz", color: .indigo, count: 1, rise: 40), .impact(.soft, intensity: 0.3), 1.4)
        case .sick: (PetParticle(symbol: "heart.fill", color: .pink, count: 1, rise: 34), .impact(.soft, intensity: 0.3), 1.2)
        }
    }
}

/// The ways the pet can be touched. Which one a touch was is worked out by `PetTouchReactions`.
enum PetTouch: Equatable {
    /// A quick tap.
    case tap
    /// Let go after holding the pet.
    case release
    /// Held past the pet's patience.
    case heldTooLong
    case swipe(PetSwipe)
    /// Tapped too many times too quickly.
    case overwhelmed
}

enum PetSwipe: Equatable {
    case left, right, up, down
}

/// Everything one touch sets off: how the pet moves, what floats up, and how it feels in the hand.
struct PetReaction: Equatable {
    var move: PetMove
    var particle: PetParticle?
    var haptic: PetHaptic
}

/// A haptic the pet answers a touch with.
enum PetHaptic: Equatable {
    case impact(UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat = 1)
    case warning

    func play() {
        switch self {
        case let .impact(style, intensity): Haptics.tap(style, intensity: intensity)
        case .warning: Haptics.warning()
        }
    }
}

/// One reaction to a pat, as amounts the keyframes play out.
struct PetMove: Equatable {
    /// How far the pet crouches before it moves, as a fraction of its height.
    var squash: Double
    /// How tall it stretches at the top of the move.
    var stretch: Double
    /// Points it leaves the ground.
    var hop: Double
    /// Four leans in degrees, played in turn before it rights itself.
    var tilts: [Double]
    /// Seconds from crouch to rest.
    var duration: Double
    /// Turns to face the other way mid-air and back again.
    var turns = false
    /// Lands with a second, smaller bounce.
    var rebounds = false
    /// Comes down slowly instead of dropping.
    var settles = false

    /// No move at all: what plays before the first touch.
    static let rest = PetMove(squash: 0, stretch: 1, hop: 0, tilts: [0, 0, 0, 0], duration: 0.1)

    func scaled(by tempo: Double) -> PetMove {
        var move = self
        move.duration *= tempo
        return move
    }

    func amplified(by factor: Double) -> PetMove {
        var move = self
        move.hop *= factor
        move.stretch = 1 + (stretch - 1) * factor
        move.tilts = tilts.map { $0 * factor }
        return move
    }
}

/// One frame of the pet's reaction to a touch, animated by keyframes from rest and back. Also how
/// it holds itself while held.
struct PetReactionFrame: Equatable {
    var scaleX = 1.0
    var scaleY = 1.0
    /// Points the pet rises off the ground; negative is up.
    var lift = 0.0
    /// Degrees the pet leans, pivoting at its feet.
    var tilt = 0.0
}

/// What rises from a pat: hearts for a happy pet, a sweat drop for a hurt one, and so on.
struct PetParticle: Equatable {
    let symbol: String
    let color: Color
    let count: Int
    /// Points it floats up before it is gone.
    let rise: CGFloat
}

/// The pet's resting motion: breath, sway and float, pinned at its feet. Plays whatever the pet is
/// showing, a pose or its sticker, and holds still when the system asks for reduced motion.
struct PetIdleMotion: ViewModifier {
    let profile: PetMotionProfile
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            // Breath, sway and float run at unrelated periods, so the loop never visibly repeats.
            let breath = sin(time * 2 * .pi / profile.breathPeriod)
            let sway = sin(time * 2 * .pi / (profile.breathPeriod * 1.7))
            let float = sin(time * 2 * .pi / (profile.breathPeriod * 1.3))
            content
                .scaleEffect(
                    x: 1 - breath * profile.breathDepth * 0.5,
                    y: (1 + breath * profile.breathDepth) * profile.slump,
                    anchor: .bottom
                )
                .rotationEffect(.degrees(sway * profile.swayAngle), anchor: .bottom)
                .offset(y: -(float + 1) / 2 * profile.floatHeight)
        }
    }
}

/// Plays a `PetMove` each time `trigger` changes.
struct PetReactionMotion: ViewModifier {
    let trigger: Int
    let move: PetMove

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: PetReactionFrame(), trigger: trigger) { view, frame in
            view
                .scaleEffect(x: frame.scaleX, y: frame.scaleY, anchor: .bottom)
                .rotationEffect(.degrees(frame.tilt), anchor: .bottom)
                .offset(y: frame.lift)
        } keyframes: { _ in
            let t = move.duration
            let tilts = move.tilts + Array(repeating: 0, count: max(0, 4 - move.tilts.count))
            KeyframeTrack(\.scaleY) {
                SpringKeyframe(1 - move.squash, duration: t * 0.15)
                SpringKeyframe(move.stretch, duration: t * 0.22)
                SpringKeyframe(1 - move.squash * 0.5, duration: t * 0.23)
                SpringKeyframe(1, duration: t * 0.4)
            }
            KeyframeTrack(\.scaleX) {
                SpringKeyframe(1 + move.squash, duration: t * 0.15)
                // Turning is a flip through its own width, read as the pet spinning round.
                SpringKeyframe(move.turns ? -1 : 2 - move.stretch, duration: t * 0.22)
                SpringKeyframe(move.turns ? -1 : 1 + move.squash * 0.5, duration: t * 0.23)
                SpringKeyframe(1, duration: t * 0.4)
            }
            KeyframeTrack(\.lift) {
                LinearKeyframe(0, duration: t * 0.15)
                SpringKeyframe(-move.hop, duration: t * 0.25)
                SpringKeyframe(0, duration: t * (move.settles ? 0.45 : 0.22), spring: move.settles ? .smooth : .bouncy)
                SpringKeyframe(move.rebounds ? -move.hop * 0.35 : 0, duration: t * 0.18)
                SpringKeyframe(0, duration: t * 0.2, spring: .bouncy)
            }
            KeyframeTrack(\.tilt) {
                SpringKeyframe(tilts[0], duration: t * 0.18)
                SpringKeyframe(tilts[1], duration: t * 0.2)
                SpringKeyframe(tilts[2], duration: t * 0.2)
                SpringKeyframe(tilts[3], duration: t * 0.18)
                SpringKeyframe(0, duration: t * 0.24)
            }
        }
    }
}

/// A few particles that float up from a pat and fade.
struct PetParticleBurst: View {
    struct Burst: Identifiable {
        let id = UUID()
        let location: CGPoint
        let particle: PetParticle
    }

    static let lifetime: Duration = .seconds(1.3)

    let particle: PetParticle

    /// Each particle's drift sideways, size and start, fanned out so they do not stack.
    private static let spread: [(dx: CGFloat, size: CGFloat, delay: Double)] = [
        (0, 20, 0), (-22, 14, 0.06), (24, 12, 0.12)
    ]

    @State private var risen = false

    var body: some View {
        ZStack {
            ForEach(0..<min(particle.count, Self.spread.count), id: \.self) { index in
                let slot = Self.spread[index]
                Image(systemName: particle.symbol)
                    .font(.system(size: slot.size, weight: .bold))
                    .foregroundStyle(particle.color)
                    .shadow(color: AppColors.ink.opacity(0.25), radius: 0, x: 1, y: 1)
                    .scaleEffect(risen ? 1 : 0.3)
                    .offset(x: risen ? slot.dx : 0, y: risen ? -particle.rise : 0)
                    .animation(.spring(duration: 0.9, bounce: 0.4).delay(slot.delay), value: risen)
                    // Fades on its own, slower curve: the particle is seen popping before it goes.
                    .opacity(risen ? 0 : 1)
                    .animation(.easeIn(duration: 1.1).delay(slot.delay), value: risen)
            }
        }
        .accessibilityHidden(true)
        .onAppear { risen = true }
    }
}

/// Tells the pet's touches apart and plays its reaction to each: a tap, a hold and its release, a
/// hold past its patience, a swipe each way, and too many taps at once.
///
/// One drag gesture reads them all, so they never fight over a touch: how far the finger moved and
/// how long it stayed decide which it was when it lifts. A hold is noticed while the finger is
/// still down, so the pet nestles in (or leans away) and purrs as it is held.
struct PetTouchReactions: ViewModifier {
    let profile: PetMotionProfile
    /// Replays the pet's tap reaction whenever it changes, without a haptic or particles: a new
    /// pose reads as the pet moving.
    let replayKey: String?
    /// Plays the pet's greeting each time it changes, as when its owner opens the app.
    var greetKey = 0
    /// Called on every reaction to a touch.
    let onTouch: () -> Void
    /// Called with each touch the pet reacted to, once the touch is over.
    var onReaction: (PetTouch) -> Void = { _ in }

    /// How far a finger moves before the touch is a swipe rather than a tap or a hold.
    private static let swipeDistance: CGFloat = 30
    /// How long a finger rests before the touch is a hold.
    private static let holdDelay: Duration = .milliseconds(450)
    /// Taps within this window count toward overwhelming the pet.
    private static let tapWindow: TimeInterval = 2.5
    private static let overwhelmingTaps = 6

    private enum Hold: Equatable {
        case none
        case cuddling
        /// Held past its patience and fell asleep in the hand.
        case asleep
        /// Held past its patience and squirmed free; the rest of the touch is ignored.
        case freed
    }

    @State private var trigger = 0
    @State private var move = PetMove.rest
    @State private var variant = 0
    @State private var bursts: [PetParticleBurst.Burst] = []
    @State private var hold = Hold.none
    @State private var lean = 1.0
    @State private var isTouching = false
    @State private var holdTask: Task<Void, Never>?
    @State private var recentTaps: [Date] = []
    @State private var width: CGFloat = 1

    func body(content: Content) -> some View {
        let pose = hold == .cuddling || hold == .asleep
            ? profile.holdPose(asleep: hold == .asleep, lean: lean)
            : PetReactionFrame()
        content
            .scaleEffect(x: pose.scaleX, y: pose.scaleY, anchor: .bottom)
            .rotationEffect(.degrees(pose.tilt), anchor: .bottom)
            .modifier(PetReactionMotion(trigger: trigger, move: move))
            .overlay(alignment: .topLeading) {
                ForEach(bursts) { burst in
                    PetParticleBurst(particle: burst.particle)
                        .position(burst.location)
                        .allowsHitTesting(false)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max($0, 1) }
            .onChange(of: replayKey) { old, new in
                guard old != nil, new != nil else { return }
                move = profile.reaction(to: .tap, variant: variant).move
                trigger += 1
            }
            .onChange(of: greetKey) { greet() }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isTouching {
                            isTouching = true
                            startHoldTimer(at: value.startLocation)
                        } else if hold == .none, value.translation.magnitude > Self.swipeDistance {
                            // On its way to a swipe; it is no longer a hold.
                            holdTask?.cancel()
                        }
                    }
                    .onEnded(finish)
            )
            // VoiceOver cannot swipe or hold the pet, so each touch is offered by name.
            .accessibilityAction { react(to: .tap, at: center) }
            .accessibilityAction(named: Text("Stroke")) { react(to: .swipe(.right), at: center) }
            .accessibilityAction(named: Text("Lift Up")) { react(to: .swipe(.up), at: center) }
            .accessibilityAction(named: Text("Press Down")) { react(to: .swipe(.down), at: center) }
            .onDisappear {
                holdTask?.cancel()
                isTouching = false
                hold = .none
            }
    }

    private var center: CGPoint { CGPoint(x: width / 2, y: width / 2) }

    /// Waits to see whether the finger stays, then holds the pet, purring until it is let go or
    /// runs out of patience.
    private func startHoldTimer(at location: CGPoint) {
        holdTask?.cancel()
        holdTask = Task {
            try? await Task.sleep(for: Self.holdDelay)
            guard !Task.isCancelled, isTouching else { return }
            lean = location.x < width / 2 ? -1 : 1
            withAnimation(.spring(duration: 0.4, bounce: 0.35)) { hold = .cuddling }
            onTouch()
            let purr = profile.purr
            let started = Date.now
            while !Task.isCancelled {
                purr.haptic.play()
                if let particle = purr.particle { burst(particle, at: location) }
                try? await Task.sleep(for: .seconds(purr.interval))
                guard !Task.isCancelled else { return }
                if Date.now.timeIntervalSince(started) >= profile.holdPatience { break }
            }
            guard !Task.isCancelled else { return }
            let asleep = profile.fallsAsleepWhenHeld
            withAnimation(.spring(duration: 0.5, bounce: asleep ? 0 : 0.4)) { hold = asleep ? .asleep : .freed }
            react(to: .heldTooLong, at: location)
        }
    }

    private func finish(_ value: DragGesture.Value) {
        holdTask?.cancel()
        holdTask = nil
        isTouching = false
        switch hold {
        case .cuddling, .asleep:
            withAnimation(.spring(duration: 0.4, bounce: 0.3)) { hold = .none }
            react(to: .release, at: value.startLocation)
        case .freed:
            hold = .none
        case .none:
            let translation = value.translation
            if translation.magnitude > Self.swipeDistance {
                let swipe: PetSwipe = abs(translation.width) > abs(translation.height)
                    ? (translation.width > 0 ? .right : .left)
                    : (translation.height > 0 ? .down : .up)
                react(to: .swipe(swipe), at: value.startLocation)
            } else {
                tap(at: value.startLocation)
            }
        }
    }

    /// A tap, unless it is one too many: enough taps close together overwhelm the pet.
    private func tap(at location: CGPoint) {
        let now = Date.now
        recentTaps = recentTaps.filter { now.timeIntervalSince($0) < Self.tapWindow } + [now]
        if recentTaps.count >= Self.overwhelmingTaps {
            recentTaps = []
            react(to: .overwhelmed, at: location)
        } else {
            react(to: .tap, at: location)
        }
    }

    private func react(to touch: PetTouch, at location: CGPoint) {
        let reaction = profile.reaction(to: touch, variant: variant)
        variant += 1
        move = reaction.move
        trigger += 1
        reaction.haptic.play()
        if let particle = reaction.particle { burst(particle, at: location) }
        onTouch()
        onReaction(touch)
    }

    /// Welcomes the owner back. Not a touch: nothing is reported, so the photo stays up.
    private func greet() {
        guard !isTouching else { return }
        let reaction = profile.greeting
        move = reaction.move
        trigger += 1
        reaction.haptic.play()
        if let particle = reaction.particle { burst(particle, at: CGPoint(x: width / 2, y: width / 3)) }
    }

    /// Floats particles up from a touch, and clears them once they have faded.
    private func burst(_ particle: PetParticle, at location: CGPoint) {
        let burst = PetParticleBurst.Burst(location: location, particle: particle)
        bursts.append(burst)
        Task {
            try? await Task.sleep(for: PetParticleBurst.lifetime)
            bursts.removeAll { $0.id == burst.id }
        }
    }
}

private extension CGSize {
    var magnitude: CGFloat { (width * width + height * height).squareRoot() }
}
