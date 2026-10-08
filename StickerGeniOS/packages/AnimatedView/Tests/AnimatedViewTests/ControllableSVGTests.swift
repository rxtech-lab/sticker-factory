import Foundation
import Testing
import SwiftUI
@testable import AnimatedView

struct ControllableSVGTests {
    struct Fixture: Decodable {
        struct Case: Decodable {
            var time: Double
            var state: SVGControlState
            var x: Double
            var lamp: Bool
            var umbrella: Bool
            var face: Bool
            var channels: [String: Double]
        }
        var rig: SVGAnimationRig
        var cases: [Case]
    }
    func fixture() throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: "controllable-svg-parity", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
    @Test func sharedTimingAndWeatherStates() throws {
        let fixture = try fixture()
        #expect(fixture.rig.isValid)
        for test in fixture.cases {
            let groups = fixture.rig.sample(state: test.state, time: test.time)
            #expect(groups[0].x == test.x)
            #expect(groups[0].y == test.channels["y"])
            #expect(groups[0].rotation == test.channels["rotation"])
            #expect(groups[0].scaleX == test.channels["scaleX"])
            #expect(groups[0].scaleY == test.channels["scaleY"])
            #expect(groups[0].opacity == test.channels["opacity"])
            #expect(groups.first { $0.id == "lamp" }?.visible == test.lamp)
            #expect(groups.first { $0.id == "umbrella" }?.visible == test.umbrella)
            #expect(groups.first { $0.id == "face" }?.visible == test.face)
        }
    }
    @Test func navigationRoutesAroundFurniture() throws {
        let rig = try fixture().rig
        let square = [SVGPoint(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)]
        let obstacle = [SVGPoint(x: 0.4, y: 0.3), .init(x: 0.6, y: 0.3), .init(x: 0.6, y: 0.8), .init(x: 0.4, y: 0.8)]
        let scene = SVGSceneDocument(version: 1, engine: .svg, rig: rig, indoor: false,
            spawn: .init(x: 0.2, y: 0.5), walkable: square, obstacles: [obstacle], shelters: [], fixtures: .init())
        let navigation = SVGSceneNavigation(scene: scene)
        let path = navigation.path(from: scene.spawn, to: .init(x: 0.8, y: 0.5))
        #expect(!path.isEmpty)
        #expect(path.allSatisfy(navigation.canStand))
        #expect(!navigation.canStand(.init(x: 0.5, y: 0.5)))
    }
    @Test func enginesResetConfiguration() throws {
        var engine = LegacyControllableEngine()
        let document = AnimatedDocument(kind: .animated, layers: [])
        engine.prepare(document)
        try engine.apply([:])
        #expect(engine.sample(at: 1, paused: false)?.time == 1)
        #expect(engine.sample(at: 5, paused: true)?.time == 1)
        try engine.reset()
        #expect(engine.sample(at: 1, paused: true)?.time == 0)
    }
    @Test func svgControlsKeepPoseExpressionSpeedAndPause() throws {
        var rig = try fixture().rig
        rig.groups[0].when = ["pose": [.string("idle"), .string("walk")]]
        var layer = AnimatedSVGLayer(base: .init(id: "pet", name: "Pet"), source: .inline(markup: rig.groups[0].markup))
        layer.rig = rig
        layer.posterAssetId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let configuration = AnimatedControlConfiguration(controls: [
            .init(id: "mood", label: "Mood", type: .choice, defaultValue: .string("calm"),
                options: [.init(id: "calm", label: "Calm"), .init(id: "happy", label: "Happy")]),
            .init(id: "pose", label: "Pose", type: .choice, defaultValue: .string("idle"),
                options: [.init(id: "idle", label: "Idle"), .init(id: "walk", label: "Walk")]),
            .init(id: "speed", label: "Speed", type: .number, defaultValue: .number(1),
                binding: "speed", minimum: 0.25, maximum: 2, step: 0.25)
        ], variants: [
            .init(id: "calm", selections: ["mood": "calm"], layers: [.init(layerId: "pet", expression: "calm")]),
            .init(id: "happy", selections: ["mood": "happy"], layers: [.init(layerId: "pet", expression: "happy")]),
            .init(id: "idle", selections: ["pose": "idle"], layers: [.init(layerId: "pet", clip: "idle")]),
            .init(id: "walk", selections: ["pose": "walk"], layers: [.init(layerId: "pet", clip: "walk")])
        ])
        var engine = SVGControllableEngine()
        engine.prepare(.init(kind: .animated, layers: [.svg(layer)], configuration: configuration))
        try engine.apply(["mood": .string("happy"), "pose": .string("walk"), "speed": .number(2), "facing": .string("left")])
        let sampled = engine.sample(at: 0.25)
        let frame = try #require(sampled)
        guard case .svg(let selected) = frame.document.layers[0] else { Issue.record("Missing SVG layer"); return }
        #expect(selected.svgState == ["expression": .string("happy"), "pose": .string("walk"), "facing": .string("left")])
        #expect(frame.document.speed == 2)
        #expect(rig.sample(state: selected.svgState ?? [:],
            time: AnimationInterpolator.mappedTime(frame.time, document: frame.document))[0].x == 5)
        #expect(engine.sample(at: 10, paused: true)?.time == 0.25)
        try engine.reset()
        let resetSample = engine.sample(at: 10, paused: true)
        let reset = try #require(resetSample)
        #expect(reset.time == 0)
        #expect(reset.document.speed == 1)
    }
    @Test func unreachableDestinationsAndSweptClearance() throws {
        let url = try #require(Bundle.module.url(forResource: "controllable-scene", withExtension: "json", subdirectory: "Fixtures"))
        var scene = try JSONDecoder().decode(SVGSceneDocument.self, from: Data(contentsOf: url))
        #expect(scene.isValid)
        scene.spawn = .init(x: 0.2, y: 0.7)
        scene.obstacles = [[.init(x: 0.45, y: 0), .init(x: 0.55, y: 0), .init(x: 0.55, y: 1), .init(x: 0.45, y: 1)]]
        let navigation = SVGSceneNavigation(scene: scene)
        #expect(navigation.path(from: scene.spawn, to: .init(x: 0.8, y: 0.7)).isEmpty)
        #expect(!navigation.canTravel(from: scene.spawn, to: .init(x: 0.8, y: 0.7)))
        #expect(!navigation.canStand(.init(x: 0.43, y: 0.7)))
        // This narrow obstacle falls between the old nine footprint samples.
        scene.obstacles = [[.init(x: 0.209, y: 0), .init(x: 0.21, y: 0), .init(x: 0.21, y: 1), .init(x: 0.209, y: 1)]]
        let thinFurniture = SVGSceneNavigation(scene: scene)
        #expect(!thinFurniture.canStand(scene.spawn))
        #expect(!thinFurniture.canTravel(from: .init(x: 0.1, y: 0.7), to: .init(x: 0.8, y: 0.7)))
    }
    @Test @MainActor func nativeFrameKeepsWindowClipping() throws {
        let url = try #require(Bundle.module.url(forResource: "controllable-scene", withExtension: "json", subdirectory: "Fixtures"))
        var rig = try JSONDecoder().decode(SVGSceneDocument.self, from: Data(contentsOf: url)).rig
        rig.groups = rig.groups.filter { $0.id == "weather" }
        let renderer = ImageRenderer(content: ControllableSVGFrame(rig: rig, state: ["weather": .string("rainy")], time: 0)
            .frame(width: 200, height: 200))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 200 * 200 * 4)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 0)
        let context = try #require(CGContext(data: buffer.baseAddress, width: 200, height: 200,
            bitsPerComponent: 8, bytesPerRow: 800,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 200, height: 200))
        let visible = stride(from: 3, to: buffer.count, by: 4).filter { buffer[$0] > 128 }.count
        #expect((1500...1700).contains(visible))
    }
    @Test func rejectsUnsafeVectorsAndMissingReferences() {
        for markup in ["<svg><script/></svg>", "<svg onload=\"run()\"/>",
            "<svg><image href=\"https://example.com\"/></svg>", "<svg fill=\"url(#missing)\"/>"] {
            #expect(!SVGMarkupValidator.accepts(markup))
        }
    }
}
