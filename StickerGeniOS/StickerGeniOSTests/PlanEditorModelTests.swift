import Foundation
import Testing

@testable import StickerGeniOS

/// What the plan editor sends, which is the whole of its contract with the server.
///
/// The endpoint rebuilds the plan from the version it already holds, so an edit that mentions a
/// layer rewrites it and an edit that only names one leaves it alone. Everything the card cannot
/// draw — a text layer's font, the parameters of a `spin` — survives on that distinction, which
/// makes "what does an untouched editor send?" the load-bearing question here.
@Suite("Plan editor edits")
struct PlanEditorModelTests {
    private func plan(
        kind: StickerKind = .animated,
        layers: [PlanLayer]? = nil
    ) -> Plan {
        Plan(
            version: 1,
            title: "Waving cat",
            summary: "A cat waving.",
            kind: kind,
            timing: .init(durationSeconds: 2, fps: 30, loop: .loop),
            layers: layers ?? [
                PlanLayer(
                    layerId: "part_0", name: "Cat", source: .generate(prompt: "A cat"),
                    x: 0.5, y: 0.5, scaleX: 0.6, scaleY: 0.6, rotationDegrees: 0,
                    animations: [PlanAnimation(type: "spin", delay: 0.2, duration: 0.5)]
                ),
                PlanLayer(
                    layerId: "part_1", name: "Caption", source: .text(text: "HI", color: "#FFFFFF"),
                    x: 0.5, y: 0.85, scaleX: 0.7, scaleY: 0.2, rotationDegrees: 0, animations: []
                )
            ]
        )
    }

    @Test("An editor nobody touched sends nothing")
    func untouchedEditIsEmpty() {
        let model = PlanEditorModel(plan: plan())
        #expect(model.edit().isEmpty)
        #expect(model.validationMessage == nil)
    }

    @Test("A retyped description rewrites only its own layer")
    func editingOneLayerKeepsTheOthers() {
        var model = PlanEditorModel(plan: plan())
        model.layers[0].prompt = "A cat in a hat"
        let edit = model.edit()

        #expect(edit.title == nil)
        #expect(edit.timing == nil)
        #expect(edit.layers?.count == 2)
        #expect(edit.layers?[0] == PlanLayerEdit(
            from: "part_0",
            source: .generate(prompt: "A cat in a hat")
        ))
        // The caption is named and nothing else: its font, weight and alignment are the server's to
        // carry over, and restating the source is exactly how they would be lost.
        #expect(edit.layers?[1] == PlanLayerEdit(from: "part_1"))
    }

    @Test("Switching a layer to a clip carries the motion and the clip length")
    func switchingToVideo() {
        var model = PlanEditorModel(plan: plan())
        model.layers[0].source = .video
        model.layers[0].motion = "a slow turntable spin"
        model.layers[0].videoSeconds = 4
        #expect(model.validationMessage == nil)
        #expect(model.edit().layers?[0].source == .video(
            prompt: "A cat", motion: "a slow turntable spin", durationSeconds: 4
        ))
        // One clip per plan, so a second layer is not offered the option.
        #expect(model.videoLayerID == model.layers[0].id)
    }

    @Test("A clip with no described motion cannot be saved")
    func videoNeedsMotion() {
        var model = PlanEditorModel(plan: plan())
        model.layers[0].source = .video
        #expect(model.validationMessage != nil)
    }

    @Test("Adding motion keeps the effects already there by index")
    func addedMotionKeepsExistingEffects() {
        var model = PlanEditorModel(plan: plan())
        model.layers[0].effects.append(PlanEditorModel.Effect(
            origin: nil, type: "slideIn", direction: "up",
            delay: 0.3, duration: 0.4, originalDelay: 0, originalDuration: 0.5
        ))
        let animations = model.edit().layers?[0].animations

        #expect(animations?.count == 2)
        // The `spin` the planner wrote comes back by index, so its turns and direction survive.
        #expect(animations?[0] == PlanAnimationEdit(from: 0))
        #expect(animations?[1] == PlanAnimationEdit(spec: PlanAnimationSpecEdit(
            type: "slideIn", delay: 0.3, duration: 0.4, direction: "up"
        )))
    }

    @Test("Retiming an effect sends the new delay and nothing else")
    func retimingSendsOnlyTheDelay() {
        var model = PlanEditorModel(plan: plan())
        model.layers[0].effects[0].delay = 0.8
        #expect(model.edit().layers?[0].animations == [PlanAnimationEdit(from: 0, delay: 0.8)])
    }

    @Test("Removing a layer sends the list without it")
    func removingALayer() {
        var model = PlanEditorModel(plan: plan())
        model.layers.removeAll { $0.layerId == "part_1" }
        #expect(model.edit().layers == [PlanLayerEdit(from: "part_0")])
    }

    @Test("A new layer arrives with an identity, a description, and a place on the canvas")
    func addingALayer() {
        var model = PlanEditorModel(plan: plan())
        var added = PlanEditorModel.newLayer(existingIDs: Set(model.layers.map(\.layerId)))
        added.name = "Sparkles"
        added.prompt = "Tiny gold sparkles"
        model.layers.append(added)

        let entry = model.edit().layers?.last
        #expect(entry?.from == nil)
        #expect(entry?.layerId == added.layerId)
        #expect(entry?.name == "Sparkles")
        #expect(entry?.source == .generate(prompt: "Tiny gold sparkles"))
        #expect(entry?.x == 0.5)
        #expect(model.validationMessage == nil)
    }

    @Test("A layer added with no description blocks the save")
    func addedLayerNeedsADescription() {
        var model = PlanEditorModel(plan: plan())
        model.layers.append(PlanEditorModel.newLayer(existingIDs: []))
        #expect(model.validationMessage != nil)
    }

    @Test("Changing the duration sends the timing alone")
    func timingOnly() {
        var model = PlanEditorModel(plan: plan())
        model.durationSeconds = 3.5
        let edit = model.edit()
        #expect(edit.timing == PlanTimingEdit(durationSeconds: 3.5))
        #expect(edit.layers == nil)
    }

    @Test("Only a source the editor cannot author offers to be kept")
    func keepIsOfferedForUnauthorableSources() {
        let model = PlanEditorModel(plan: plan())
        #expect(model.layers[0].canKeep == false)
        #expect(model.layers[1].canKeep)
        #expect(model.layers[1].source == .keep)
        // Its name is what the prompt field opens on, so converting it starts from something real.
        #expect(model.layers[1].prompt == "Caption")
    }
}
