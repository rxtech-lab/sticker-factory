import Foundation
import FoundationModels
import Observation
import os

/// Decides what the pet says and does.
///
/// Anything that changes the pet — an action, a picture it is shown — is decided by the pet's agent
/// on the server, which answers with the pet's new stats, pose and line. Small things that change
/// nothing are decided here on the phone when it has Apple Intelligence, so the pet answers at once:
/// what it says back when it is touched or greeted, its first reaction to an action or a picture
/// while its agent is still thinking, and its thanks when a walk gives it energy back. Without the
/// on-device model the pet still reacts with its body, and with a predefined line where there is one.
@MainActor
@Observable
final class PetBrain {
    /// A line the on-device model wrote for the pet, shown over its agent's line for a little while.
    struct LocalLine: Equatable {
        var id = UUID()
        var text: String
    }

    /// What the pet says right now in reply to a touch. Nil when its agent's line should show.
    private(set) var localLine: LocalLine?
    /// Counts the times the pet chose to play its animation right away; `PetAnimatedPose` plays
    /// once each time it changes.
    private(set) var playRequest = 0

    /// How often the pet plays its animation when its agent has not said.
    static let defaultAnimationInterval = 30
    /// The bounds the server holds the agent's interval to, held again here against older servers.
    static let animationIntervalRange = 8...600
    /// How long a touch reply stays up before the agent's line comes back.
    static let localLineLifetime: Duration = .seconds(8)
    /// The least time between two touch replies, so a flurry of taps is one thought, not ten.
    static let localReplyCooldown: TimeInterval = 4

    private static let log = Logger(subsystem: "app.rxlab.sticker-factory", category: "pet-brain")

    let api: any StickerAPIClientProtocol

    @ObservationIgnored private var thinking: Task<Void, Never>?
    /// Names the thought in `thinking`, so one that was replaced does not clear its successor.
    @ObservationIgnored private var thinkingID = UUID()
    @ObservationIgnored private var lineExpiry: Task<Void, Never>?
    @ObservationIgnored private var lastReplyAt: Date?
    @ObservationIgnored private let model = SystemLanguageModel.default

    init(api: any StickerAPIClientProtocol) {
        self.api = api
    }

    // MARK: Remote: the pet's agent

    /// Has the pet's agent answer `action`. Returns the pet as it is afterwards.
    func answer(_ action: PetAction) async throws -> Pet? {
        let pet = try await api.interactWithPet(action)
        forgetLocalLine()
        return pet
    }

    /// Has the pet's agent look at the picture in `jpeg`. Returns the pet as it is afterwards.
    func look(atPhoto jpeg: Data) async throws -> Pet? {
        let pet = try await api.sendPetPhoto(jpeg: jpeg)
        forgetLocalLine()
        return pet
    }

    /// How long the pet holds still between plays of its animation, as its agent chose with the pose.
    func animationInterval(for pet: Pet?) -> Duration {
        let seconds = pet?.status?.animateEverySeconds ?? Self.defaultAnimationInterval
        return .seconds(min(max(seconds, Self.animationIntervalRange.lowerBound), Self.animationIntervalRange.upperBound))
    }

    // MARK: On device

    /// Whether this phone can think for the pet: Apple Intelligence is on and speaks the user's language.
    var canThinkOnDevice: Bool {
        model.isAvailable && model.supportsLocale(.current)
    }

    /// Loads the on-device model ahead of the first touch, so the first reply is not slow.
    func prepare() {
        guard canThinkOnDevice else { return }
        LanguageModelSession(model: model).prewarm()
    }

    /// Lets the on-device model answer `touch` with a short line, and maybe play the pet's animation.
    /// Does nothing without the model, while a reply is already being thought of, or right after one.
    func react(to touch: PetTouch, pet: Pet) {
        guard canThinkOnDevice, thinking == nil else { return }
        if let lastReplyAt, Date.now.timeIntervalSince(lastReplyAt) < Self.localReplyCooldown { return }
        lastReplyAt = .now
        let instructions = Self.instructions(for: pet)
        let prompt = Self.prompt(for: touch, pet: pet)
        let model = model
        let id = UUID()
        thinkingID = id
        thinking = Task {
            defer { if thinkingID == id { thinking = nil } }
            do {
                let session = LanguageModelSession(model: model, instructions: instructions)
                let reply = try await session.respond(
                    to: prompt,
                    generating: PetTouchReply.self,
                    options: GenerationOptions(temperature: 0.9, maximumResponseTokens: 80)
                ).content
                guard !Task.isCancelled else { return }
                let line = reply.line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty { show(LocalLine(text: line)) }
                if reply.playsAnimation { playRequest &+= 1 }
            } catch {
                // Guardrails, a busy model or anything else: the pet's body has already answered.
                Self.log.error("On-device touch reply failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Lets the pet say hello when its owner opens the app, `away` after they last had it open (nil
    /// when they never have on this phone). It speaks up when it needs something, or when it has
    /// been a while; back from a quick look elsewhere, a content pet only hops.
    func greet(_ pet: Pet, awayFor away: TimeInterval?) {
        let mood = PetMood(stats: pet.stats, maxHp: pet.maxHp)
        let hasNeed = mood == .sick || mood == .sleepy || mood == .grumpy
        let wasAwhile = away.map { $0 >= Self.quietReturn } ?? true
        guard hasNeed || wasAwhile else { return }
        speak(for: pet, prompt: Self.greetingPrompt(away: away), fallback: Self.greetingLine(for: mood, away: away))
    }

    /// Has the pet thank its owner for a walk that just gave it energy (and gold) back: a hop at
    /// once, and a line of its own. `pet` is the pet after the walk was paid.
    func thank(forWalk walk: PetWalkReward, pet: Pet) {
        playRequest &+= 1
        speak(for: pet, prompt: Self.walkPrompt(walk, pet: pet), fallback: Self.walkLine(walk))
    }

    /// Has the pet react to `action` the moment it is chosen, while its agent works out what really
    /// happens. Only with the on-device model; without it the thinking bubble stands in.
    func anticipate(_ action: PetAction, pet: Pet) {
        // An older line must not pass for the reaction while the thinking bubble is up.
        forgetLocalLine()
        guard canThinkOnDevice else { return }
        speak(for: pet, prompt: Self.anticipationPrompt(for: action), fallback: nil)
    }

    /// Has the pet react to being held up a picture, before its agent has looked at it properly.
    func anticipatePhoto(pet: Pet) {
        forgetLocalLine()
        guard canThinkOnDevice else { return }
        speak(
            for: pet,
            prompt: "Your owner is holding up a picture for you to look at. You have not looked closely yet. React right away.",
            fallback: nil
        )
    }

    /// Has the pet answer `words` its owner said aloud, thought of on the phone, and waits for the
    /// answer so the thinking bubble can stay up until it lands. Without the on-device model, or when
    /// it fails, the pet answers from its mood instead: it always says something back.
    func hear(_ words: String, pet: Pet) async {
        thinking?.cancel()
        thinking = nil
        lastReplyAt = .now
        let fallback = Self.heardLine(for: PetMood(stats: pet.stats, maxHp: pet.maxHp))
        guard canThinkOnDevice else {
            show(LocalLine(text: fallback))
            return
        }
        do {
            let session = LanguageModelSession(model: model, instructions: Self.instructions(for: pet))
            let reply = try await session.respond(
                to: Self.hearingPrompt(words),
                generating: PetTouchReply.self,
                options: GenerationOptions(temperature: 0.9, maximumResponseTokens: 80)
            ).content
            let line = reply.line.trimmingCharacters(in: .whitespacesAndNewlines)
            show(LocalLine(text: line.isEmpty ? fallback : line))
            if reply.playsAnimation { playRequest &+= 1 }
        } catch {
            Self.log.error("On-device reply to speech failed: \(error.localizedDescription, privacy: .public)")
            show(LocalLine(text: fallback))
        }
    }

    static func hearingPrompt(_ words: String) -> String {
        "Your owner just said to you, out loud: \"\(words)\". Answer them in your own voice, " +
            "in the language they spoke. Take what they said to heart, but stay in character."
    }

    /// What the pet says back to its owner's words without the on-device model.
    static func heardLine(for mood: PetMood) -> String {
        switch mood {
        case .sick: String(localized: "I hear you… I'm not feeling well, though.")
        case .sleepy: String(localized: "Mm-hm… I'm listening… just so sleepy.")
        case .grumpy: String(localized: "Hmph. Fine, I'm listening.")
        case .content: String(localized: "I love it when you talk to me.")
        case .joyful: String(localized: "Ooh, tell me more! I love your voice!")
        }
    }

    /// Has the on-device model say one line for `pet` in reply to `prompt`, in place of any thought
    /// in flight. Without the model, or when it fails, says `fallback` instead when there is one.
    private func speak(for pet: Pet, prompt: String, fallback: String?) {
        thinking?.cancel()
        lastReplyAt = .now
        guard canThinkOnDevice else {
            if let fallback { show(LocalLine(text: fallback)) }
            return
        }
        let instructions = Self.instructions(for: pet)
        let model = model
        let id = UUID()
        thinkingID = id
        thinking = Task {
            defer { if thinkingID == id { thinking = nil } }
            do {
                let session = LanguageModelSession(model: model, instructions: instructions)
                let reply = try await session.respond(
                    to: prompt,
                    generating: PetTouchReply.self,
                    options: GenerationOptions(temperature: 0.9, maximumResponseTokens: 80)
                ).content
                guard !Task.isCancelled else { return }
                let line = reply.line.trimmingCharacters(in: .whitespacesAndNewlines)
                if let text = line.isEmpty ? fallback : line { show(LocalLine(text: text)) }
                if reply.playsAnimation { playRequest &+= 1 }
            } catch {
                guard !Task.isCancelled else { return }
                Self.log.error("On-device line failed: \(error.localizedDescription, privacy: .public)")
                if let fallback { show(LocalLine(text: fallback)) }
            }
        }
    }

    /// What the pet says for a walk without the on-device model.
    static func walkLine(_ walk: PetWalkReward) -> String {
        walk.energy > 0
            ? String(localized: "What a walk! I feel full of energy again.")
            : String(localized: "Thanks for the walk! I had so much fun.")
    }

    static func walkPrompt(_ walk: PetWalkReward, pet: Pet) -> String {
        var lines = ["Your owner has walked \(walk.steps) steps today and took you along."]
        if walk.energy > 0 { lines.append("The walk gave you back \(walk.energy) energy; you now have \(pet.stats.energy)/100.") }
        if walk.gold > 0 { lines.append("You also found \(walk.gold) gold on the way.") }
        lines.append("Thank them for the walk in your own way.")
        return lines.joined(separator: " ")
    }

    static func anticipationPrompt(for action: PetAction) -> String {
        "Your owner just chose to do this with you: \(action.title) — \(action.description) " +
            "It has not happened yet. React right away, as eager or as wary as you feel about it."
    }

    /// Back within this long, the owner barely left: a content pet greets them with its body only.
    static let quietReturn: TimeInterval = 5 * 60

    /// What the pet says on the owner's return without the on-device model. Nil when a hop says it all.
    static func greetingLine(for mood: PetMood, away: TimeInterval?) -> String? {
        switch mood {
        case .sick: return String(localized: "You're back… I don't feel so good. Look after me?")
        case .sleepy: return String(localized: "Oh, it's you… I'm so sleepy.")
        case .grumpy: return String(localized: "Hmph. I've been bored. Play with me?")
        case .content, .joyful:
            guard let away else { return String(localized: "Hello again! I missed you.") }
            if away >= 24 * 60 * 60 { return String(localized: "You're back! It's been ages!") }
            if away >= quietReturn { return String(localized: "Welcome back! I missed you.") }
            return nil
        }
    }

    static func greetingPrompt(away: TimeInterval?, now: Date = .now) -> String {
        var lines = ["Your owner just opened the app to see you."]
        if let away { lines.append("They were away for \(awayDescription(away)).") }
        lines.append("It is \(timeOfDay(now)) for them.")
        lines.append("Greet them. If you need something — rest, care or play — say so; otherwise just welcome them back.")
        return lines.joined(separator: " ")
    }

    static func awayDescription(_ away: TimeInterval) -> String {
        switch away {
        case ..<(60 * 60): "a few minutes"
        case ..<(3 * 60 * 60): "about an hour"
        case ..<(24 * 60 * 60): "about \(Int(away / 3600)) hours"
        case ..<(2 * 24 * 60 * 60): "about a day"
        default: "\(Int(away / 86400)) days"
        }
    }

    static func timeOfDay(_ date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "morning"
        case 12..<17: "afternoon"
        case 17..<22: "evening"
        default: "late at night"
        }
    }

    /// Puts the on-device line away, so the agent's line shows again. Called when the agent answers.
    func forgetLocalLine() {
        thinking?.cancel()
        thinking = nil
        lineExpiry?.cancel()
        lineExpiry = nil
        localLine = nil
    }

    private func show(_ line: LocalLine) {
        localLine = line
        lineExpiry?.cancel()
        lineExpiry = Task { [weak self] in
            try? await Task.sleep(for: Self.localLineLifetime)
            guard !Task.isCancelled, let self, self.localLine?.id == line.id else { return }
            self.localLine = nil
        }
    }

    // MARK: Prompts

    static func instructions(for pet: Pet) -> String {
        let mood = PetMood(stats: pet.stats, maxHp: pet.maxHp)
        var lines = [
            "You are \(pet.sticker.title), a small virtual pet living in a sticker app.",
            "You answer your owner with one short line in your own voice: at most 12 words, no emoji, no quotes.",
            "Stay in character. Never mention being an AI, a model or an app.",
            "Right now you feel \(mood.promptDescription).",
            "Happiness \(pet.stats.happiness)/100, energy \(pet.stats.energy)/100, HP \(pet.stats.hp)/\(pet.maxHp)."
        ]
        if let identity = pet.identity {
            lines.append("You are a \(identity.petClass.rawValue). Your personality: \(identity.personality).")
            if !identity.likes.isEmpty { lines.append("You like: \(identity.likes.joined(separator: ", ")).") }
            if !identity.dislikes.isEmpty { lines.append("You dislike: \(identity.dislikes.joined(separator: ", ")).") }
        }
        if let caption = pet.status?.caption(at: .now), !caption.isEmpty {
            lines.append("The last thing you said was: \(caption)")
            lines.append("Reply in the same language as that line.")
        }
        return lines.joined(separator: "\n")
    }

    static func prompt(for touch: PetTouch, pet: Pet) -> String {
        "Your owner just \(touch.promptDescription). How do you react?"
    }
}

/// What the on-device model decides when the pet is touched.
@Generable
nonisolated struct PetTouchReply {
    @Guide(description: "What the pet says back, in its own voice. One short sentence of at most 12 words.")
    var line: String
    @Guide(description: "True when the touch excites the pet enough to wiggle through its own animation right now.")
    var playsAnimation: Bool
}

extension PetMood {
    var promptDescription: String {
        switch self {
        case .sick: "unwell and fragile"
        case .sleepy: "sleepy and low on energy"
        case .grumpy: "grumpy and a bit cross"
        case .content: "calm and content"
        case .joyful: "joyful and full of beans"
        }
    }
}

extension PetTouch {
    var promptDescription: String {
        switch self {
        case .tap: "tapped you gently"
        case .release: "let go of you after a cuddle"
        case .heldTooLong: "held you for far too long"
        case .swipe(.left), .swipe(.right): "stroked you"
        case .swipe(.up): "lifted you up"
        case .swipe(.down): "pressed you down"
        case .overwhelmed: "tapped you over and over, far too quickly"
        case .shaken: "shook the phone you live in, rattling you about"
        }
    }
}
