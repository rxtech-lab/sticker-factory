import Foundation
import Observation

/// The editing session's state: a document, a selection, a playhead, and an undo history.
///
/// Cross-platform on purpose. Everything here is `Foundation` and `Observation`, so the entire
/// editing model — every mutation, every guard, every undo interaction — is exercised by
/// `swift test` on macOS. Only the views that drive it are iOS-only.
///
/// Every mutating method has the same three-line shape: call a pure function, and on success record
/// the previous document and adopt the new one; on failure publish the error and change nothing.
/// That is why the pure functions return a document instead of mutating in place — it makes "the
/// edit was refused" and "the edit half-happened" different by construction.
@MainActor
@Observable
public final class AnimatedDocumentEditor {
    /// The document being edited. Only this type may write it.
    public private(set) var document: AnimatedDocument

    public var selectedLayerID: String?
    /// The keyframe the timeline has selected, if any.
    public var selectedKeyframe: AnimatedKeyframeSelection?

    /// The playhead, in **document time** — the same space keyframes live in, before `speed`.
    ///
    /// Not wall-clock time. `AnimationInterpolator.mappedTime` multiplies wall-clock by `speed`, so
    /// a scrubber that stored wall-clock would put the playhead at the wrong keyframe on any
    /// document not playing at 1×.
    ///
    /// Computed over private storage rather than a stored property with a `didSet`: `@Observable`
    /// rewrites stored properties into accessors, and a `didSet` that assigns to its own property
    /// then re-enters that setter and recurses until the stack overflows. Clamping in the setter
    /// has the same effect and cannot recurse. Observation still works — the getter reads a stored
    /// property, so the macro registers the access.
    public var scrubDocumentTime: Double {
        get { storedScrubTime }
        set { storedScrubTime = clampedScrubTime(newValue) }
    }

    private var storedScrubTime: Double = 0

    /// Whether the playhead is advancing.
    ///
    /// Setting this captures where playback resumes from, so pausing at 1.2s and pressing play
    /// again continues from 1.2s rather than restarting. Computed over private storage rather than
    /// carrying a `didSet`, for the same reason `scrubDocumentTime` is: `@Observable` rewrites
    /// stored properties into accessors, and a `didSet` that touches its own property re-enters the
    /// setter.
    public var isPlaying: Bool {
        get { storedIsPlaying }
        set { setPlaying(newValue) }
    }

    /// Starts or stops playback, against an explicit clock.
    ///
    /// `now` exists so the whole playback path is testable: with a real `Date()` captured inside
    /// the setter, a test measuring from a fixed instant would compare against whenever the test
    /// happened to run. Callers in the app use the default and go through `isPlaying`.
    public func setPlaying(_ playing: Bool, now: Date = Date()) {
        guard playing != storedIsPlaying else { return }
        storedIsPlaying = playing
        playbackAnchorTime = playing ? storedScrubTime : 0
        playbackStartedAt = playing ? now : nil
    }

    private var storedIsPlaying = false
    /// Where the playhead sat when playback last started, and when that was.
    private var playbackAnchorTime: Double = 0
    private var playbackStartedAt: Date?

    /// Moves the playhead to wherever wall clock says it should be.
    ///
    /// The editor drives its own clock rather than letting a `TimelineView` render ahead of the
    /// model, because the playhead, the scrubber, and the time readout all read
    /// `scrubDocumentTime` — a clock that only fed the canvas would animate the artwork while the
    /// timeline sat still.
    ///
    /// Returns `false` once a play-once document has reached its end, which is the caller's cue to
    /// stop ticking.
    @discardableResult
    public func advancePlayback(now: Date = Date()) -> Bool {
        guard storedIsPlaying, document.kind == .animated, let startedAt = playbackStartedAt else { return false }

        // `mappedTime` takes wall clock and applies both `speed` and the loop mode, so the resume
        // point has to be expressed in wall clock too — hence dividing the anchor by speed.
        let speed = Swift.max(document.speed, 0.0001)
        let elapsed = now.timeIntervalSince(startedAt)
        storedScrubTime = AnimationInterpolator.mappedTime(playbackAnchorTime / speed + elapsed, document: document)

        // A one-shot that has played out should settle on its final frame rather than leaving a
        // pause button that no longer pauses anything.
        if document.loop == .once, storedScrubTime >= document.durationSeconds - 1e-6 {
            isPlaying = false
            return false
        }
        return true
    }

    /// The most recent refused edit. The UI shows it and clears it; it never blocks anything.
    public var lastError: AnimatedEditorError?

    /// Everything currently wrong with the document, recomputed after each successful edit.
    public private(set) var issues: [AnimatedEditorIssue]

    /// Layers the user has already agreed to convert from preset motion this session, so the
    /// confirmation is asked once per layer rather than on every drag.
    public private(set) var confirmedDetachLayerIDs: Set<String> = []

    private var undoStack = AnimatedEditorUndoStack()
    private var activeGestureKey: String?

    public init(document: AnimatedDocument) {
        self.document = document
        self.issues = document.editorIssues
    }

    // MARK: - Derived state

    public var selectedLayer: AnimatedLayer? {
        selectedLayerID.flatMap { document.layer(id: $0) }
    }

    public var canUndo: Bool { undoStack.canUndo }
    public var canRedo: Bool { undoStack.canRedo }
    public var undoActionName: String? { undoStack.undoActionName }
    public var redoActionName: String? { undoStack.redoActionName }

    /// Blocking issues alone — what stands between the document and a successful save.
    public var blockingIssues: [AnimatedEditorIssue] {
        issues.filter { $0.severity == .blocking }
    }

    public var canSave: Bool { blockingIssues.isEmpty }

    /// The state the selected layer is in right now, for the inspector's readouts.
    public var selectedLayerState: AnimatedLayerState? {
        selectedLayer.map { AnimationInterpolator.state(for: $0, atDocumentTime: scrubDocumentTime) }
    }

    /// What a gesture on `channel` would write to, for the selection overlay's caption.
    public func editTarget(for channel: AnimationChannel) -> AnimatedEditTarget? {
        selectedLayer.map {
            AnimatedEditTargetResolver.target(channel: channel, layer: $0, atDocumentTime: scrubDocumentTime)
        }
    }

    private func clampedScrubTime(_ time: Double) -> Double {
        guard document.kind == .animated, document.durationSeconds > 0 else { return 0 }
        return Swift.min(Swift.max(time, 0), document.durationSeconds)
    }

    // MARK: - Applying an edit

    /// The single funnel every mutation passes through.
    ///
    /// On success: snapshot the old document, adopt the new one, refresh the issue list. On failure:
    /// publish the error and leave everything untouched, so a refused edit is a true no-op.
    @discardableResult
    private func apply(_ name: String, coalescingKey: String? = nil, _ edit: (AnimatedDocument) throws -> AnimatedDocument) -> Bool {
        do {
            let previous = document
            let next = try edit(previous)
            guard next != previous else { return true }
            undoStack.record(previous, name: name, coalescingKey: coalescingKey ?? activeGestureKey)
            adopt(next)
            return true
        } catch let error as AnimatedEditorError {
            lastError = error
            return false
        } catch {
            lastError = .compile(error.localizedDescription)
            return false
        }
    }

    /// Installs a document and re-derives everything that hangs off it.
    private func adopt(_ next: AnimatedDocument) {
        document = next
        issues = next.editorIssues
        // A selection can outlive the thing it points at — undoing an "add layer", or deleting the
        // selected one. Leaving a dangling id would make the inspector render an empty shell.
        if let id = selectedLayerID, next.layer(id: id) == nil {
            selectedLayerID = nil
            selectedKeyframe = nil
        }
        if let selection = selectedKeyframe,
           let layer = next.layer(id: selection.layerID),
           selection.index >= layer.animation.count(of: selection.channel) {
            selectedKeyframe = nil
        }
        // Shortening the document, or making it static, can strand the playhead past the end.
        storedScrubTime = clampedScrubTime(storedScrubTime)
    }

    // MARK: - Gestures and undo

    /// Marks the start of a continuous gesture so its many small edits collapse into one undo step.
    public func beginGesture(_ key: String) {
        activeGestureKey = key
    }

    public func endGesture() {
        activeGestureKey = nil
        undoStack.endCoalescing()
    }

    public func undo() {
        guard let restored = undoStack.undo(current: document) else { return }
        adopt(restored)
    }

    public func redo() {
        guard let restored = undoStack.redo(current: document) else { return }
        adopt(restored)
    }

    // MARK: - Layers

    /// Adds a starter layer and selects it. Returns the new layer's id.
    @discardableResult
    public func addLayer(_ type: AnimatedLayerType, assetID: String? = nil) -> String? {
        var created: String?
        apply("Add \(AnimatedEditorDefaults.defaultName(for: type))") { document in
            let (next, id) = try document.addingStarterLayer(type, assetID: assetID)
            created = id
            return next
        }
        if let created { selectedLayerID = created }
        return created
    }

    public func removeLayer(id: String) {
        apply("Delete Layer") { try $0.removingLayer(id: id) }
    }

    public func duplicateLayer(id: String) {
        let before = Set(document.layers.map(\.id))
        apply("Duplicate Layer") { try $0.duplicatingLayer(id: id) }
        if let created = document.layers.map(\.id).first(where: { !before.contains($0) }) {
            selectedLayerID = created
        }
    }

    public func moveLayer(id: String, toIndex index: Int) {
        apply("Reorder Layers") { try $0.movingLayer(id: id, toIndex: index) }
    }

    public func renameLayer(id: String, to name: String) {
        apply("Rename Layer", coalescingKey: "rename-\(id)") { try $0.renamingLayer(id: id, to: name) }
    }

    public func setHidden(_ hidden: Bool, forLayer id: String) {
        apply(hidden ? "Hide Layer" : "Show Layer") { try $0.settingHidden(hidden, forLayer: id) }
    }

    public func setBlendMode(_ mode: AnimatedBlendMode, forLayer id: String) {
        apply("Change Blend Mode") { try $0.settingBlendMode(mode, forLayer: id) }
    }

    /// Writes a layer's type-specific fields. Nothing here is compiler input, so nothing recompiles.
    public func updateLayer(id: String, name: String = "Edit Layer", coalescingKey: String? = nil, _ body: @escaping (inout AnimatedLayer) -> Void) {
        apply(name, coalescingKey: coalescingKey) { try $0.updatingLayer(id: id, body) }
    }

    // MARK: - Canvas edits

    public func setPosition(_ value: AnimatedPoint, forLayer id: String) {
        apply("Move Layer", coalescingKey: "position-\(id)") {
            try $0.applyingPosition(value, toLayer: id, atDocumentTime: scrubDocumentTime)
        }
    }

    public func setScale(_ value: AnimatedPoint, forLayer id: String) {
        apply("Scale Layer", coalescingKey: "scale-\(id)") {
            try $0.applyingScale(value, toLayer: id, atDocumentTime: scrubDocumentTime)
        }
    }

    public func setRotation(_ degrees: Double, forLayer id: String) {
        apply("Rotate Layer", coalescingKey: "rotation-\(id)") {
            try $0.applyingRotation(degrees, toLayer: id, atDocumentTime: scrubDocumentTime)
        }
    }

    public func setOpacity(_ value: Double, forLayer id: String) {
        apply("Change Opacity", coalescingKey: "opacity-\(id)") {
            try $0.applyingOpacity(value, toLayer: id, atDocumentTime: scrubDocumentTime)
        }
    }

    public func setTrim(_ value: AnimatedTrim, forLayer id: String) {
        apply("Change Trim", coalescingKey: "trim-\(id)") {
            try $0.applyingTrim(value, toLayer: id, atDocumentTime: scrubDocumentTime)
        }
    }

    public func setEffects(_ value: AnimatedEffectValue, forLayer id: String) {
        apply("Change Effects", coalescingKey: "effects-\(id)") {
            try $0.applyingEffects(value, toLayer: id, atDocumentTime: scrubDocumentTime)
        }
    }

    // MARK: - Keyframes

    public func insertKeyframe(on channel: AnimationChannel, forLayer id: String) {
        guard let layer = document.layer(id: id) else { return }
        let time = scrubDocumentTime
        let state = AnimationInterpolator.state(for: layer, atDocumentTime: time)
        apply("Add Keyframe") { document in
            let animation = try layer.animation.insertingKeyframe(on: channel, atTime: time, sampledFrom: state)
            return try document.settingAnimation(animation, forLayer: id)
        }
        if let updated = document.layer(id: id),
           let index = updated.animation.keyframeIndex(on: channel, near: time, tolerance: 1e-6) {
            selectedKeyframe = .init(layerID: id, channel: channel, index: index)
        }
    }

    public func moveKeyframe(on channel: AnimationChannel, forLayer id: String, index: Int, toTime time: Double) {
        guard let layer = document.layer(id: id) else { return }
        apply("Move Keyframe", coalescingKey: "keyframe-\(id)-\(channel.rawValue)-\(index)") { document in
            let animation = try layer.animation.movingKeyframe(
                on: channel, index: index, toTime: time, clampedTo: document.durationSeconds
            )
            return try document.settingAnimation(animation, forLayer: id)
        }
    }

    public func removeKeyframe(on channel: AnimationChannel, forLayer id: String, index: Int) {
        guard let layer = document.layer(id: id) else { return }
        apply("Delete Keyframe") { document in
            let animation = try layer.animation.removingKeyframe(on: channel, index: index)
            return try document.settingAnimation(animation, forLayer: id)
        }
        if selectedKeyframe?.channel == channel, selectedKeyframe?.index == index { selectedKeyframe = nil }
    }

    /// Applies an arbitrary channel edit to one layer's keyframes.
    ///
    /// The keyframe inspector's value controls all funnel through here rather than each getting its
    /// own method on this class: the six channels carry genuinely different payloads, and a
    /// per-channel API would be six near-identical wrappers around one line.
    public func applyKeyframeEdit(
        forLayer id: String,
        name: String = "Edit Keyframe",
        coalescingKey: String? = nil,
        _ edit: @escaping (AnimatedLayerAnimation) throws -> AnimatedLayerAnimation
    ) {
        guard let layer = document.layer(id: id) else { return }
        apply(name, coalescingKey: coalescingKey) { document in
            try document.settingAnimation(try edit(layer.animation), forLayer: id)
        }
    }

    public func setKeyframeEasing(_ easing: AnimatedEasing, on channel: AnimationChannel, forLayer id: String, index: Int) {
        guard let layer = document.layer(id: id) else { return }
        apply("Change Easing") { document in
            let animation = try layer.animation.settingEasing(easing, on: channel, index: index)
            return try document.settingAnimation(animation, forLayer: id)
        }
    }

    // MARK: - Detaching

    /// Whether a gesture on this layer needs the "convert preset motion?" confirmation first.
    public func needsDetachConfirmation(forLayer id: String) -> Bool {
        document.layerIsDeclarative(id) && !confirmedDetachLayerIDs.contains(id)
    }

    /// Converts a layer's preset motion into editable keyframes.
    ///
    /// One-way: the specs are gone and a later duration change can only rescale the keyframes they
    /// produced, never re-derive them. Undo is the only way back, which is why the UI confirms.
    public func detachAnimations(forLayer id: String) {
        confirmedDetachLayerIDs.insert(id)
        apply("Convert to Keyframes") { try $0.detachingAnimations(forLayer: id) }
    }

    // MARK: - Document settings

    public func setCanvas(_ canvas: AnimatedCanvas) {
        apply("Resize Canvas", coalescingKey: "canvas") { $0.settingCanvas(canvas) }
    }

    public func setSpeed(_ speed: Double) {
        apply("Change Speed", coalescingKey: "speed") { $0.settingSpeed(speed) }
    }

    public func setBackground(_ background: AnimatedBackground, mp4: AnimatedBackground? = nil) {
        apply("Change Background") { $0.settingBackground(background, mp4: mp4) }
    }

    public func setTiming(
        durationSeconds: Double? = nil,
        fps: Int? = nil,
        loop: AnimatedLoop? = nil,
        rescalingDetachedKeyframes: Bool = true
    ) {
        apply("Change Timing", coalescingKey: "timing") { document in
            try document.settingDuration(
                durationSeconds ?? document.durationSeconds,
                fps: fps,
                loop: loop,
                rescalingDetachedKeyframes: rescalingDetachedKeyframes
            )
        }
    }

    public func setKind(_ kind: AnimatedKind) {
        let time = scrubDocumentTime
        apply(kind == .static ? "Convert to Still" : "Convert to Animation") {
            try $0.settingKind(kind, bakingAtDocumentTime: time)
        }
    }

    // MARK: - Saving

    /// The document, if it is fit to leave the editor.
    ///
    /// The host calls this rather than reading `document` directly when it is about to persist or
    /// export: `issues` is advisory and deliberately non-blocking, but a save has to be all-or-nothing.
    public func validatedDocument() throws -> AnimatedDocument {
        try document.validated()
    }

    /// Replaces the document wholesale — for a host that reloaded it from the server.
    ///
    /// Clears the history, because undoing across a reload would resurrect a document the server
    /// has never heard of.
    public func replaceDocument(_ next: AnimatedDocument) {
        undoStack.removeAll()
        adopt(next)
    }
}

/// Which keyframe the timeline has selected.
public struct AnimatedKeyframeSelection: Hashable, Sendable {
    public var layerID: String
    public var channel: AnimationChannel
    public var index: Int

    public init(layerID: String, channel: AnimationChannel, index: Int) {
        self.layerID = layerID
        self.channel = channel
        self.index = index
    }
}
