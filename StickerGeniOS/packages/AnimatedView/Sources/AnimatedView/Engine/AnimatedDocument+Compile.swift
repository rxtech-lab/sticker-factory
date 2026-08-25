import Foundation

extension AnimatedDocument {
    /// Recompiles every layer that carries declarative specs, replacing its keyframe tracks.
    ///
    /// A document stores both representations, and they must agree — the server rejects one where
    /// they don't. This is how a document authored in Swift gets into that agreeing state, and how
    /// a timing change is absorbed: compiled keyframes are absolute times derived from the old
    /// duration, so they go stale the moment `durationSeconds` changes, while specs are relative
    /// and survive.
    ///
    /// Layers with no specs are left exactly as they are, so hand-authored keyframes are never
    /// silently overwritten.
    public func compiled() throws -> AnimatedDocument {
        let declarative = layers.enumerated().filter { !$0.element.animations.isEmpty }
        guard !declarative.isEmpty else { return self }

        let compiled = try AnimationCompiler.compileAll(
            declarative.map { .init(layerId: $0.element.id, specs: $0.element.animations, anchor: $0.element.anchor) },
            timing: AnimationTiming(document: self)
        )

        var result = self
        for (offset, entry) in declarative.enumerated() {
            result.layers[entry.offset].base.animation = compiled[offset]
        }
        return result
    }

    /// Replaces a layer's declarative motion and recompiles the whole document.
    ///
    /// The document-wide recompile is not incidental: the keyframe budget is shared, so adding
    /// cycles to one layer can force every other cyclic layer to sample less densely.
    public func settingAnimations(_ specs: [AnimationSpec], forLayer id: String) throws -> AnimatedDocument {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return self }
        var result = self
        result.layers[index].base.animations = specs
        return try result.compiled()
    }

    /// Changes timing and recompiles, since every compiled keyframe time depends on the duration.
    public func settingTiming(durationSeconds: Double, fps: Int, loop: AnimatedLoop) throws -> AnimatedDocument {
        var result = self
        result.durationSeconds = durationSeconds
        result.fps = fps
        result.loop = loop
        return try result.compiled()
    }
}
