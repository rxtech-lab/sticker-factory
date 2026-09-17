import Foundation

public enum AnimatedControlValue: Codable, Hashable, Sendable {
    case string(String), number(Double), bool(Bool)
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? c.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try c.decode(String.self))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        }
    }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var number: Double? { if case .number(let v) = self { v } else { nil } }
    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
}

public struct AnimatedControlOption: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public init(id: String, label: String) { self.id = id; self.label = label }
}

public struct AnimatedControl: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case choice, number, toggle }
    public var id: String
    public var label: String
    public var type: Kind
    public var defaultValue: AnimatedControlValue
    public var options: [AnimatedControlOption]?
    public var binding: String?
    public var minimum: Double?
    public var maximum: Double?
    public var step: Double?
    public var layerIds: [String]?
    public init(id: String, label: String, type: Kind, defaultValue: AnimatedControlValue,
                options: [AnimatedControlOption]? = nil, binding: String? = nil, minimum: Double? = nil,
                maximum: Double? = nil, step: Double? = nil, layerIds: [String]? = nil) {
        self.id = id; self.label = label; self.type = type; self.defaultValue = defaultValue
        self.options = options; self.binding = binding; self.minimum = minimum; self.maximum = maximum
        self.step = step; self.layerIds = layerIds
    }
    public func normalized(_ value: AnimatedControlValue?) -> AnimatedControlValue {
        switch type {
        case .choice:
            if let text = value?.string, options?.contains(where: { $0.id == text }) == true { return .string(text) }
        case .toggle:
            if let flag = value?.bool { return .bool(flag) }
        case .number:
            if let number = value?.number, number.isFinite {
                return .number(min(maximum ?? 2, max(minimum ?? 0.25, number)))
            }
        }
        return defaultValue
    }
}

/// The plan and document share control identity; only a plan may carry generation instructions.
public struct AnimatedVariantSource: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case base, image, sequence, generate, existing, frames }
    public var kind: Kind
    public var assetId: String?
    public var prompt: String?
    public var columns: Int?
    public var rows: Int?
    public var frameCount: Int?
    public var frameRate: Double?
    public var playback: AnimatedSequencePlayback?
    public var posterAssetId: String?
    public init(kind: Kind, assetId: String? = nil, prompt: String? = nil, columns: Int? = nil, rows: Int? = nil,
                frameCount: Int? = nil, frameRate: Double? = nil, playback: AnimatedSequencePlayback? = nil, posterAssetId: String? = nil) {
        self.kind = kind; self.assetId = assetId; self.prompt = prompt; self.columns = columns; self.rows = rows
        self.frameCount = frameCount; self.frameRate = frameRate; self.playback = playback; self.posterAssetId = posterAssetId
    }
    func applying(to layer: AnimatedLayer) throws -> AnimatedLayer {
        if kind == .base { return layer }
        guard let assetId, UUID(uuidString: assetId) != nil else { throw AnimatedConfigurationError.invalid("Missing variant artwork") }
        switch kind {
        case .image: return .image(.init(base: layer.base, assetId: assetId))
        case .sequence:
            guard let columns, let rows, let frameCount, let frameRate, let playback else {
                throw AnimatedConfigurationError.invalid("Incomplete frame sequence")
            }
            return .sequence(.init(base: layer.base, assetId: assetId, columns: columns, rows: rows,
                                   frameCount: frameCount, frameRate: frameRate, playback: playback, posterAssetId: posterAssetId))
        default: throw AnimatedConfigurationError.invalid("Generate the planned artwork before playback")
        }
    }
}

public struct AnimatedVariantLayer: Codable, Hashable, Sendable {
    public var layerId: String
    public var source: AnimatedVariantSource?
    public var animations: [AnimationSpec]?
    public var anchor: AnimatedAnchor?
    /// For a sprite layer: which body clip plays. A pose control binds this.
    public var clip: String?
    /// For a sprite layer: which face is drawn into every frame's slot. A mood control binds this.
    public var expression: String?
    public var text: String?
    public var hidden: Bool?
    public init(layerId: String, source: AnimatedVariantSource? = nil, animations: [AnimationSpec]? = nil, anchor: AnimatedAnchor? = nil, clip: String? = nil, expression: String? = nil, text: String? = nil, hidden: Bool? = nil) {
        self.layerId = layerId
        self.source = source
        self.animations = animations
        self.anchor = anchor
        self.clip = clip
        self.expression = expression
        self.text = text
        self.hidden = hidden
    }
}

public struct AnimatedVariant: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var selections: [String: String]
    public var layers: [AnimatedVariantLayer]
    public var layerOrder: [String]?
    public init(id: String, selections: [String: String], layers: [AnimatedVariantLayer], layerOrder: [String]? = nil) {
        self.id = id; self.selections = selections; self.layers = layers; self.layerOrder = layerOrder
    }
}

/// Throws `AnimatedConfigurationError.invalid` when a configuration check fails.
///
/// File-scoped so `validated` and the helper it delegates to raise identical errors.
private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw AnimatedConfigurationError.invalid(message) }
}

public struct AnimatedControlConfiguration: Codable, Hashable, Sendable {
    public var controls: [AnimatedControl]
    public var variants: [AnimatedVariant]
    public init(controls: [AnimatedControl], variants: [AnimatedVariant] = []) { self.controls = controls; self.variants = variants }
    public func normalizedValues(_ values: [String: AnimatedControlValue] = [:]) -> [String: AnimatedControlValue] {
        Dictionary(controls.map { ($0.id, $0.normalized(values[$0.id])) }, uniquingKeysWith: { _, new in new })
    }
    /// Every pairing of every choice, which is what the plan card quotes to the user. Preparing a
    /// cast is priced on ``preparedStateCount``; this is the far larger number it buys them.
    ///
    /// Saturates rather than caps. How many combinations are *allowed* is the server's to say — see
    /// `GET /api/v1/configuration-limits` — so the only thing guarded here is the arithmetic.
    public var combinationCount: Int {
        controls.reduce(1) { count, control in
            guard control.type == .choice else { return count }
            let (product, overflowed) = count.multipliedReportingOverflow(by: control.options?.count ?? 0)
            return overflowed ? .max : product
        }
    }
    private static func product(_ controls: [AnimatedControl]) -> [[String: AnimatedControlValue]] {
        controls.reduce([[:]]) { states, control in
            guard control.type == .choice else { return states }
            return states.flatMap { state in (control.options ?? []).map { option in
                var next = state; next[control.id] = .string(option.id); return next
            } }
        }
    }
    public var choiceSelections: [[String: AnimatedControlValue]] {
        guard combinationCount < .max else { return [] }
        return Self.product(controls)
    }

    /// Which layers a control acts on. A choice control declares nothing about layers of its own;
    /// the variants that select it are the only record of what it changes. A toggle names its
    /// layers outright, and a speed control belongs to the document rather than to any one layer.
    public func layerIDs(for control: AnimatedControl) -> Set<String> {
        switch control.type {
        case .toggle: Set(control.layerIds ?? [])
        case .number: []
        case .choice: Set(variants.flatMap { variant in
            variant.selections[control.id] == nil ? [] : variant.layers.map(\.layerId)
        })
        }
    }
    /// The choice controls acting on each configurable layer, in the order the controls are declared.
    private var choicesByLayer: [(layerID: String, controls: [AnimatedControl])] {
        var order: [String] = []
        var byLayer: [String: [AnimatedControl]] = [:]
        for control in controls where control.type == .choice {
            for layerID in layerIDs(for: control).sorted() {
                if byLayer[layerID] == nil { order.append(layerID) }
                byLayer[layerID, default: []].append(control)
            }
        }
        return order.map { ($0, byLayer[$0] ?? []) }
    }
    /// How many states each configurable layer can be prepared in. Only controls acting on the same
    /// layer multiply, which is exactly a sprite's pose and mood.
    public var layerCombinationCounts: [String: Int] {
        Dictionary(uniqueKeysWithValues: choicesByLayer.map { layerID, controls in
            (layerID, controls.reduce(1) { $0 * ($1.options?.count ?? 0) })
        })
    }
    /// Every layer's states added up — what the whole-sticker budget is spent on.
    public var preparedStateCount: Int { layerCombinationCounts.values.reduce(0, +) }
    /// The smallest set of selections that still reaches every state any one layer can be in.
    ///
    /// One character's pose cannot change how another resolves, so states add rather than multiply:
    /// two characters at six states each are twelve to prepare, not thirty-six.
    public var coverageSelections: [[String: AnimatedControlValue]] {
        let perLayer = choicesByLayer.flatMap { Self.product($0.controls) }
        var seen = Set<String>()
        return (perLayer.isEmpty ? [[:]] : perLayer).filter { values in
            seen.insert(values.keys.sorted().map { "\($0)=\(values[$0]?.string ?? "")" }.joined(separator: "|")).inserted
        }
    }
    /// A control and the single layer it acts on, or `nil` for one that belongs to the whole
    /// document: speed, and a visibility toggle covering more than one layer.
    public struct ControlGroup: Hashable, Sendable {
        public let layerID: String?
        public let controls: [AnimatedControl]
    }

    /// The controls bucketed by the character they pose, in the order the controls are declared.
    ///
    /// Grouping is derived rather than declared: a choice control carries no layer of its own, and
    /// the variants that select it are the only record of what it changes. Only a layer something
    /// chooses *between* is a character — a visibility toggle over an accessory is a setting, not a
    /// cast member, and giving it a heading of its own would split a one-character sheet in two.
    /// The document-wide bucket comes last, so a sheet reads as the cast and then the sticker.
    public var controlGroups: [ControlGroup] {
        let posed = Set(controls.filter { $0.type == .choice }.flatMap(layerIDs(for:)))
        var order: [String] = []
        var grouped: [String: [AnimatedControl]] = [:]
        var ungrouped: [AnimatedControl] = []
        for control in controls {
            let layers = layerIDs(for: control)
            guard layers.count == 1, let layerID = layers.first, posed.contains(layerID) else {
                ungrouped.append(control); continue
            }
            if grouped[layerID] == nil { order.append(layerID) }
            grouped[layerID, default: []].append(control)
        }
        let characters = order.map { ControlGroup(layerID: $0, controls: grouped[$0] ?? []) }
        return characters + (ungrouped.isEmpty ? [] : [ControlGroup(layerID: nil, controls: ungrouped)])
    }

    public func keepingLayers(_ ids: Set<String>) -> Self? {
        var result = self
        result.variants = variants.compactMap { variant in
            var next = variant
            next.layers = variant.layers.filter { ids.contains($0.layerId) }
            next.layerOrder = variant.layerOrder?.filter { ids.contains($0) }
            return next.layers.isEmpty ? nil : next
        }
        let axes = Set(result.variants.flatMap { $0.selections.keys })
        result.controls = controls.compactMap { control in
            if control.type == .choice { return axes.contains(control.id) ? control : nil }
            guard control.type == .toggle else { return control }
            var next = control; next.layerIds = control.layerIds?.filter { ids.contains($0) }
            return next.layerIds?.isEmpty == false ? next : nil
        }
        return result.controls.isEmpty ? nil : result
    }

    public func validated(layerIds: Set<String>, planned: Bool = false) throws {
        func validID(_ id: String) -> Bool { id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil }
        // Shape only, never size. How many controls, options, variants or prepared states a
        // configuration may have is the server's to decide and the server's to refuse; a document
        // that reached this device was already accepted there, and a plan on its way out is checked
        // against `GET /api/v1/configuration-limits` by the editor that composed it.
        try require(!controls.isEmpty, "A configuration needs at least one control")
        try require(Set(controls.map(\.id)).count == controls.count, "Control ids must be unique")
        try require(Set(variants.map(\.id)).count == variants.count, "Variant ids must be unique")
        var properties: [String: String] = [:]
        func claim(_ property: String, _ family: String) throws {
            try require(properties[property] == nil || properties[property] == family, "Conflicting controls for \(property)")
            properties[property] = family
        }
        for control in controls {
            let named = !control.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            try require(validID(control.id) && named && control.label.count <= 80, "Invalid control name")
            switch control.type {
            case .choice:
                let options = control.options ?? []
                let uniqueOptions = Set(options.map(\.id)).count == options.count
                try require(uniqueOptions, "Each choice needs unique options")
                try require(options.allSatisfy { validID($0.id) && !$0.label.isEmpty && $0.label.count <= 80 }, "Invalid option name")
                try require(options.contains { $0.id == control.defaultValue.string }, "Default option is missing")
            case .number:
                guard let low = control.minimum, let high = control.maximum,
                      let step = control.step, let value = control.defaultValue.number else {
                    throw AnimatedConfigurationError.invalid("Incomplete numeric control")
                }
                let bounded = low >= 0.25 && high <= 2 && low < high && step >= 0.01 && step <= 1
                let detail = "\(control.binding ?? "missing"), \(low)...\(high), step \(step), default \(value)"
                try require(
                    control.binding == "speed" && bounded && value >= low && value <= high,
                    "Invalid speed control: \(detail)"
                )
                try claim("document.speed", control.id)
            case .toggle:
                let ids = control.layerIds ?? []
                let uniqueLayers = Set(ids).count == ids.count
                let sized = !ids.isEmpty && uniqueLayers
                try require(control.defaultValue.bool != nil && sized, "Invalid visibility control")
                for id in ids {
                    try require(layerIds.contains(id), "Missing configurable layer \(id)")
                    try claim("\(id).hidden", control.id)
                }
            }
        }
        var families: [String: (expected: Int, keys: Set<String>, targets: Set<String>)] = [:]
        var used = Set<String>()
        for variant in variants {
            let axes = variant.selections.keys.sorted()
            try require(validID(variant.id) && !axes.isEmpty && !variant.layers.isEmpty, "Invalid variant")
            var expected = 1
            for axis in axes {
                guard let control = controls.first(where: { $0.id == axis }), control.type == .choice,
                      control.options?.contains(where: { $0.id == variant.selections[axis] }) == true else {
                    throw AnimatedConfigurationError.invalid("Variant refers to an unknown choice")
                }
                used.insert(axis); expected *= control.options?.count ?? 0
            }
            let family = axes.joined(separator: "|")
            let targets = try variantTargets(for: variant.layers, layerIds: layerIds, planned: planned)
                .union(try variantOrderTargets(variant.layerOrder, layerIds: layerIds))
            for target in targets { try claim(target, "choices:\(family)") }
            var entry = families[family] ?? (expected, [], targets)
            try require(entry.targets == targets, "Every option must bind the same properties")
            let key = axes.map { variant.selections[$0] ?? "" }.joined(separator: "|")
            try require(entry.keys.insert(key).inserted, "Duplicate variant selection")
            families[family] = entry
        }
        for (_, entry) in families { try require(entry.keys.count == entry.expected, "Some choice combinations have no artwork") }
        try require(controls.filter { $0.type == .choice }.allSatisfy { used.contains($0.id) }, "A choice has no variants")
    }

    /// Checks one variant's layer patches and returns the properties they bind.
    ///
    /// Split out of `validated` so neither half runs long: this is the per-patch shape check,
    /// and the set it returns is what the caller compares across a family's variants.
    private func variantTargets(
        for layers: [AnimatedVariantLayer],
        layerIds: Set<String>,
        planned: Bool
    ) throws -> Set<String> {
        var targets = Set<String>()
        for patch in layers {
            try require(layerIds.contains(patch.layerId), "Missing configurable layer \(patch.layerId)")
            let bound = patch.source != nil || patch.animations != nil || patch.anchor != nil || patch.clip != nil
                || patch.expression != nil || patch.text != nil || patch.hidden != nil
            try require(bound, "Empty variant layer")
            // Clip and expression are separate properties on purpose: that is what lets a mood
            // control and a pose control act on one character without a combined table.
            if patch.clip != nil {
                try require(targets.insert("\(patch.layerId).clip").inserted, "Duplicate clip binding")
            }
            if patch.expression != nil {
                try require(targets.insert("\(patch.layerId).expression").inserted, "Duplicate expression binding")
            }
            if let text = patch.text {
                try require(!text.isEmpty && text.count <= 160, "Caption must contain 1 to 160 characters")
                try require(targets.insert("\(patch.layerId).text").inserted, "Duplicate text binding")
            }
            if patch.hidden != nil {
                try require(targets.insert("\(patch.layerId).hidden").inserted, "Duplicate visibility binding")
            }
            if let anchor = patch.anchor {
                try require(anchor.isValid, "Invalid option placement")
                try require(targets.insert("\(patch.layerId).anchor").inserted, "Duplicate placement binding")
            }
            if let source = patch.source {
                try require(targets.insert("\(patch.layerId).source").inserted, "Duplicate artwork binding")
                if planned {
                    let plannable: [AnimatedVariantSource.Kind] = [.base, .generate, .existing, .frames, .sequence]
                    try require(plannable.contains(source.kind), "Invalid planned variant source")
                } else {
                    try require([.base, .image, .sequence].contains(source.kind) && source.prompt == nil, "Unbuilt variant artwork")
                }
                if [.image, .sequence, .existing].contains(source.kind) {
                    try require(source.assetId.flatMap(UUID.init(uuidString:)) != nil, "Invalid artwork id")
                } else if source.kind != .base {
                    let described = source.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    try require(described && (source.prompt?.count ?? 0) <= 2000, "Describe the variant artwork")
                }
                if [.sequence, .frames].contains(source.kind) {
                    guard let columns = source.columns, let rows = source.rows,
                          let frames = source.frameCount, let rate = source.frameRate else {
                        throw AnimatedConfigurationError.invalid("Incomplete frame sequence")
                    }
                    let grid = (1...8).contains(columns) && (1...8).contains(rows)
                        && (1...64).contains(frames) && frames <= columns * rows
                    let rated = rate >= 1 && rate <= (planned ? 30 : 60) && source.playback != nil
                    try require(grid && rated, "Invalid frame sequence")
                }
            }
            if let animations = patch.animations {
                try require(animations.count <= 12, "Too many animation effects")
                try require(targets.insert("\(patch.layerId).animations").inserted, "Duplicate animation binding")
            }
        }
        return targets
    }

    private func variantOrderTargets(_ order: [String]?, layerIds: Set<String>) throws -> Set<String> {
        guard let order else { return [] }
        try require(order.count == layerIds.count && Set(order) == layerIds, "Option layer order must list every layer once")
        return ["document.layerOrder"]
    }
}

public enum AnimatedConfigurationError: Error, LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

extension AnimatedDocument {
    public func resolvingConfiguration(_ selected: [String: AnimatedControlValue] = [:]) throws -> Self {
        var result = self
        result.configuration = nil
        guard let configuration else { return result }
        try configuration.validated(layerIds: Set(layers.map(\.id)))
        let values = configuration.normalizedValues(selected)
        var layerOrder: [String]?
        for variant in configuration.variants where variant.selections.allSatisfy({ values[$0.key]?.string == $0.value }) {
            for patch in variant.layers {
                guard let index = result.layers.firstIndex(where: { $0.id == patch.layerId }) else {
                    throw AnimatedConfigurationError.invalid("Missing configurable layer \(patch.layerId)")
                }
                if let source = patch.source { result.layers[index] = try source.applying(to: result.layers[index]) }
                if let text = patch.text {
                    guard case .text(var layer) = result.layers[index] else {
                        throw AnimatedConfigurationError.invalid("Layer \(patch.layerId) is not a text layer")
                    }
                    layer.text = text
                    result.layers[index] = .text(layer)
                }
                if let hidden = patch.hidden { result.layers[index].base.hidden = hidden }
                if let anchor = patch.anchor { result.layers[index].base.anchor = anchor }
                if let animations = patch.animations {
                    result.layers[index].base.animations = animations
                    result.layers[index].base.animation = try AnimationCompiler.compile(
                        animations, anchor: result.layers[index].anchor, timing: AnimationTiming(document: result)
                    )
                }
                if patch.clip != nil || patch.expression != nil {
                    guard case .sprite(var sprite) = result.layers[index] else {
                        throw AnimatedConfigurationError.invalid("Layer \(patch.layerId) is not a sprite, so it has nothing to select")
                    }
                    if let clip = patch.clip {
                        guard sprite.clips.contains(where: { $0.id == clip }) else {
                            throw AnimatedConfigurationError.invalid("Sprite \(sprite.base.id) has no clip \(clip)")
                        }
                        sprite.clipId = clip
                    }
                    if let expression = patch.expression {
                        guard sprite.expressions.tiles.contains(where: { $0.id == expression }) else {
                            throw AnimatedConfigurationError.invalid("Sprite \(sprite.base.id) has no expression \(expression)")
                        }
                        sprite.expressionId = expression
                    }
                    result.layers[index] = .sprite(sprite)
                }
            }
            if let order = variant.layerOrder { layerOrder = order }
        }
        for control in configuration.controls {
            if control.type == .number { result.speed = values[control.id]?.number ?? 1 }
            if control.type == .toggle {
                for index in result.layers.indices where control.layerIds?.contains(result.layers[index].id) == true {
                    result.layers[index].base.hidden = !(values[control.id]?.bool ?? true)
                }
            }
        }
        if let layerOrder {
            let byID = Dictionary(uniqueKeysWithValues: result.layers.map { ($0.id, $0) })
            result.layers = layerOrder.compactMap { byID[$0] }
        }
        return try result.validated()
    }
    public var allConfigurationImageAssetIDs: Set<String> {
        var ids = Set(layers.flatMap(\.referencedImageAssetIDs))
        if case .image(let id, _) = background { ids.insert(id) }
        for variant in configuration?.variants ?? [] {
            for patch in variant.layers {
                if let id = patch.source?.assetId { ids.insert(id) }
                if let id = patch.source?.posterAssetId { ids.insert(id) }
            }
        }
        return ids
    }
}
