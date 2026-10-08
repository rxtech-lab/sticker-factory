import Foundation

public struct ControllableFrame: Sendable {
    public let document: AnimatedDocument
    public let time: Double
}
/// All controllable players share configuration resolution, timeline mapping and reset semantics.
public protocol ControllableEngine {
    var id: ControllableEngineID { get }
    mutating func prepare(_ document: AnimatedDocument)
    mutating func apply(_ values: [String: AnimatedControlValue]) throws
    mutating func sample(at time: Double, paused: Bool) -> ControllableFrame?
    mutating func reset() throws
}
public struct LegacyControllableEngine: ControllableEngine {
    public let id: ControllableEngineID = .legacy
    private var source: AnimatedDocument?
    private var resolved: AnimatedDocument?
    private var sampledTime = 0.0
    public init() {}
    public mutating func prepare(_ document: AnimatedDocument) { source = document; resolved = document; sampledTime = 0 }
    public mutating func apply(_ values: [String: AnimatedControlValue]) throws { resolved = try source?.resolvingEngineConfiguration(values) }
    public mutating func sample(at time: Double, paused: Bool = false) -> ControllableFrame? {
        if !paused { sampledTime = max(0, time.isFinite ? time : 0) }
        return resolved.map { ControllableFrame(document: $0, time: sampledTime) }
    }
    public mutating func reset() throws { sampledTime = 0; try apply([:]) }
    @MainActor
    static func spriteFrame(_ layer: AnimatedSpriteLayer, atDocumentTime time: Double, assets: any AnimatedAssetProvider) -> PlatformImage? {
        let index = AnimationInterpolator.spriteFrameIndex(layer.currentClip.frames, atDocumentTime: time)
        return SpriteFrameCache.shared.frame(for: layer, index: index, assets: assets)
    }
}
public struct SVGControllableEngine: ControllableEngine {
    public let id: ControllableEngineID = .svg
    private var playback = LegacyControllableEngine()
    public init() {}
    public mutating func prepare(_ document: AnimatedDocument) {
        artworkControls = [:]
        declaredControls = Set(document.configuration?.controls.map(\.id) ?? [])
        playback.prepare(document)
    }
    private var artworkControls: SVGControlState = [:]
    private var declaredControls: Set<String> = []
    public mutating func apply(_ values: [String: AnimatedControlValue]) throws {
        try playback.apply(values)
        artworkControls = values.filter { ["pose", "expression", "facing"].contains($0.key) && !declaredControls.contains($0.key) }
    }
    public mutating func sample(at time: Double, paused: Bool = false) -> ControllableFrame? {
        guard let frame = playback.sample(at: time, paused: paused) else { return nil }
        var document = frame.document
        for index in document.layers.indices {
            if case .svg(var layer) = document.layers[index], layer.rig != nil {
                // Existing control IDs are resolved first. Direct engine controls only fill unbound axes.
                var selected = layer.svgState ?? [:]
                for (key, value) in artworkControls {
                    if key == "facing" || layer.rig?.defaults[key] == value
                        || layer.rig?.groups.contains(where: { $0.when[key]?.contains(value) == true }) == true {
                        selected[key] = value
                    }
                }
                layer.svgState = selected
                document.layers[index] = .svg(layer)
            }
        }
        return ControllableFrame(document: document, time: frame.time)
    }
    public mutating func reset() throws { artworkControls = [:]; try playback.reset() }
}
public extension AnimatedDocument {
    func resolvingConfiguration(_ selected: [String: AnimatedControlValue] = [:]) throws -> Self {
        var engine: any ControllableEngine = layers.contains { if case .svg(let layer) = $0 { layer.rig != nil } else { false } }
            ? SVGControllableEngine() : LegacyControllableEngine()
        engine.prepare(self)
        try engine.apply(selected)
        return engine.sample(at: 0, paused: false)?.document ?? self
    }
}
