import Foundation

/// Human wording for the tool ids the server streams, and which of them are *phases*.
///
/// The distinction is not cosmetic, and it already exists in the data. `workflows/sticker-generation`
/// opens two different kinds of row through the same call:
///
///   - **phases**, named in kebab-case (`plan-sticker`, `animate-sticker`, `build-plan`), are the
///     turn's overall stage. There is one at a time and it is what the user means by "what is it
///     doing right now" — so it belongs in the navigation bar, where it cannot scroll away.
///   - **tool calls**, named in snake_case (`create_animation`, `edit_layers`), are the individual
///     steps the model takes inside a phase. There are many per turn and they are a record of work
///     done, so they stay in the transcript as rows the user can scroll back through.
///
/// Matching on the naming convention rather than on an explicit list would be too clever to trust,
/// so the phases are enumerated. A tool id nobody has listed is treated as a tool call, which is the
/// safe default: it shows up in the transcript rather than silently taking over the title chip.
///
/// `nonisolated` because it is a pure string lookup with no state: the view reads it on the main
/// actor, and the tests read it off one.
nonisolated enum StickerToolLabel {
    /// The workflow stages, which drive the second line of the navigation bar's title chip.
    private static let phases: Set<String> = [
        "generate-sticker",
        "generate-image",
        "generate-video",
        "edit-sticker",
        "animate-sticker",
        "plan-sticker",
        "build-plan",
        "show-sticker",
        "reply"
    ]

    /// Whether this row is the turn's overall stage rather than one step inside it.
    static func isPhase(_ toolName: String) -> Bool {
        phases.contains(base(of: toolName))
    }

    /// Sentence-cased wording for a tool id.
    ///
    /// The server appends a `#2` suffix to tell repeat calls within one turn apart (`toolCallLabeller`
    /// in `workflows/sticker-generation/steps.ts`), so the suffix is split off before matching and
    /// re-attached as an ordinal — "Drawing artwork (2)" rather than a label that fails to match and
    /// falls back to a raw id.
    static func text(for toolName: String) -> String {
        let stem = base(of: toolName)
        let ordinal = self.ordinal(of: toolName)
        let label = known[stem] ?? fallback(for: stem)
        return ordinal.isEmpty ? label : "\(label) (\(ordinal))"
    }

    /// Sentence-cased wording for a `stage` on a progress event.
    ///
    /// Stages are the *inside* of a phase — the long silent stretches where no tool row opens and
    /// the only thing the screen could otherwise say is that something, somewhere, is happening.
    /// They are a separate vocabulary from tool ids (`workflows/sticker-generation`, and
    /// `liveActivitySnapshot` on the server, which words them the same way), so they get their own
    /// table; an unlisted stage falls back to its own words rather than to silence.
    static func text(forStage stage: String) -> String {
        stages[stage] ?? fallback(for: stage)
    }

    private static let stages: [String: String] = [
        "reading_request": String(localized: "Reading your request"),
        "preparing_context": String(localized: "Gathering references"),
        "planning_edit": String(localized: "Planning the edit"),
        "planning_animation": String(localized: "Planning the motion"),
        "generating_image": String(localized: "Drawing artwork"),
        "reviewing": String(localized: "Reviewing the design"),
        "composing": String(localized: "Composing the artwork"),
        "composing_part": String(localized: "Drawing a part"),
        "composing_sprite": String(localized: "Drawing the frames"),
        "composing_video": String(localized: "Filming a clip"),
        "assembling": String(localized: "Assembling the layers"),
        "validating_candidate": String(localized: "Checking the result"),
        "rendering_exports": String(localized: "Rendering the sticker"),
        "verifying_exports": String(localized: "Verifying the files"),
        "finalizing": String(localized: "Finishing up")
    ]

    private static func base(of toolName: String) -> String {
        String(toolName.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
            .trimmingCharacters(in: .whitespaces)
    }

    private static func ordinal(of toolName: String) -> String {
        let parts = toolName.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count > 1 else { return "" }
        return String(parts[1]).trimmingCharacters(in: .whitespaces)
    }

    private static let known: [String: String] = [
        // Phases.
        "reply": String(localized: "Writing a reply"),
        "generate-sticker": String(localized: "Making your sticker"),
        "generate-image": String(localized: "Drawing artwork"),
        "generate-video": String(localized: "Filming a clip"),
        "edit-sticker": String(localized: "Editing sticker"),
        "animate-sticker": String(localized: "Animating sticker"),
        "plan-sticker": String(localized: "Planning sticker"),
        "build-plan": String(localized: "Building plan"),
        "show-sticker": String(localized: "Showing the sticker"),
        // Tool calls.
        "create_plan": String(localized: "Drafting a plan"),
        "update_plan": String(localized: "Revising the plan"),
        "show_plan": String(localized: "Showing the plan"),
        "finalize_plan": String(localized: "Finishing the plan"),
        "create_animation": String(localized: "Creating animation"),
        "update_animation": String(localized: "Adjusting animation"),
        "edit_layer_animation": String(localized: "Tuning a layer"),
        "finalize_animation": String(localized: "Finishing animation"),
        "edit_layers": String(localized: "Editing layers"),
        "edit_image_layer": String(localized: "Redrawing a layer"),
        "add_image_layer": String(localized: "Adding a layer"),
        "create_video": String(localized: "Filming a clip"),
        "finalize_edit": String(localized: "Finishing the edit"),
        "view_plan_image": String(localized: "Reviewing the plan image"),
        "view_sticker": String(localized: "Reviewing the sticker"),
        // The server-rendered publish behind quick mode. Not tool calls in the agent's sense — no
        // model runs them — but they are reported as such because they are exactly what the step
        // list is for: several slow pieces of work, in order, that the user is waiting on.
        "render_artwork": String(localized: "Drawing it full size"),
        "render_frames": String(localized: "Drawing the frames"),
        "render_attachments": String(localized: "Making the send sizes"),
        "render_webp": String(localized: "Making the compact copy"),
        "render_sizes": String(localized: "Fitting it for Messages"),
        "save_renditions": String(localized: "Saving it")
    ]

    /// An unknown tool still has to read as English, because the server can ship a new one before
    /// this build knows about it. `some_new_tool` becomes "Some new tool".
    private static func fallback(for toolName: String) -> String {
        let words = toolName.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let first = words.first else { return String(localized: "Working") }
        return first.uppercased() + words.dropFirst()
    }
}
