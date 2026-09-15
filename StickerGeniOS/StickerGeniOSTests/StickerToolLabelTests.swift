import Foundation
import Testing

@testable import StickerGeniOS

/// Which rows become the navigation subtitle and which stay in the transcript.
///
/// Worth testing directly because getting it wrong is invisible rather than loud: misclassify a
/// phase and the subtitle stays on "Working…" for the whole turn, misclassify a tool call and every
/// one of them fights over the subtitle while vanishing from the transcript the user scrolls back
/// through. Neither breaks anything, so neither shows up except by looking.
@Suite("Sticker tool labels")
struct StickerToolLabelTests {
    @Test("Workflow phases drive the subtitle", arguments: [
        "plan-sticker", "build-plan", "animate-sticker", "generate-sticker",
        "generate-image", "generate-video", "edit-sticker", "show-sticker", "reply"
    ])
    func phasesAreRecognised(_ toolName: String) {
        #expect(StickerToolLabel.isPhase(toolName))
    }

    @Test("The model's own tool calls stay in the transcript", arguments: [
        "create_plan", "update_plan", "show_plan", "finalize_plan",
        "create_animation", "update_animation", "edit_layer_animation", "finalize_animation",
        "edit_layers", "edit_image_layer", "add_image_layer", "create_video", "finalize_edit",
        "view_plan_image", "view_sticker"
    ])
    func toolCallsAreNotPhases(_ toolName: String) {
        #expect(!StickerToolLabel.isPhase(toolName))
    }

    /// The safe default: a tool this build has never heard of shows up as a transcript row rather
    /// than silently taking over the subtitle.
    @Test func anUnknownToolIsTreatedAsAToolCall() {
        #expect(!StickerToolLabel.isPhase("some_new_tool"))
        #expect(!StickerToolLabel.isPhase("some-new-tool"))
    }

    @Test func labelsReadAsEnglishRatherThanAsIdentifiers() {
        #expect(StickerToolLabel.text(for: "edit-sticker") == "Editing sticker")
        #expect(StickerToolLabel.text(for: "build-plan") == "Building plan")
        #expect(StickerToolLabel.text(for: "animate-sticker") == "Animating sticker")
        #expect(StickerToolLabel.text(for: "create_animation") == "Creating animation")
        #expect(StickerToolLabel.text(for: "view_plan_image") == "Reviewing the plan image")
        #expect(StickerToolLabel.text(for: "view_sticker") == "Reviewing the sticker")
        #expect(StickerToolLabel.text(for: "create_video") == "Filming a clip")
        #expect(StickerToolLabel.text(for: "generate-video") == "Filming a clip")
    }

    /// The server distinguishes repeat calls within a turn with a `#N` suffix. Splitting it off
    /// before matching is what stops "build-plan #2" falling through to the raw-id fallback.
    @Test func aRepeatKeepsItsLabelAndGainsAnOrdinal() {
        #expect(StickerToolLabel.text(for: "build-plan #2") == "Building plan (2)")
        #expect(StickerToolLabel.isPhase("build-plan #2"))
        #expect(StickerToolLabel.isPhase("generate-video #2"))
        #expect(StickerToolLabel.text(for: "generate-video #2") == "Filming a clip (2)")
        #expect(StickerToolLabel.text(for: "update_plan #3") == "Revising the plan (3)")
    }

    /// Stages are what the screen says during the stretches of a turn that open no tool row, so an
    /// unlisted one has to read as English too — the server can add a stage before this build knows
    /// about it, and "preparing_context" on a card is worse than a plain sentence.
    @Test func stagesReadAsEnglish() {
        #expect(StickerToolLabel.text(forStage: "reading_request") == "Reading your request")
        #expect(StickerToolLabel.text(forStage: "preparing_context") == "Gathering references")
        #expect(StickerToolLabel.text(forStage: "generating_image") == "Drawing artwork")
        #expect(StickerToolLabel.text(forStage: "composing_video") == "Filming a clip")
        #expect(StickerToolLabel.text(forStage: "finalizing") == "Finishing up")
        #expect(StickerToolLabel.text(forStage: "polishing_edges") == "Polishing edges")
    }

    @Test func anUnknownToolIsStillSentenceCased() {
        #expect(StickerToolLabel.text(for: "some_new_tool") == "Some new tool")
        #expect(StickerToolLabel.text(for: "polish-edges") == "Polish edges")
    }
}
