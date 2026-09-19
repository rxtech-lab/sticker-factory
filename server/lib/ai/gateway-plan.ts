// Planning a composition and settling where its parts sit.

import { createWebTools, WEB_RESEARCH_PROMPT } from "./web-tools";
import { POSE_COUNTS } from "@/lib/contracts/pose-preset";
import { gateway } from "@ai-sdk/gateway";
import { generateText, hasToolCall, stepCountIs, tool } from "ai";
import { z } from "zod";
import { compactingPrepareStep } from "@/lib/ai/compaction";
import { recordTextApiCost, reportAiStepUsage } from "@/lib/ai/cost";
import { downscaleForModelInput } from "@/lib/storage/r2";
import { viewPlanImageTool } from "@/lib/ai/view-plan-image-tool";
import { viewStickerTool } from "@/lib/ai/view-sticker-tool";
import { configurationReviewSelections } from "@/lib/contracts/configuration";
import { PlanV1Schema, reusableAssetIds } from "@/lib/contracts/plan";
import { LayoutAdjustmentSchema, layoutDiagnostics } from "@/lib/layout/composition";
import { describeToolError, isTurnAbort, summarizeDocument } from "./gateway-contracts";
import type { AiLayoutContext, AiPlanContext, LayoutDraftState, LayoutDraftingSession, LayoutTurnResult, PlanDraftingSession, PlanTurnResult } from "./gateway-contracts";
import { attachedImagesNote, priorArtNote, userTurn, viewablePlanVisuals, viewableReferences } from "./gateway-models";

export async function refineStickerLayout(
  input: AiLayoutContext,
  session: LayoutDraftingSession,
): Promise<LayoutTurnResult | undefined> {
  let state: LayoutTurnResult | undefined;
  let fatal: unknown;
  const hasPlanImage = Boolean(session.viewPlanImage);
  const references = await viewableReferences(input.references ?? []);
  const configurationCount = input.document.configuration ? configurationReviewSelections(input.document.configuration).length : 1;

  const guard = async (run: () => Promise<LayoutDraftState>) => {
    try {
      const landed = await run();
      state = { revision: landed.revision, finalized: false };
      return {
        revision: landed.revision,
        sticker: summarizeDocument(landed.document),
        diagnostics: layoutDiagnostics(landed.document),
      };
    } catch (error) {
      if (isTurnAbort(error)) {
        fatal = error.reason ?? error;
        throw new Error("This layout review has been stopped. Do not call any more tools.");
      }
      throw new Error(describeToolError(error));
    }
  };

  const tools = {
    ...createWebTools(),
    ...(session.viewPlanImage
      ? { view_plan_image: viewPlanImageTool(() => session.viewPlanImage!()) }
      : {}),
    view_sticker: viewStickerTool(session, { animated: input.document.kind === "animated" }),
    adjust_layout: tool({
      description: [
        "Correct only the composition of the existing layers. placements move, resize, or rotate",
        "layers; order is the complete back-to-front list of layer ids (the last layer is on top).",
        "Every generated asset, layer, and animation is preserved automatically. Use the actual",
        "visible artwork from view_sticker, not just the nominal square layer boxes, to decide",
        "whether overlap is intentional. Keep the main subject readable at thumbnail size.",
        "image and sequence layers hold square artwork fitted inside its box, so send them equal",
        "scaleX and scaleY: an unequal pair is applied as the smaller of the two, never as a",
        "stretch. To make one of them bigger, raise both.",
      ].join(" "),
      inputSchema: LayoutAdjustmentSchema,
      execute: async (adjustment) => guard(() => session.applyLayout(adjustment)),
    }),
    finalize_layout: tool({
      description: [
        "Finish layout review once the final composition has been viewed and is balanced,",
        "readable, and free of accidental obstruction or clipping.",
      ].join(" "),
      inputSchema: z.object({}).strict(),
      execute: async () => {
        const result = await guard(() => session.finalizeLayout());
        if (state) state = { ...state, finalized: true };
        return result;
      },
    }),
  };

  const generation = await generateText({
    // Feeds the chat screen's live token meter; see `reportAiStepUsage`.
    onLanguageModelCallEnd: reportAiStepUsage,
    model: gateway(process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
    system: [
      input.presetGuidance ?? "",
      WEB_RESEARCH_PROMPT,
      "When a document has configuration, view_sticker advances through every choice combination. Review all combinations listed in the instruction, including after layout changes. Do not finalize after viewing only the default.",
      "You are the final composition reviewer for a multi-layer sticker. The individual assets",
      "are already approved-quality: never redraw, replace, remove, rename, or restyle them, and",
      "never change their animation timing. Your only job is layout.",
      hasPlanImage
        ? "First call view_plan_image, then call view_sticker and compare their compositions."
        : "First call view_sticker.",
      "Judge the actual generated pixels: visual hierarchy, balance,",
      "spacing, scale consistency, whether important elements cover each other, whether anything",
      "is clipped, and whether the sticker reads clearly at thumbnail size.",
      "Use adjust_layout only when it improves the composition. Intentional overlap is allowed —",
      "for example a hat on a character — but accidental obstruction, near-duplicate stacking,",
      "and unrelated elements colliding are not. Geometry diagnostics are conservative square-box",
      "warnings, so resolve overlap by looking at the image rather than blindly separating boxes.",
      "After every adjustment, call view_sticker again. Finish with finalize_layout only after",
      "viewing the exact final revision. If the first render is already strong, change nothing and",
      "finalize it.",
      "",
      // The reviewer used to see only its own render, so it had no way to know the build had
      // drifted from the picture the user actually said yes to.
      hasPlanImage
        ? "The view_plan_image tool returns the static reference image the user approved. Every layer in this sticker"
          + " was separated out of that exact image, so it is the target composition, not merely an"
          + " inspiration: match its placement, relative sizes, spacing, and overlap. Where the"
          + " assembled render disagrees with it, the render is wrong and the reference is right."
          + " Reproducing an overlap it shows — a title arcing over a head, a badge sitting on a"
          + " shoulder — is the correct outcome, not a collision to separate. It is a still frame,"
          + " so ignore any difference that is only a moment of the animation, and do not try to"
          + " reproduce detail that lives inside a layer's own artwork."
        : "",
    ].filter(Boolean).join(" "),
    messages: userTurn([
      `Approved design intent:\n${input.instruction}`,
      hasPlanImage
        ? "The approved static reference is available through view_plan_image. Inspect it there;"
          + " it is the composition this build is meant to reproduce."
        : "",
      input.animationSummary
        ? "The attached image is the approved illustrated animation summary. Use its labelled poses and expressions as a visual motion reference when reviewing configurations. The static image from view_plan_image remains the composition and character-design reference. Do not reproduce the storyboard panels, labels, arrows or background in the sticker. The structured plan defines timing and available controls."
        : "",
      `Current layer summary:\n${JSON.stringify(summarizeDocument(input.document))}`,
      `Conservative geometry diagnostics:\n${JSON.stringify(layoutDiagnostics(input.document))}`,
      attachedImagesNote(references.length),
      `Recoverable project context:\n${input.history}`,
    ].filter(Boolean).join("\n\n"), [
      ...(input.animationSummary ? [await downscaleForModelInput(input.animationSummary.bytes)] : []),
      ...references,
    ], input.presetReferences),
    tools,
    toolChoice: "required",
    stopWhen: [hasToolCall("finalize_layout"), stepCountIs(Math.max(hasPlanImage ? 9 : 8, configurationCount * 2 + 8)), () => fatal !== undefined],
    maxRetries: 2,
    abortSignal: AbortSignal.timeout(Math.max(120_000, configurationCount * 20_000)),
  });
  await recordTextApiCost(generation);

  if (fatal) throw fatal;
  return state;
}

export async function planSticker(
  input: AiPlanContext,
  session: PlanDraftingSession,
): Promise<PlanTurnResult | undefined> {
  // Threaded through the tool bodies rather than read off the result, because the model refers to
  // the plan by id on every subsequent call and only the session knows the id it was given.
  let state: PlanTurnResult | undefined;
  const reusable = reusableAssetIds(input.document);
  // Prior art first and attachments after, because both notes below describe the images by their
  // position in the message and `userTurn` appends them in this order.
  const priorArt = await viewablePlanVisuals(input.priorArt);
  const viewable = await viewableReferences(input.references);

  const requirePlan = (planId: string) => {
    if (!state)
      throw new Error("Call create_plan before any other plan tool");
    if (state.planId !== planId)
      throw new Error(
        `Unknown plan id ${planId}; the current plan is ${state.planId}`,
      );
    return state;
  };

  const tools = {
    ...createWebTools(),
    create_plan: tool({
      description:
        "Create the first draft of the plan. Call this exactly once, before any other plan tool.",
      inputSchema: z.object({ plan: PlanV1Schema }).strict(),
      execute: async ({ plan }) => {
        if (state)
          throw new Error(
            `A plan already exists (${state.planId}); use update_plan to change it`,
          );
        const created = await session.createPlan(plan);
        state = { ...created, finalized: false };
        return created;
      },
    }),
    update_plan: tool({
      description: [
        "Replace the whole draft with a revised version. Send the complete plan, not a patch.",
        "Use this to fix anything the schema rejected, to act on the user's feedback, or to",
        "improve the design after re-reading it.",
      ].join(" "),
      inputSchema: z
        .object({ planId: z.string().min(1), plan: PlanV1Schema })
        .strict(),
      execute: async ({ planId, plan }) => {
        const current = requirePlan(planId);
        const updated = await session.updatePlan(current.planId, plan);
        state = { ...updated, finalized: false };
        return updated;
      },
    }),
    show_plan: tool({
      description: [
        "Post the current draft into the chat so the user can see it. Optional — use it when you",
        "want the user to look at the design before you commit to it.",
      ].join(" "),
      inputSchema: z.object({ planId: z.string().min(1) }).strict(),
      execute: async ({ planId }) => {
        const current = requirePlan(planId);
        return session.showPlan(current.planId);
      },
    }),
    finalize_plan: tool({
      description: [
        "Finish planning and hand the plan to the user to confirm. Call this once you are",
        "satisfied with the design. For an animated plan, this first renders the static visual",
        "reference the user will approve; separate animation parts are not generated until then.",
      ].join(" "),
      inputSchema: z.object({ planId: z.string().min(1) }).strict(),
      execute: async ({ planId }) => {
        const current = requirePlan(planId);
        const finalized = await session.finalizePlan(current.planId);
        state = { ...finalized, finalized: true };
        return finalized;
      },
    }),
  };

  const generation = await generateText({
    // Feeds the chat screen's live token meter; see `reportAiStepUsage`.
    onLanguageModelCallEnd: reportAiStepUsage,
    model: gateway(process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
    system: [
      input.presetGuidance ?? "",
      WEB_RESEARCH_PROMPT,
      "You design stickers as a set of independent layers, then hand the design to the user.",
      "Work in this order: call create_plan once, revise with update_plan as many times as you need,",
      "optionally call show_plan, and finish by calling finalize_plan. Never call create_plan twice.",
      "If a tool returns an error, read it and fix the plan with update_plan — the error text says",
      "exactly what was wrong. Do not give up and do not repeat the same invalid plan.",
      "",
      "Static visual reference. For every animated plan, set conceptPrompt to a complete prompt",
      "for one polished still image of the finished sticker in its resting pose. It must include",
      "all planned layers in their intended layout, use one coherent style, fill the square frame,",
      "and show no animation frames, contact sheet, labels, arrows, watermark, or UI. The user",
      "approves this image before the generated artwork is separated into independent parts, so",
      "it is the visual source of truth for style, colour, proportions, and composition.",
      // The excluded list above is annotation — the scaffolding of a storyboard, not the sticker.
      // Read as "no text at all" it would strip the very lettering the plan then asks a generate
      // layer to lift out of this image, which leaves that layer with no source.
      "Lettering the sticker itself carries is not on that list: if the design has words, the",
      "conceptPrompt spells them out and describes how they are drawn, so the approved image is",
      "the source the word layer is separated from.",
      "When the plan has sprite layers, the conceptPrompt describes each character's face exactly as",
      "that layer's `face` field does — every facial feature inside that one region and none anywhere",
      "else on the body — because the approved still is what the sprite sheets are drawn from.",
      "Each sprite clip must set faceCompositing. Use `masked` whenever a hand, cup, instrument,",
      "hair strand, prop, or other foreground artwork crosses the face; use `overlay` only when the",
      "entire face opening stays unobstructed in every frame.",
      "",
      "Likeness. The photos the user uploaded to this project are handed to the image model along",
      "with your conceptPrompt and your layer prompts, on every turn, including turns where the",
      "user attached nothing new. So write those prompts to *point at* the reference rather than to",
      "replace it: say \"the person in the supplied reference photo\", and keep the description to",
      "what the picture cannot say for itself — the sticker style, the crop, the pose, the palette.",
      "A written description cannot carry a face. \"Short tousled black hair, rectangular dark grey",
      "glasses, fair warm skin\" fits thousands of people, and a prompt built out of clauses like",
      "that returns a stranger who matches the words. Never re-describe a real person's features",
      "in place of the reference, and never let a later turn's prompt drift further from the photo",
      "than the first turn's did: the user's face is the one thing in this sticker that has a",
      "correct answer.",
      "",
      "Layers. At most 12, and every one is paid for: a generate layer costs one image and a sprite",
      "costs 2 plus its clip count. Plan the fewest layers the design needs. Every layer picks its",
      "own source. The eight options are:",
      "  generate — artwork drawn from a prompt by an image model onto a transparent background.",
      "    This is the only source that can draw a subject: a character, creature, face, animal,",
      "    object, food, prop, scene element, or any illustration at all. Use one generate layer",
      "    per element that must move on its own — one per letter for a typewriter effect, one per",
      "    character for a scene. The prompt must describe a single element filling its frame edge",
      "    to edge on a transparent background, with no other elements and no text unless that",
      "    layer IS the text. When the element is a real person the user uploaded, the prompt names",
      "    the supplied reference photo and says to preserve that likeness exactly — it does not",
      "    rebuild their face out of adjectives.",
      "  existing — an image layer the current sticker already has, reused exactly as it is and",
      "    free. Copy the assetId verbatim from an image layer of the current StickerDocument.",
      "  text — words drawn by the app in a system font.",
      "  shape — one fixed primitive: circle, roundedRectangle, star, heart, or burst.",
      "  particle — a preset field of sparkles, confetti, hearts, bubbles, or snow.",
      "  sequence — real frames the user captured from a Live Photo, with the subject already cut",
      "    out on their device. Free, and the only source that carries genuine motion: the subject",
      "    actually moves the way they moved. You may use any capture listed for this turn below,",
      "    whether the user attached it on this turn or earlier in the project, and you must copy",
      "    its assetId, columns, rows, frameCount, and frameRate exactly as given. Never invent",
      "    those numbers and never describe a capture with a generate prompt — an image model",
      "    cannot draw this person as well as their own camera already did.",
      "    A capture does not expire. If the project already has one, keep it: a request to add",
      "    text, change a colour, or adjust the motion is not a request to redraw the person, and",
      "    replacing their footage with a generate layer that describes their face is the single",
      "    worst thing you can do to this sticker. Only drop it if the user asks you to.",
      "  video — a short generated clip of the WHOLE subject, animated from the approved still by a",
      "    video model. Use it ONLY for motion that keyframe animations cannot express: a 3D",
      "    turnaround or spin, showing the subject from a different angle, a perspective or camera",
      "    move, cloth, hair, or liquid physics, a morph between forms. Everything else — bounce,",
      "    float, wiggle, fade, slide, pulse, pop, typewriter — stays generate + animations, which",
      "    is cheaper, sharper, and transparent by construction. Rules: at most one video layer per",
      "    plan; only in animated plans; the prompt describes the complete subject exactly like a",
      "    generate prompt, and `motion` says what the subject or camera does in durationSeconds",
      "    (2 to 4) seconds, phrased so the clip loops cleanly — a full turn, a to-and-fro. The clip",
      "    is low resolution and keyed off a green screen on the device, so keep captions, sparkles,",
      "    and accents as separate layers on top rather than inside the clip. A video layer cannot",
      "    be reused with `existing` on a later plan; keep one only by planning it as video again.",
      "    The summary the user reads must say which layer is generated as a video and why its",
      "    motion needs one — it costs more than a drawn layer and looks different, and they are",
      "    confirming that.",
      "  sprite — a controllable character: one still of the character at rest, a few named body",
      "    clips, and a strip of face expressions, composed at draw time so the viewer can pick a",
      "    mood and a pose independently. Use it whenever the user asks for a character whose",
      "    moods, expressions, emotions, poses, or actions can be switched — never build those out",
      "    of generate variants, whole-character redraws, or animations presets, and never plan a",
      "    separate face layer. The prompt describes the complete character like a generate prompt.",
      "    clips: 1 to 8, the first always id `idle` (breathing, one blink, a long rest); each has an",
      "    id, a label, a prompt saying what the body does frame by frame, and 1 to 8 frames — six is",
      "    the norm — each with a duration in seconds that you author: a loop runs 2 to 4 seconds,",
      "    holds are long (1 to 2.5 s), a blink is 0.15 to 0.3 s, and frame 1 is the resting pose the",
      "    loop returns to. Clips move the body only; the face is drawn separately into the face region.",
      "    face: one sentence naming the single contiguous region that holds ALL of the character's",
      "    facial features, and what is in it. The build cuts exactly one oval out of the body there and",
      "    draws every expression inside it, so the design must put the eyes AND the mouth (and nose and",
      "    brows, if any) in that one area — never split them, such as eyes on a windshield and a mouth on",
      "    a bumper. An animal or a person simply names its face; a vehicle, robot, object or food picks",
      "    one surface (a windshield, a screen, a front panel) and carries the whole face on it, while",
      "    grilles, bumpers, badges and panels elsewhere carry no facial features at all.",
      "    expressions: 1 to 8 faces, the first always id `neutral`; each has an id, a label, and a",
      "    prompt for the face alone — eyes, brows, mouth, cheeks — all inside the face region; never",
      "    the body or a pose.",
      "    A sprite costs 1 + clips + 1 image generations, cannot be reused with existing on a later",
      "    plan (plan it as sprite again with the same ids), and is only for animated plans. Plan one",
      "    sprite layer per character the user wants to control — two characters are two sprite",
      "    layers, each with its own clips, expressions, and controls, and each paying that cost",
      "    again. The summary says which characters are controllable and how many clips and",
      "    expressions each has.",
      "Animated visual fidelity. In an animated plan, every new visible element must use generate,",
      "including styled lettering, bursts, stars, underlines, badges, and decorative accents. The",
      "approved static image is later separated into these generated layers, which is how the final",
      "sticker keeps its exact silhouettes, outlines, bevels, shadows, highlights, and texture.",
      "A video layer is separated from the approved image the same way and then animated, so it",
      "counts as generated artwork here.",
      "Never use text, shape, or particle in an animated plan: those are generic app-rendered",
      "primitives and will not match the approved image.",
      // Words are the case the planner reaches for a primitive on hardest, because a `text` layer
      // looks like the obvious tool for them. It is the wrong one here: an animated sticker's
      // lettering is part of the artwork, and a system font dropped on top of drawn artwork reads
      // as a caption bolted onto someone else's picture.
      "Words are artwork. Lettering in an animated sticker is drawn by the image model, never set",
      "in a system font: give it a generate layer whose prompt spells the exact words and says how",
      "they look — the typeface's character, weight, colour, outline, shadow, and any bevel, gloss",
      "or glow — on a transparent background. The words must also appear, spelled identically, in",
      "the conceptPrompt, or the approved image will have nothing for that layer to be separated",
      "from. A `text` layer is a last resort in an animated plan and needs a reason the drawn",
      "version could not work.",
      "The exception to app-rendered primitives is a plan led by a sequence layer: there is no",
      "generated image for anything to match, so shape and particle layers are welcome around a",
      "capture and are usually what makes it a sticker. Lettering still prefers generate even",
      "there, because a drawn word carries the outline, gloss and shadow that make it read as a",
      "sticker and a system font cannot. Know what that costs: adding any generated layer puts a",
      "capture-led plan back on the concept path, so the user is asked to approve a rendered still",
      "of their own footage before the build. Worth it for lettering the design is built around;",
      "not worth it for an incidental word, which may stay a text layer.",
      "Keep a word or phrase together in one",
      "generated layer unless parts of it genuinely need independent motion. Existing image layers",
      "may still be reused when revising artwork that must remain pixel-identical.",
      "For static plans, prefer text, shape, and particle for simple lettering, flat accents, and",
      "effects: they cost nothing and stay crisp at any size. That preference stops at illustration.",
      "A shape is a plain filled silhouette and a particle preset is a scatter of dots, so neither",
      "is ever a stand-in for",
      // Left to itself the planner reads "prefer the free sources" as "never generate", and returns
      // plans made entirely of primitives — a design with no artwork in it at all, which is not
      // what a user who asked for a sticker of something wants.
      "drawn artwork. If the request names or implies anything that has to be drawn, at least one",
      "layer must use generate; do not approximate a subject out of primitives.",
      "",
      // Without this the planner treats every request as a blank page and re-plans the sticker
      // from nothing — so "remove the old text" comes back as eight fresh layers, five of them
      // paid redraws of artwork the user was already happy with and none of which will look the
      // same twice. Reuse is the whole reason `existing` is a source.
      "Revising a sticker. When there is a current StickerDocument you are editing that sticker,",
      "not designing a new one. Start from the layers it already has: carry each one over with the",
      "same layerId, name, position, scale, rotation, and animations, and change only what the",
      "user asked you to change. Drop a layer to remove it and add one to introduce something new.",
      "Every image layer you keep must use the existing source with that layer's own assetId —",
      "never a generate layer describing the same artwork. Redrawing a layer the request did not",
      "touch costs the user money and comes back looking different, which reads as the sticker",
      "changing behind their back. Use generate only for artwork that is genuinely new, or that",
      "the user asked to have redrawn.",
      "",
      "Text layers, on the static plans that may still use them. Give them equal scaleX and scaleY:",
      "a glyph is fitted inside its box without stretching, so unequal values only shrink it. Size a",
      "text layer by the box you want the words to occupy, not by their letter count.",
      "",
      // Generated artwork is a square PNG drawn to fill its frame, so a wide box used to stretch
      // it. The build now fits the artwork inside the box instead, which makes an unequal pair
      // silently equal to its smaller half — say so, or a wide caption is planned as a wide box
      // and arrives a third of the size that was intended.
      "Image layers keep their aspect. generate, existing, and sequence layers hold square artwork",
      "that is fitted inside its box rather than stretched to fill it, so give them equal scaleX",
      "and scaleY too. An unequal pair is built as the smaller of the two, which makes a wide,",
      "short box a small square. To get a wide caption, ask the prompt for wide lettering inside a",
      "square frame and give the layer one square box big enough to hold it.",
      "For a staged text reveal, split the phrase into at most 6 chunks and prefer whole words —",
      "generated chunks in an animated plan, text chunks in a static one:",
      '"Hello World" is two layers, not eleven. A plan may use at most 12 layers, so one layer',
      "per letter only works for very short words, and cramming a phrase into it produces uneven",
      "spacing and unreadably small type. Lay the chunks out left to right with each chunk's width",
      "roughly proportional to its length so the spacing between them looks even, and leave a",
      "visible gap between neighbouring chunks or the words run together into one string.",
      "",
      "Controllable characters. When the user asks for moods, expressions, poses, or actions they can",
      "switch between, set configuration.controls and configuration.variants against each sprite layer.",
      "Every sprite gets its own controls, and a control acts on exactly one sprite: a pose choice",
      "control whose option ids are that sprite's clip ids, with one variant per option binding",
      "{ layerId, clip }; and a mood choice control whose option ids are that sprite's expression ids,",
      "with one variant per option binding { layerId, expression }. With one character name the",
      "controls `pose` and `mood`. With several, give each its own control ids and labels naming the",
      "character — `catPose` labelled \"Cat pose\", `dogMood` labelled \"Dog mood\" — so the viewer can",
      "tell the rows apart; bind one control to two sprites only when the user asked them to change",
      "together. Every sprite you plan must be bound by at least one control: a character the viewer",
      "can see but cannot pose is a bug, not scenery. Never bind source or animations on a",
      "sprite. Add a number control bound to speed (0.25 to 2) when the user wants to slow or hurry",
      "the animation, and toggles binding layerIds visibility for accessory layers. Choice controls",
      "name stable option ids; every option in a control binds the same properties; at most 64",
      "combinations per character, so keep each one to about 4 moods and 3 poses. Two characters at",
      "that size are fine — the budget is per character, not per sticker. Accessory layers that are not a",
      "character keep the older variant sources: base for unchanged artwork, generate for a redrawn",
      "still, frames for a registered sprite animation, existing for reusable still artwork, sequence",
      "with its unchanged grid for an already approved animated variant, and an animations patch to",
      "swap a layer's motion presets. Do not create controls unless requested or already present, and",
      "preserve existing control, option, clip, and expression ids during revisions.",
      "",
      "Layout. x and y are the layer's normalized centre (0,0 is top-left, 1,1 is bottom-right).",
      // Nothing else in this prompt says what the order of `layers` means, and a planner that
      // lists the hero first and its glow second has, without knowing it, hidden the hero.
      "Layer order is stacking order: the first layer in layers is drawn at the back and the last",
      "on top. List backgrounds, glows and bursts first, the main subject next, and anything that",
      "must read over it — badges, lettering, sparkles — last.",
      // The renderer fits every layer into a box of 0.86 * canvas before applying scale, so the
      // planner's numbers are not a direct fraction of the canvas. Say so or layouts overlap.
      "scaleX and scaleY are relative to a box covering 86% of the canvas, so 0.4 is roughly a third",
      "of the width. Lay layers out so their boxes do not overlap, and keep each one fully on canvas.",
      // Left to itself the planner clusters everything near the centre at small scales, which
      // renders as a few tiny elements marooned in transparency. A sticker has to read at
      // thumbnail size in a message bubble.
      "Fill the frame. A sticker is viewed small, so the design must use most of the canvas:",
      "together the layers should span roughly the full width or height, not a patch in the middle.",
      "For a row of N elements across the canvas, each one wants scaleX near 1/N — two letters are",
      "about 0.5 wide each, not 0.2. Scale up until the layout nearly touches the edges, then stop.",
      "Small scales are for genuine accents such as a sparkle or a caret, never for the main subject.",
      "",
      "Motion. Each layer carries a list of named animations, every one with a delay and a duration",
      "in seconds. Stagger a sequence by giving each layer a larger delay — that is how a typewriter",
      "reveal is built. Two animations on the same layer must not overlap in time if they drive the",
      "same property: fadeIn/fadeOut/popIn/popOut/slideIn/slideOut all drive opacity, popIn and pulse",
      "and scaleTo drive scale, spin and wiggle and rotateTo drive rotation, and slideIn/slideOut and",
      "moveTo/arcTo and bounce and float all drive position.",
      "Every animation must finish within the sticker's duration (delay + duration <= durationSeconds).",
      "Static stickers cannot carry any animations at all.",
      "Reveals and light. wipeIn/wipeOut/wipeTo uncover or cover a layer along an axis — wipeIn takes",
      "the direction the reveal travels and a softness for how hard the edge is. They work on every",
      "layer including images and text, which is what makes them the way to reveal a photo or a word",
      "edge-to-edge; drawOn/drawOff/trimTo only ever affect a stroked shape or an SVG.",
      "shine sweeps a bright band across a layer for gloss or polish, and ignores its easing because",
      "the band has to move at a constant speed; repeat it with cycles rather than with two shines.",
      "bloomIn/bloomOut/bloomPulse are glow — the layer stays sharp and sheds a halo of its own",
      "colours — for anything magical, hot or neon. Each of these three families drives a property of",
      "its own, so they can overlap each other and any of the animations above; only two wipes, or",
      "two shines, or two blooms on one layer need separating in time.",
      // moveTo is two keyframes blended linearly, so nothing can bend it into an arc. Without this
      // paragraph every thrown or falling subject came back travelling along a ruler.
      "Curves. moveTo travels in a dead straight line, which looks mechanical for anything thrown,",
      "tossed, swooping or falling. Use arcTo instead: same destination, but it bows along a parabola",
      "by arcHeight canvas units at the midpoint — positive arcs over the top, negative sags under,",
      "0.2-0.4 is a natural throw, and giving it the layer's own x/y makes a straight-up toss.",
      "Every animation departs from the layer's resting x/y rather than from where the previous one",
      "ended, so a layer gets at most one moveTo or arcTo; a second is rejected.",
      // Easing went unmentioned here for long enough that every stored spec sits on the default.
      "Easing. Every animation takes linear, easeIn, easeOut, easeInOut (the default), springSoft or",
      "springBouncy, and it does more for how the sticker feels than any other number. Entrances want",
      "easeOut or a spring, exits want easeIn, a full-frame spin wants linear. wiggle, pulse and float",
      "must use linear: they compile to a sampled sine and any other easing eases each sample on its",
      "own, which makes them stutter. arcTo wants linear too, unless the throw should slow into its",
      "landing.",
      "",
      "",
      "The user can edit the sticker directly in the on-device editor between turns, and the history",
      "shows that as a bracketed system note. When you see one, the current StickerDocument above",
      "already contains their edit: plan from that document rather than from anything earlier in the",
      "conversation, and keep what they changed unless the new request is specifically to undo it.",
      "",
      "The summary is shown to the user as your chat message: one or two friendly sentences.",
    ].join("\n"),
    messages: userTurn([
      `Sticker kind: ${input.stickerKind}`,
      // Also enforced deterministically: `create_plan` and `update_plan` strip travelling specs
      // when this is off. Said here anyway so the plan the user reads matches what gets built.
      input.stickerKind === "animated" && !input.motion
        ? "This sticker stays put. Give no layer a float, bounce, moveTo or arcTo: the subject rests"
          + " in one place and acts there. It may still breathe, blink, tilt, squash, pulse, wiggle,"
          + " turn, or change expression — everything except travelling around the canvas. For a"
          + " sprite, the idle clip is a resting pose that holds its spot rather than drifting,"
          + " hovering or bobbing across its frames. Do not describe the sticker as floating,"
          + " flying, hovering or moving around in the summary."
        : "",
      input.stickerKind === "animated" && input.motion
        ? "The user asked for this sticker to move around: the subject may travel across the canvas."
          + " Keep it inside the frame at the end of the loop so it does not jump when the loop"
          + " repeats."
        : "",
      input.posePreset
        ? `Pose variety: ${input.posePreset}. Create exactly ${POSE_COUNTS[input.posePreset]} distinct selectable body clips per character, including idle. This overrides the default pose-count suggestion. Add meaningful actions suited to the subject when increasing; keep retained clip IDs when decreasing. Give every clip a pose option and variant binding. This changes the number of clips, not frames or moods. Preserve the current plan's subject, look, composition, moods and timing unless the user asks otherwise. Describe this setting using its preset label, without raw pose counts.`
        : "",
      // The switch in the create screen, not a sentence the user typed — so it is stated as a
      // requirement of the project rather than left for the model to infer from their wording.
      // `create_plan` enforces the same rule and hands back a repair instruction if it is ignored.
      input.controllable
        ? "This project is controllable: the user asked for characters whose mood and pose they can"
          + " switch from the sticker itself. Plan one sprite layer per character their request calls"
          + " for — one for a single subject, one each when they name several. If their words imply a"
          + " pair (a cat and a dog, two friends, a couple), that is two sprites, not one drawing of"
          + " both, because a group drawn as one sprite cannot be posed apart. Give each the clips and"
          + " expressions its own subject calls for, set each sprite's face to the one region all of its"
          + " facial features share, and give every one of them a mood control, a pose"
          + " control, or both. Everything else about the sticker still follows their request."
        : "",
      // The converse of the clause above, and just as much a project requirement. Without it the
      // sprite guidance further up — "use it whenever the user asks for a character whose moods,
      // expressions, poses or actions can be switched" — read as permission to build one from the
      // wording alone, and a request like "a cat that waves and smiles" quietly became a sprite
      // that costs several extra generations. `create_plan` rejects one if it is ignored.
      !input.controllable
        ? "This project is NOT controllable: the user left the moods-and-poses switch off. Plan no"
          + " sprite layers and no clip or expression bindings, however much their wording sounds"
          + " like switchable moods, poses or actions — the switch is their answer and it overrides"
          + " what the request implies. Draw each character once, with generate, in the single pose"
          + " the request describes, and express what it does with animations. Controls that hide a"
          + " layer or change text are still allowed. Do not mention the switch or offer to turn it"
          + " on; just plan the sticker they asked for."
        : "",
      priorArtNote(priorArt),
      attachedImagesNote(
        viewable.length,
        "Read them for the subject, likeness, style, and colours the user wants, and write the"
        + " layer prompts around what you can actually see in them."
        + (input.sequenceAssets.length > 0
          ? " One of them is the capture named below, laid out as a contact sheet: its frames read"
            + " left to right, top to bottom. Look at what the subject actually does across them"
            + " and design the sticker around that movement."
          : ""),
      ),
      input.baseRevisionId ? `To extend this sticker, set baseRevisionId to ${input.baseRevisionId}. List ONLY added or explicitly replaced layers. Unlisted layers and their complete artwork and motion survive unchanged. Use configurationChanges with upsertControls, upsertVariants, removeControlIds and removeVariantIds; do not send configuration. Preserve existing ids and untouched bindings in upserted variant rows. New captions can bind text or hidden; artwork choices use generate sources. Captions alone can have an empty layers list. Do not repeat existing sprites to preserve them: that would pay to redraw them. Native text overlays are allowed in extension plans. Keep the original timing unless the additions require more time.` : "",
      input.document
        ? `Current StickerDocument: ${JSON.stringify(input.document)}`
        : "There is no current sticker document.",
      // Pulled out of the document JSON it is already sitting in: this is the one list the model
      // has to copy from exactly, and it should not have to find it among the keyframes.
      reusable.length > 0
        ? `Artwork you can reuse with an existing source — copy these assetIds exactly:\n${reusable
            .map((assetId) => `- ${assetId}`)
            .join("\n")}`
        : "",
      // Spelled out as fields rather than left for the model to read off the contact sheet it can
      // see: the grid was fixed when the atlas was encoded on device, and a plan that guesses it
      // wrong slices the footage into the wrong frames.
      // Not "attached to this turn": these are every capture the project has, carried forward from
      // whichever turn it arrived on. A capture that is only legal on the turn it was uploaded is
      // a capture the next turn has to replace with a drawing of the user's face.
      input.sequenceAssets.length > 0
        ? "This project has captured footage of the user, already cut out — attached on this turn "
          + "or earlier in the conversation, and available to you either way. Make it the hero "
          + "layer with a sequence source and build the sticker around it; if a previous plan "
          + "already used it, keep using it. Copy these fields "
          + `exactly:\n${input.sequenceAssets
            .map((asset) => `- assetId ${asset.assetId}, columns ${asset.columns}, rows ${asset.rows}, `
              + `frameCount ${asset.frameCount}, frameRate ${asset.frameRate}`)
            .join("\n")}`
        : "",
      // Extension plans retain complete sprites. Only explicit replacements need their declarations.
      (input.document?.layers ?? []).some((layer) => layer.type === "sprite")
        ? "The current sticker has controllable characters. Keep unchanged characters out of an extension plan's layers. For a character explicitly being replaced, preserve its layerId, clip ids and expression ids, changing only what "
          + `the user asked for:\n${(input.document?.layers ?? []).flatMap((layer) => (layer.type === "sprite"
            ? [`- layer ${layer.id}: clips ${layer.clips.map((clip) => clip.id).join(", ")}; expressions ${layer.expressions.tiles.map((tile) => tile.id).join(", ")}`]
            : [])).join("\n")}`
        : "",
      input.rejectedReasons.length > 0
        ? `The user already turned down earlier plans for these reasons — do not repeat them:\n${input.rejectedReasons
            .map((reason) => `- ${reason}`)
            .join("\n")}`
        : "",
      `Recoverable chat history:\n${input.history}`,
      `Latest user request:\n${input.instruction}`,
    ]
      .filter(Boolean)
      .join("\n\n"), [...priorArt.map((visual) => visual.image), ...viewable], input.presetReferences),
    tools,
    toolChoice: "required",
    // The heaviest of the three loops: `update_plan` is a complete `PlanV1` every time, so twelve
    // steps of revision is twelve whole designs sitting in the context.
    prepareStep: compactingPrepareStep({ loop: "plan" }),
    // The model ends the turn by calling finalize_plan. The step cap is the backstop for a model
    // that keeps polishing forever; the caller finalizes whatever draft exists when it trips.
    stopWhen: [hasToolCall("finalize_plan"), stepCountIs(12)],
    maxRetries: 2,
    abortSignal: AbortSignal.timeout(180_000),
  });
  await recordTextApiCost(generation);

  return state;
}
