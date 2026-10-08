import Foundation
import SwiftUI
import SVGView

public enum ControllableEngineID: String, Codable, Sendable { case legacy, svg }
public typealias SVGControlState = [String: AnimatedControlValue]
public struct SVGPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}
public struct SVGTrack: Codable, Hashable, Sendable {
    public struct Frame: Codable, Hashable, Sendable { public var time: Double; public var value: Double }
    public var property: String
    public var duration: Double
    public var loop: Bool
    public var interpolation: String
    public var frames: [Frame]
    public func sample(_ time: Double) -> Double {
        guard duration > 0, let first = frames.first else { return 0 }
        let elapsed = max(0, time.isFinite ? time : 0)
        let t = loop ? elapsed.truncatingRemainder(dividingBy: duration) : min(elapsed, duration)
        var value = first.value
        for i in 1..<frames.count {
            let a = frames[i - 1], b = frames[i]
            if t >= b.time { value = b.value; continue }
            value = interpolation == "step" ? a.value : a.value + (b.value - a.value) * (t - a.time) / (b.time - a.time)
            break
        }
        return value
    }
}
public struct SVGAnimationGroup: Codable, Hashable, Sendable, Identifiable {
    public struct ColorRule: Codable, Hashable, Sendable { public var when: [String: [AnimatedControlValue]]; public var color: String; public init(when: [String: [AnimatedControlValue]], color: String) { self.when = when; self.color = color } }
    public var id: String
    public var markup: String
    public var pivot: SVGPoint
    public var when: [String: [AnimatedControlValue]]
    public var tracks: [SVGTrack]
    public var colors: [ColorRule]
    public var depth: Double?
}
public struct SVGGroupSample: Hashable, Sendable {
    public var id: String
    public var x = 0.0, y = 0.0, rotation = 0.0, scaleX = 1.0, scaleY = 1.0, opacity = 1.0
    public var visible = true
    public var color: String?
}
public struct SVGAnimationRig: Codable, Hashable, Sendable {
    public var version: Int
    public var width: Int
    public var height: Int
    public var defaults: SVGControlState
    public var groups: [SVGAnimationGroup]
    public var emotions: [String: String]
    public func sample(state: SVGControlState = [:], time: Double) -> [SVGGroupSample] {
        var selected = defaults.merging(state) { _, value in value }
        if state["emotion"] == nil, let expression = selected["expression"]?.string, let emotion = emotions[expression] {
            selected["emotion"] = .string(emotion)
        }
        func matches(_ when: [String: [AnimatedControlValue]]) -> Bool {
            when.allSatisfy { key, values in selected[key].map(values.contains) ?? false }
        }
        return groups.map { group in
            var s = SVGGroupSample(id: group.id)
            s.visible = matches(group.when)
            for track in group.tracks {
                let value = track.sample(time)
                switch track.property {
                case "x": s.x = value
                case "y": s.y = value
                case "rotation": s.rotation = value
                case "scaleX": s.scaleX = value
                case "scaleY": s.scaleY = value
                case "opacity": s.opacity = min(1, max(0, value))
                default: break
                }
            }
            for rule in group.colors where matches(rule.when) { s.color = rule.color }
            return s
        }
    }
    public var isValid: Bool {
        version == 1 && (16...4096).contains(width) && (16...4096).contains(height)
        && !groups.isEmpty && groups.count <= 96 && Set(groups.map(\.id)).count == groups.count
        && groups.allSatisfy { group in
            SVGMarkupValidator.accepts(group.markup)
            && (0...1).contains(group.pivot.x) && (0...1).contains(group.pivot.y)
            && group.tracks.count <= 6 && Set(group.tracks.map(\.property)).count == group.tracks.count
            && group.tracks.allSatisfy { track in
                track.duration >= 0.1 && track.duration <= 60 && !track.frames.isEmpty
                && track.frames.count <= 32 && ["linear", "step"].contains(track.interpolation)
                && ["x", "y", "rotation", "scaleX", "scaleY", "opacity"].contains(track.property)
                && track.frames.first?.time == 0
                && zip(track.frames, track.frames.dropFirst()).allSatisfy { $0.time < $1.time }
                && track.frames.allSatisfy { $0.time >= 0 && $0.time <= track.duration && (-4096...4096).contains($0.value) }
            }
            && ([group.when] + group.colors.map(\.when)).allSatisfy { condition in
                condition.allSatisfy { key, values in defaults[key] != nil && !values.isEmpty && values.count <= 16 }
            }
        }
    }
}
public struct SVGSceneDocument: Codable, Hashable, Sendable {
    public struct Effects: Codable, Hashable, Sendable {
        public struct Window: Codable, Hashable, Sendable { public var groupId: String; public var bounds: [SVGPoint] }
        public var lights: [String]; public var lightPools: [String]; public var precipitation: [String]
        public var umbrellas: [String]; public var puddles: [String]; public var windows: [Window]
    }
    public struct Fixtures: Codable, Hashable, Sendable {
        public var clock: SVGPoint?
        public var weather: SVGPoint?
        public var status: SVGPoint?
    }
    public var version: Int
    public var engine: ControllableEngineID
    public var rig: SVGAnimationRig
    public var indoor: Bool
    public var spawn: SVGPoint
    public var walkable: [SVGPoint]
    public var obstacles: [[SVGPoint]]
    public var shelters: [[SVGPoint]]
    public var fixtures: Fixtures
    public var effects: Effects?
    public var isValid: Bool {
        version == 1 && engine == .svg && rig.isValid && (3...32).contains(walkable.count)
        && obstacles.count <= 24 && shelters.count <= 12 && SVGSceneNavigation(scene: self).canStand(spawn)
        && ([walkable] + obstacles + shelters).allSatisfy { polygon in
            (3...32).contains(polygon.count) && polygon.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) }
        }
    }
}

/// Parses each immutable vector group once. State and time only change native transforms and paint.
public struct ControllableSVGFrame: View {
    private static let cache = SVGCache(capacity: 256)
    public var rig: SVGAnimationRig
    public var state: SVGControlState
    public var time: Double
    public init(rig: SVGAnimationRig, state: SVGControlState = [:], time: Double) { self.rig = rig; self.state = state; self.time = time }
    public var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / Double(rig.width), geometry.size.height / Double(rig.height))
            let samples = rig.sample(state: state, time: time)
            ZStack {
                ForEach(Array(rig.groups.enumerated()), id: \.element.id) { index, group in
                    let sample = samples[index]
                    if sample.visible, let parsed = Self.cache.document(
                        for: .inline(markup: Self.markup(group.markup, color: sample.color)), assets: EmptyAnimatedAssets()) {
                        // Keep the native tree: flattening a clipped group discards its window mask.
                        parsed.root.node.toSwiftUI()
                        .frame(width: Double(rig.width), height: Double(rig.height))
                        .scaleEffect(x: sample.scaleX, y: sample.scaleY, anchor: UnitPoint(x: group.pivot.x, y: group.pivot.y))
                        .rotationEffect(.degrees(sample.rotation), anchor: UnitPoint(x: group.pivot.x, y: group.pivot.y))
                        .offset(x: sample.x, y: sample.y)
                        .opacity(sample.opacity)
                    }
                }
            }
            .frame(width: Double(rig.width), height: Double(rig.height))
            .scaleEffect(x: (state["facing"] ?? rig.defaults["facing"])?.string == "left"
                && !rig.groups.contains(where: { $0.when["facing"] != nil })
                ? -1 : 1, y: 1)
            .scaleEffect(scale)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
    private static func markup(_ source: String, color: String?) -> String {
        // SVGView resolves clip references but does not register a clipPath element parser.
        // A group inside defs has the same geometry and stays hidden until used as a clip.
        let native = source.replacingOccurrences(of: "<clipPath", with: "<g").replacingOccurrences(of: "</clipPath>", with: "</g>")
        guard let color else { return native }
        return native.replacingOccurrences(of: #"\bfill=(["'])(?!none\1)([^"']*)\1"#,
            with: "fill=\"\(color)\"", options: .regularExpression)
    }
}
