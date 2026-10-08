import AnimatedView
import SpriteKit
import SwiftUI

@Observable
private final class PetWorldPresentation {
    var position = CGPoint(x: 0.5, y: 0.7)
}

/// SpriteKit owns world coordinates and depth; the SVG rig remains the artwork's source of truth.
private final class PetWorldScene: SKScene {
    var document: SVGSceneDocument?
    var state: SVGControlState = [:]
    var animation: PetAnimation?
    var fallback: UIImage?
    var movementPaused = false
    var reduceMotion = false
    var onPosition: (CGPoint) -> Void = { _ in }
    var onDestination: () -> Void = {}
    private var actor = SKSpriteNode()
    private var artwork: [String: SKSpriteNode] = [:]
    private var colors: [String: String] = [:]
    private var location = SVGPoint(x: 0.5, y: 0.7)
    private var route: [SVGPoint] = []
    private var previousTime: Double?
    private var clock = 0.0
    private var nextRoam = 4.0
    private var animationStarted = 0.0
    private var textures: [String: SKTexture] = [:]
    private var facingLeft = false
    private var lastReported = 0.0
    private var roamIndex = 0
    private var rasterWidth = 768.0

    func load(_ scene: SVGSceneDocument) {
        guard document != scene else { return }
        document = scene
        size = CGSize(width: scene.rig.width, height: scene.rig.height)
        scaleMode = .aspectFit
        backgroundColor = .clear
        removeAllChildren(); artwork.removeAll(); colors.removeAll(); textures.removeAll(); route.removeAll()
        location = scene.spawn
        let navigation = SVGSceneNavigation(scene: scene)
        if !navigation.canStand(location) {
            location = navigation.path(from: scene.spawn, to: scene.spawn).first ?? scene.spawn
        }
        for group in scene.rig.groups {
            let node = SKSpriteNode(texture: texture(group, in: scene.rig, color: nil))
            node.size = size
            node.anchorPoint = CGPoint(x: group.pivot.x, y: 1 - group.pivot.y)
            node.position = CGPoint(x: group.pivot.x * size.width, y: (1 - group.pivot.y) * size.height)
            node.zPosition = group.depth.map { $0 * 100 } ?? -10
            colors[group.id] = ""
            artwork[group.id] = node
            addChild(node)
        }
        actor = SKSpriteNode()
        actor.anchorPoint = CGPoint(x: 0.5, y: 0.12)
        actor.size = CGSize(width: size.width * 0.24, height: size.width * 0.24)
        addChild(actor)
        reportPosition()
    }
    func setAnimation(_ next: PetAnimation?, fallback: UIImage?) {
        if animation?.key != next?.key { textures.removeAll(); animationStarted = clock }
        animation = next; self.fallback = fallback
    }
    func setDisplayWidth(_ width: Double) {
        let next = min(2048, max(128, width.rounded()))
        guard abs(next - rasterWidth) > 16 else { return }
        rasterWidth = next
        textures.removeAll(keepingCapacity: true)
        guard let source = document else { return }
        for group in source.rig.groups {
            artwork[group.id]?.texture = texture(group, in: source.rig, color: colors[group.id].flatMap { $0.isEmpty ? nil : $0 })
        }
    }
    func explore() {
        guard !movementPaused, let document else { return }
        roamIndex += 1
        let candidates = [SVGPoint(x: 0.25, y: 0.78), .init(x: 0.75, y: 0.78), .init(x: 0.5, y: 0.65), document.spawn]
        route = SVGSceneNavigation(scene: document).path(from: location, to: candidates[roamIndex % candidates.count])
        nextRoam = clock + 12
    }
    func interrupt() { route.removeAll(); nextRoam = clock + 8 }
    func react() {
        interrupt()
        guard !reduceMotion else { return }
        actor.removeAction(forKey: "reaction")
        actor.run(.sequence([.scale(to: 1.07, duration: 0.12), .scale(to: 1, duration: 0.2)]), withKey: "reaction")
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !movementPaused, let scene = document, let touch = touches.first else { return }
        let point = touch.location(in: self)
        let target = SVGPoint(x: point.x / size.width, y: 1 - point.y / size.height)
        route = SVGSceneNavigation(scene: scene).path(from: location, to: target)
        nextRoam = clock + 10
        if !route.isEmpty { onDestination() }
    }
    override func update(_ currentTime: TimeInterval) {
        let dt = min(0.05, max(0, currentTime - (previousTime ?? currentTime)))
        previousTime = currentTime
        guard let scene = document else { return }
        if !movementPaused {
            let emotion = state["emotion"]?.string ?? "content"
            clock += dt * (emotion == "sleepy" || emotion == "sick" ? 0.65 : emotion == "joyful" ? 1.2 : 1)
        }
        if !movementPaused, !reduceMotion, route.isEmpty, clock > nextRoam {
            explore()
        }
        let moving = !movementPaused && !route.isEmpty
        if moving, let next = route.first {
            let distance = hypot(next.x - location.x, next.y - location.y)
            let mood = state["emotion"]?.string ?? "content"
            let stride = dt * (mood == "sleepy" || mood == "sick" ? 0.055 : mood == "joyful" ? 0.16 : 0.1)
            if distance <= stride { location = next; route.removeFirst() } else {
                location.x += (next.x - location.x) / distance * stride
                location.y += (next.y - location.y) / distance * stride
            }
            if abs(next.x - location.x) > 0.001 { facingLeft = next.x < location.x }
        }
        state["moving"] = .bool(moving)
        state["facing"] = .string(facingLeft ? "left" : "right")
        state["reduceMotion"] = .bool(reduceMotion)
        state["paused"] = .bool(movementPaused)
        if moving { state["pose"] = .string("walk") }
        state["sheltered"] = .bool(scene.indoor || scene.shelters.contains { SVGSceneNavigation.contains(location, polygon: $0) })
        let samples = scene.rig.sample(state: state, time: reduceMotion ? 0 : clock)
        for (i, group) in scene.rig.groups.enumerated() {
            guard let node = artwork[group.id] else { continue }
            let sample = samples[i]
            node.isHidden = !sample.visible; node.alpha = sample.opacity
            node.position = CGPoint(x: group.pivot.x * size.width + sample.x, y: (1 - group.pivot.y) * size.height - sample.y)
            node.xScale = sample.scaleX; node.yScale = sample.scaleY
            node.zRotation = -sample.rotation * .pi / 180
            if colors[group.id] != (sample.color ?? "") {
                node.texture = texture(group, in: scene.rig, color: sample.color)
                colors[group.id] = sample.color ?? ""
            }
        }
        actor.position = CGPoint(x: location.x * size.width, y: (1 - location.y) * size.height)
        actor.zPosition = location.y * 100
        actor.xScale = facingLeft ? -abs(actor.xScale) : abs(actor.xScale)
        actor.texture = petTexture(moving: moving)
        if clock - lastReported > 0.05 || movementPaused { reportPosition(); lastReported = clock }
    }
    private func reportPosition() { onPosition(CGPoint(x: location.x, y: location.y)) }
    private func texture(_ group: SVGAnimationGroup, in source: SVGAnimationRig, color: String?) -> SKTexture? {
        var rig = source
        var plain = group; plain.when = [:]; plain.tracks = []
        if let color { plain.colors = [.init(when: [:], color: color)] } else { plain.colors = [] }
        rig.groups = [plain]
        let width = rasterWidth, height = width * Double(rig.height) / Double(rig.width)
        let renderer = ImageRenderer(content: ControllableSVGFrame(rig: rig, time: 0).frame(width: width, height: height))
        return renderer.uiImage.map(SKTexture.init(image:))
    }
    private func petTexture(moving: Bool) -> SKTexture? {
        guard let animation else {
            if let cached = textures["fallback"] { return cached }
            let texture = fallback.map(SKTexture.init(image:))
            textures["fallback"] = texture
            return texture
        }
        let frame = reduceMotion ? 0 : Int((clock - animationStarted) * 12)
            % max(1, min(360, Int(ceil(animation.document.renderedCycleDuration * 12))))
        let key = "\(moving)-\(frame)"
        if let cached = textures[key] { return cached }
        var document = animation.document
        if moving {
            for index in document.layers.indices {
                if case .svg(var layer) = document.layers[index], let rig = layer.rig,
                   rig.groups.contains(where: { $0.when["pose"]?.contains(.string("walk")) == true }) {
                    layer.svgState = (layer.svgState ?? [:]).merging(["pose": .string("walk")]) { _, new in new }
                    document.layers[index] = .svg(layer)
                }
            }
        }
        let petResolution = max(64, (rasterWidth * 0.24).rounded())
        let renderer = ImageRenderer(content: AnimatedIconFrame(document: document,
            time: Double(frame) / 12, assets: animation.assets.dictionary)
            .frame(width: petResolution, height: petResolution))
        guard let image = renderer.uiImage else { return nil }
        let texture = SKTexture(image: image)
        if textures.count >= 96 { textures.removeAll(keepingCapacity: true) }
        textures[key] = texture
        return texture
    }
}

struct PetWorldStage: View {
    let model: PetModel
    let pet: Pet
    let document: SVGSceneDocument
    let paused: Bool
    let conversing: Bool
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scene = PetWorldScene()
    @State private var bubbleSize = CGSize(width: 220, height: 75)
    @State private var presentation = PetWorldPresentation()
    private var shouldReduceMotion: Bool {
        reduceMotion || (ProcessInfo.processInfo.arguments.contains("--ui-testing")
            && ProcessInfo.processInfo.arguments.contains("--reduce-motion"))
    }
    var body: some View {
        GeometryReader { geometry in
            let rasterScale = displayScale
            let aspect = Double(document.rig.width) / Double(document.rig.height)
            let width = min(geometry.size.width, geometry.size.height * aspect)
            let height = width / aspect
            let origin = CGPoint(x: (geometry.size.width - width) / 2, y: (geometry.size.height - height) / 2)
            let actor = CGPoint(x: origin.x + presentation.position.x * width, y: origin.y + presentation.position.y * height)
            let bubble = dialogueFrame(actor: actor, stage: geometry.size, origin: origin, width: width, height: height)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ZStack(alignment: .topLeading) {
                    SpriteView(scene: scene, isPaused: paused, preferredFramesPerSecond: 30, options: [.allowsTransparency])
                        .accessibilityHidden(true)
                    Color.clear.frame(width: width * 0.25, height: width * 0.25)
                        .contentShape(.rect)
                        .modifier(PetTouchReactions(profile: PetMotionProfile(pet: pet), replayKey: model.touchPose?.key ?? model.poseKey,
                            greetKey: model.greetCount, onTouch: { scene.interrupt(); if !model.isAnswering { model.dismissPhoto() } },
                            onReaction: { scene.react(); model.touched($0) }, acceptsShakes: !paused))
                        .modifier(PetItemPresentation(item: model.usedItem, isVisible: !paused))
                        .overlay(alignment: .trailing) {
                            if let photo = model.shownPhoto { PetPhotoBubble(image: photo) }
                        }
                        .overlay(alignment: .topLeading) {
                            if pet.evolution?.isGrowing == true { PetGrowingBadge() }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(pet.sticker.title)
                        .accessibilityIdentifier("current-pet")
                        .accessibilityAction(named: "Explore") { scene.explore() }
                        .position(x: actor.x, y: actor.y - width * 0.09)
                    Group {
                        if model.isAnswering {
                            PetThinkingBubble(reaction: model.brain.localLine?.text, placement: bubble.midY < actor.y ? .above : .below)
                        } else {
                            PetSpeechBubble(text: model.brain.localLine?.text ?? pet.status?.caption(at: context.date)
                                ?? String(localized: "I'm here with you. What shall we do?"),
                                placement: bubble.midY < actor.y ? .above : .below)
                        }
                    }
                    .frame(width: min(220, width * 0.8))
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { bubbleSize = $0 }
                    .position(x: bubble.midX, y: bubble.midY)
                    .accessibilityIdentifier("pet-dialogue")
                    .allowsHitTesting(false)
                    fixtureText(at: document.fixtures.clock, text: context.date.formatted(date: .omitted, time: .shortened),
                        origin: origin, width: width, height: height)
                    fixtureText(at: document.fixtures.weather, text: pet.signals?.weather.map { "\(Int($0.temperatureC))°" } ?? "",
                        origin: origin, width: width, height: height)
                    fixtureText(at: document.fixtures.status,
                        text: "♥ \(pet.stats.hp)/\(pet.maxHp)  ☺ \(pet.stats.happiness)  ⚡ \(pet.stats.energy)",
                        origin: origin, width: width, height: height)
                }
                .onGeometryChange(for: Double.self) { $0.size.width * rasterScale } action: { scene.setDisplayWidth($0) }
                .onChange(of: worldState(at: context.date), initial: true) { _, state in scene.state = state }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pet-svg-world")
        .task(id: document) {
            scene.onPosition = { presentation.position = $0 }
            scene.onDestination = { Haptics.tap(.light) }
            scene.load(document)
            scene.setAnimation(model.touchPose ?? model.animation, fallback: model.pose)
        }
        .onChange(of: model.touchPose?.key ?? model.animation?.key) { _, _ in
            scene.setAnimation(model.touchPose ?? model.animation, fallback: model.pose)
        }
        .onChange(of: paused, initial: true) { _, value in scene.movementPaused = value || conversing; if value { scene.interrupt() } }
        .onChange(of: conversing, initial: true) { _, value in scene.movementPaused = value || paused; if value { scene.interrupt() } }
        .onChange(of: shouldReduceMotion, initial: true) { _, value in scene.reduceMotion = value; if value { scene.interrupt() } }
        .onDisappear { scene.isPaused = true; scene.interrupt() }
        .onAppear { scene.isPaused = false }
    }
    private func dialogueFrame(actor: CGPoint, stage: CGSize, origin: CGPoint, width: Double, height: Double) -> CGRect {
        let size = CGSize(width: min(220, width * 0.8), height: bubbleSize.height)
        let petRect = CGRect(x: actor.x - width * 0.12, y: actor.y - width * 0.23, width: width * 0.24, height: width * 0.24)
        let fixtures = [document.fixtures.clock, document.fixtures.weather, document.fixtures.status].compactMap { $0 }.map {
            CGRect(x: origin.x + $0.x * width - width * 0.06, y: origin.y + $0.y * height - height * 0.05,
                width: width * 0.12, height: height * 0.1)
        }
        let candidates = [CGPoint(x: actor.x, y: petRect.minY - size.height / 2 - 8),
                          CGPoint(x: actor.x, y: actor.y + size.height / 2 + 12),
                          CGPoint(x: petRect.minX - size.width / 2 - 8, y: petRect.midY),
                          CGPoint(x: petRect.maxX + size.width / 2 + 8, y: petRect.midY)]
        let frames = candidates.map { center in
            CGRect(x: min(max(4, center.x - size.width / 2), max(4, stage.width - size.width - 4)),
                   y: min(max(4, center.y - size.height / 2), max(4, stage.height - size.height - 4)),
                   width: size.width, height: size.height)
        }
        func score(_ frame: CGRect) -> Double {
            (fixtures + [petRect]).reduce(0) { sum, obstacle in
                let intersection = frame.intersection(obstacle.insetBy(dx: -6, dy: -6))
                return sum + (intersection.isNull ? 0 : intersection.width * intersection.height)
            }
        }
        return frames.min { score($0) < score($1) } ?? .zero
    }
    private func fixtureText(at point: SVGPoint?, text: String, origin: CGPoint, width: Double, height: Double) -> some View {
        Group {
            if let point {
                Text(text).font(.system(size: max(8, width * 0.027), weight: .semibold)).foregroundStyle(.primary)
                    .padding(3).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3))
                    .position(x: origin.x + point.x * width, y: origin.y + point.y * height)
                    .allowsHitTesting(false)
            }
        }
    }
    private func worldState(at date: Date) -> SVGControlState {
        let weather = pet.signals?.weather
        let mood = String(describing: PetMood(stats: pet.stats, maxHp: pet.maxHp))
        var emotion = mood
        var pose = "idle"
        for layer in (model.touchPose ?? model.animation)?.document.layers ?? [] {
            if case .svg(let svg) = layer, let expression = svg.svgState?["expression"]?.string,
               let mapped = svg.rig?.emotions[expression] { emotion = mapped; pose = svg.svgState?["pose"]?.string ?? "idle"; break }
        }
        return ["emotion": .string(emotion), "pose": .string(pose), "weather": .string(weather?.kind.rawValue ?? "sunny"),
                "night": .bool(!(weather?.isDay ?? PetSkyOrbit.isDay(at: date)))]
    }
}
