import AnimatedView
import Foundation

/// The configuration budget, as the server states it.
///
/// None of these numbers is decided here. The app asks once per launch
/// (`GET /api/v1/configuration-limits`, cached for the next cold start) and enforces exactly what
/// it is told, so raising a cap is a server deploy rather than a release. An app that has never
/// heard holds `nil` and enforces nothing: the server refuses the plan, which it would have done
/// anyway, and that refusal is the only authority on the subject.
nonisolated struct ConfigurationLimits: Codable, Sendable, Hashable {
    var controls: Int
    var controlOptions: Int
    var controlOptionsMinimum: Int
    var variants: Int
    var layerCombinations: Int
    var preparedStates: Int
    /// Layers one plan may hold. Not part of the configuration budget, but spent on the same
    /// screen, and the plan editor has no other way to learn it either.
    var planLayers: Int

    /// A budget the editor can act on.
    ///
    /// Only nonsense is rejected — a zero or inverted cap would grey out every button on the
    /// screen, which is a worse answer than the honest "no limits known yet" that `nil` gives.
    func validated() throws -> Self {
        let values = [controls, controlOptions, controlOptionsMinimum,
                      variants, layerCombinations, preparedStates, planLayers]
        guard values.allSatisfy({ $0 > 0 }), controlOptionsMinimum <= controlOptions else {
            throw StickerAPIError.invalidResponse
        }
        return self
    }

    /// Whether one more choice control on this layer would put it past its ceiling.
    ///
    /// A new control arrives with the fewest options a choice can have, so that is what the
    /// layer's current count is multiplied by.
    func exceedsLayerCombinations(addingControlTo combinations: Int) -> Bool {
        combinations * controlOptionsMinimum > layerCombinations
    }

    /// Whether one more option on a control already offering `options` would do the same.
    func exceedsLayerCombinations(addingOptionTo combinations: Int, options: Int) -> Bool {
        options >= controlOptions || combinations / max(1, options) * (options + 1) > layerCombinations
    }

    /// Why this configuration is over budget, in the same terms the server would answer with —
    /// said before the round trip instead of after it. `nil` when it fits.
    func issue(for configuration: AnimatedControlConfiguration) -> String? {
        if configuration.controls.count > controls {
            return String(localized: "A sticker can have at most \(controls) controls.")
        }
        if configuration.variants.count > variants {
            return String(localized: "A sticker can have at most \(variants) artwork rows.")
        }
        for (layerID, count) in configuration.layerCombinationCounts.sorted(by: { $0.key < $1.key })
        where count > layerCombinations {
            return String(localized: """
                \(layerID) has \(count) mood/pose combinations; at most \(layerCombinations) can be \
                prepared. Drop an option from one of its controls.
                """)
        }
        let prepared = configuration.preparedStateCount
        if prepared > preparedStates {
            return String(localized: """
                At most \(preparedStates) states in total can be prepared, and these controls reach \
                \(prepared). Reduce the number of options, or the number of configurable layers.
                """)
        }
        return nil
    }
}
