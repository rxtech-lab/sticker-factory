// The animation turn: keyframing a document the user has already accepted.

import { createWebTools, WEB_RESEARCH_PROMPT } from "./web-tools";
import { gateway } from "@ai-sdk/gateway";
import { generateText, stepCountIs, tool } from "ai";
import { z } from "zod";
import { compactingPrepareStep } from "@/lib/ai/compaction";
import { recordTextApiCost, reportAiStepUsage } from "@/lib/ai/cost";
import { viewStickerTool } from "@/lib/ai/view-sticker-tool";
import { AnimationOperationsSchema, describeToolError, isTurnAbort, summarizeDocument } from "./gateway-contracts";
import type { AiAnimationContext, AnimateTurnResult, AnimationDraftState, AnimationDraftingSession } from "./gateway-contracts";
import { attachedImagesNote, userTurn, viewableReferences } from "./gateway-models";

export async function animateSticker(
  input: AiAnimationContext,
  session: AnimationDraftingSession,
): Promise<AnimateTurnResult | undefined> {
  // Threaded through the tool bodies rather than read off the result, because the model refers to
  // the animation by id on every subsequent call and only the session knows the id it was given.
  let state: AnimateTurnResult | undefined;
  const viewable = await viewableReferences(input.references);
  // Set when the session fails for a reason the model cannot fix. Not thrown from the tool body:
  // the SDK converts every `execute` throw into a tool-error part and keeps going, so the loop has
  // to be stopped from the outside and the real error rethrown after it unwinds.
  let fatal: unknown;

  const guard = async (run: () => Promise<AnimationDraftState>) => {
    try {
      return await run();
    } catch (error) {
      if (isTurnAbort(error)) {
        fatal = error.reason ?? error;
        throw new Error(
          "This animation turn has been stopped. Do not call any more tools.",
        );
      }
      throw new Error(describeToolError(error));
    }
  };

  // The SDK runs every tool call of a step concurrently, and the model often sends a fix and
  // finalize_animation together. Finalize used to read the state before the fix settled: it
  // succeeded on the old revision, ended the loop, and the fix's rejection was never answered.
  // So finalize waits for its siblings and refuses while the latest change is a rejected one.
  const pendingEdits = new Set<Promise<unknown>>();
  let rejectedEdit: string | undefined;
  const edit = <Input, Output>(execute: (input: Input) => Promise<Output>) => (input: Input) => {
    const run = execute(input).then(
      (output) => { rejectedEdit = undefined; return output; },
      (error: unknown) => { rejectedEdit = error instanceof Error ? error.message : String(error); throw error; },
    );
    pendingEdits.add(run);
    return run.finally(() => pendingEdits.delete(run));
  };

  const requireAnimation = (animationId: string) => {
    if (!state)
      throw new Error(
        "Call create_animation before any other animation tool",
      );
    if (state.animationId !== animationId) {
      throw new Error(
        `Unknown animation id ${animationId}; the current animation is ${state.animationId}`,
      );
    }
    return state;
  };

  const tools = {
    ...createWebTools(),
    view_sticker: viewStickerTool(session, { animated: true }),
    create_animation: tool({
      description:
        "Apply your first set of operations to the sticker. Call this once, before any other animation tool.",
      inputSchema: z
        .object({ operations: AnimationOperationsSchema })
        .strict(),
      execute: edit(async ({ operations }) => {
        // Only reachable after a *successful* create, so a rejected one may simply be retried.
        if (state)
          throw new Error(
            `An animation already exists (${state.animationId}); use update_animation to change it`,
          );
        const landed = await guard(() => session.createAnimation(operations));
        state = {
          animationId: landed.animationId,
          revision: landed.revision,
          finalized: false,
        };
        return {
          ...state,
          sticker: summarizeDocument(landed.document),
        };
      }),
    }),
    update_animation: tool({
      description: [
        "Replace the whole animation with a revised set of operations. Send every operation you",
        "want the sticker to have, not just the one you are changing: an update is applied to the",
        "original sticker, never stacked on your previous attempt.",
        "Use this to fix anything a tool rejected, to act on the user's feedback, or to improve",
        "the timing after re-reading it.",
      ].join(" "),
      inputSchema: z
        .object({
          animationId: z.string().min(1),
          operations: AnimationOperationsSchema,
        })
        .strict(),
      execute: edit(async ({ animationId, operations }) => {
        const current = requireAnimation(animationId);
        const landed = await guard(() =>
          session.updateAnimation(current.animationId, operations),
        );
        state = {
          animationId: landed.animationId,
          revision: landed.revision,
          finalized: false,
        };
        return {
          ...state,
          sticker: summarizeDocument(landed.document),
        };
      }),
    }),
    edit_layer_animation: tool({
      description: [
        "Change the motion of one layer and leave every other layer's exactly as it is.",
        "Send only the operations for that layer — not the whole animation. They replace whatever",
        "that layer currently has, so send all of the motion you want it to end up with; every",
        "other layer keeps the motion it already has, and you do not have to restate it.",
        "This is the tool for a change to one part of a sticker that is otherwise right: 'start the",
        "hat a little later', 'the caption should fade instead of pop', 'lose the wiggle on the",
        "star'. To leave a layer still, send setLayerAnimations for it with an empty animations",
        "list.",
        "Use update_animation instead when you are reworking the whole animation, or when two",
        "layers' timing has to change together.",
      ].join(" "),
      inputSchema: z
        .object({
          animationId: z.string().min(1),
          layerId: z.string().min(1).max(64),
          operations: AnimationOperationsSchema,
        })
        .strict(),
      execute: edit(async ({ animationId, layerId, operations }) => {
        const current = requireAnimation(animationId);
        const landed = await guard(() =>
          session.editLayerAnimation(current.animationId, layerId, operations),
        );
        state = {
          animationId: landed.animationId,
          revision: landed.revision,
          finalized: false,
        };
        return {
          ...state,
          sticker: summarizeDocument(landed.document),
        };
      }),
    }),
    finalize_animation: tool({
      description: [
        "Finish and show the animation to the user. Call this once you are satisfied with the",
        "motion. Only the finalized animation is shown, so nothing you did before it is visible.",
      ].join(" "),
      inputSchema: z.object({ animationId: z.string().min(1) }).strict(),
      execute: async ({ animationId }) => {
        // Let the step's other calls start, then settle, before judging what there is to finalize.
        await new Promise((resolve) => setTimeout(resolve, 0));
        await Promise.allSettled([...pendingEdits]);
        if (rejectedEdit) {
          throw new Error(`Not finalized: your last animation change was rejected (${rejectedEdit}). Fix it with update_animation or edit_layer_animation, then call finalize_animation on its own.`);
        }
        const current = requireAnimation(animationId);
        const landed = await guard(() =>
          session.finalizeAnimation(current.animationId),
        );
        state = {
          animationId: landed.animationId,
          revision: landed.revision,
          finalized: true,
        };
        return {
          ...state,
          sticker: summarizeDocument(landed.document),
        };
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
      "You add motion to an existing sticker by applying operations to its document.",
      "Work in this order: call create_animation once with your first operations, refine with",
      "update_animation or edit_layer_animation as many times as you need, and finish by calling",
      "finalize_animation. Only",
      "the finalized animation is shown to the user, so nothing in between is wasted or visible.",
      "update_animation is a restatement, not a patch: it is applied to the original sticker, so",
      "send every operation you want the finished animation to have, every time.",
      // Restating an 8-layer animation to move one delay is where layers get dropped, and a dropped
      // layer is silently un-animated rather than an error the loop can see and repair.
      "edit_layer_animation is the same thing scoped to one layer: it swaps out that layer's",
      "operations, keeps every other layer's, and re-applies the result to the original sticker.",
      "Prefer it whenever the change is to one layer and the rest of the animation is already right.",
      "If a tool returns an error, read it and fix it. The compiler names the offending specs, the",
      "layer, the channel they share, and the seconds involved, so the error text says exactly what",
      "to change. If create_animation failed there is no animation to update yet — call",
      "create_animation again with the fix. If it succeeded, fix it with update_animation, or with",
      "edit_layer_animation when the error names a single layer. Do not",
      "give up and do not repeat the same rejected operations.",
      "",
      // The transcript marks these rows explicitly (see `lineFor` in lib/ai/compaction), but the
      // marker only helps if the model knows to act on it. Without this paragraph the loop plans
      // against the document it remembers producing and silently undoes the user's own edit.
      "The user can edit the sticker directly in the on-device editor between your turns, and the",
      "transcript shows that as a bracketed system note saying they did. When you see one, the",
      "sticker has been changed by someone other than you: the StickerDocument you are given below",
      "is the up-to-date one and already includes their edit. Read it before you decide anything,",
      "treat it as the truth over your own memory of what you last produced, and build on top of",
      "their change rather than reapplying operations that would revert it. If their edit already",
      "achieves what the request asked for, say so instead of redoing it.",
      "",
      // The loop had no way to see its own work before this tool existed, so every instruction
      // about motion was being followed blind. Saying "look before you finalize" explicitly is
      // what turns the tool from available into used.
      "Look at what you have made. view_sticker returns a contact sheet of frames across the",
      "cycle, and it is the only way to actually see the motion rather than re-reading the numbers",
      "you just wrote. Call it after your first set of operations and again before finalizing, and",
      "fix what it shows you: a layer that never appears because its entrance runs past the end, a",
      "layer still off-canvas in the last frame, two layers landing on top of each other, an idle",
      "so small it reads as nothing. It costs nothing and buys no artwork.",
      "Do not call it twice in a row without changing something in between — a second look at an",
      "unchanged sticker tells you what the first one did and spends a step you may need.",
      "It is a review render from the server, not the app's own: judge timing, position, coverage",
      "and colour from it, not the exact curve of a shape or the metrics of a font.",
      "",
      "Strongly prefer setLayerAnimations: it takes named effects with a delay and a duration in",
      "seconds, and the server compiles them into keyframes for you. Stagger layers by giving each a",
      "larger delay. The full vocabulary is:",
      "entrances and exits — fadeIn, fadeOut, popIn, popOut, slideIn, slideOut;",
      "moves — moveTo, arcTo, scaleTo, rotateTo, spin;",
      "idles — wiggle, pulse, bounce, float;",
      "effects — blurIn, blurOut, hueShift;",
      "stroke drawing — drawOn, drawOff, trimTo, which only do anything on a shape with a stroke or",
      "an SVG layer, and are how a signature, an outline, or an underline draws itself in;",
      "wipes — wipeIn, wipeOut, wipeTo, a directional reveal that masks the layer along an axis.",
      "Unlike the stroke-drawing effects these need no path, so they are how an image, a photo, or a",
      "word of text is revealed edge-to-edge. wipeIn takes a direction — the way the reveal travels,",
      "so right uncovers the layer starting at its left edge — and a softness, where 0 is a hard line",
      "and 0.2 is a soft gradient. wipeTo is the general form for angled or partial reveals;",
      "light — shine, bloomIn, bloomOut, bloomPulse. shine sweeps a bright band across the layer, the",
      "glint that reads as gloss or polish on a logo or a badge; give it a width, an intensity, and a",
      "cycles count if you want it to repeat. bloom is glow rather than a sweep: the layer stays sharp",
      "and sheds a halo of its own colours, for anything magical, hot, or neon. bloomPulse breathes it.",
      "",
      // Three separate channels precisely so these combinations are legal; saying so stops the model
      // sequencing them defensively and wasting the sticker's duration on effects that could overlap.
      "Wipes and light do not collide with anything else, so they layer freely over motion: a layer",
      "can wipeIn while it slides, and shine and bloom can run over each other and over a wipe at the",
      "very same instant. Two wipes, or two shines, still cannot overlap each other.",
      "shine ignores its easing — the band has to travel at constant speed or it reads as a stutter —",
      "so use cycles to repeat it rather than several shine effects back to back.",
      "",
      // moveTo compiles to two keyframes and the interpolator blends them linearly, so no easing
      // can bend it. Every "throw it across the screen" request used to come back as a layer
      // sliding along a ruler, which is the single most common complaint about the motion here.
      "Curved motion. moveTo travels in a dead straight line, which reads as mechanical for anything",
      "thrown, tossed, lobbed, swooped, or falling. Use arcTo for those: it goes to the same x/y but",
      "bows along a parabola. arcHeight is how far it bows at the midpoint, in canvas units,",
      "perpendicular to the travel — positive always arcs over the top, negative sags underneath, and",
      "0.2-0.4 reads as a natural throw. Giving it the layer's own x/y makes a straight-up toss that",
      "comes back down. An arcTo costs 11 of a layer's 32 keyframes.",
      // Every spec is compiled against the layer's anchor, not against where the previous spec left
      // it, so back-to-back moves collide on the boundary keyframe with a confusing error.
      "Every effect departs from the layer's resting x/y, not from wherever the last effect ended, so",
      "two moves cannot be chained on one layer: an arcTo or moveTo followed by another is rejected.",
      "One arc per layer. For repeated hops in place use bounce, and to move several things along",
      "different trajectories give each its own layer.",
      // x/y accept -1 to 2 so that entrances and exits can start and finish out of frame. Nothing
      // stops a plain move from using that room, and a looping sticker that ends out there snaps
      // back to its resting spot the instant the clock wraps.
      "Land on canvas. x and y may run from -1 to 2, but that room is for entrances and exits: a",
      "layer that is still visible outside 0-1 when the loop ends jumps back to its starting place",
      "as it repeats. Finish a move inside the frame, or pair it with a fadeOut so the layer is gone",
      "before it gets there.",
      "",
      // Neither prompt used to mention easing at all, so every spec landed on the easeInOut
      // default, including the sampled ones where it is actively wrong.
      "Easing. Every effect takes an easing: linear, easeIn, easeOut, easeInOut (the default),",
      "springSoft, or springBouncy. It matters more than the numbers do. Entrances want easeOut or a",
      "spring so they arrive with weight; exits want easeIn; a spin or a hueShift crossing the whole",
      "frame wants linear. Use springBouncy for anything playful landing into place.",
      "One case is worth memorising: wiggle, pulse and float compile to a sampled sine, and the",
      "easing is then applied to each sample on its own, so easeInOut brings the motion to a full",
      "stop four times a cycle — that is what makes them look stiff. Give those three linear, which",
      "leaves the sampled sine as the only curve in play. arcTo takes",
      "linear too unless you specifically want the throw to decelerate into its landing (easeOut),",
      "because a linear parameter over a parabola is exactly how a real thrown object moves.",
      // The rule was already here in the abstract and was still broken constantly, always the same
      // way: an entrance and an idle effect both starting at 0. Naming that case and showing the
      // arithmetic is what makes it stick.
      "Two effects on one layer must never overlap in time if they drive the same property, and",
      "every effect must finish within the sticker's duration. An entrance and an idle effect are",
      "the usual trap: popIn, fadeIn, slideIn, blurIn, scaleTo and pulse, bounce, float, wiggle,",
      "spin all drive scale or position, and slideIn, slideOut, moveTo, arcTo, bounce and float all",
      "drive position in particular. Sequence them — popIn with delay 0 and duration 0.5 means",
      "the pulse after it starts at delay 0.5, not 0. Two effects on different layers, or on the",
      "same layer driving different properties, may overlap freely — and the wipe, shine and bloom",
      "families each own a property of their own, so they never conflict with the effects above.",
      "Fall back to the raw setXKeyframes operations only for motion no named effect can express;",
      "their timeSeconds values are absolute seconds, never percentages or deltas, and they cannot",
      "be used on a layer that already has named animations.",
      "Look at what you have made. view_sticker renders the sticker as it currently stands and",
      "returns it as an image. Call it when you are unsure a change landed the way you meant, and",
      "before finalizing: it is how you catch a layer hidden behind another, a new layer placed",
      "off-canvas or at the wrong size, or artwork whose colours fight the ones already there.",
      "It costs nothing and generates no artwork, so it is never the expensive choice — but do not",
      "call it twice without changing anything in between.",
      "It is a review render from the server rather than the app's own, so judge layout, size,",
      "coverage and colour from it, never the fine detail of a glyph or a curve. Never redraw",
      "artwork just because an edge looks a little different there.",
      "You may add validated text, shape, or allowlisted particle layers. Do not add/remove image layers or replace assets. Do not emit Swift, JavaScript, URLs, shaders, expressions, or external asset identifiers.",
      // Narrower than the document contract allows on purpose: v2 documents can hold 12 layers
      // and run up to 30s, but those exist for a person editing directly. Handing the planner the
      // wider ranges would only give it more ways to be wrong.
      "Keep within the planner's limits of 8 layers and 128 keyframes, duration 0.5-4s, and FPS <=30,",
      "and at most 16 operations in any one call.",
    ].join(" "),
    messages: userTurn([
      `Base StickerDocument:\n${JSON.stringify(input.document)}`,
      attachedImagesNote(
        viewable.length,
        "They are about the motion, not the artwork: you cannot draw anything this turn, so read"
        + " them for how the user wants the sticker to move and keyframe the layers you have to"
        + " match.",
      ),
      input.targetLayerId
        ? `Animate only the layer with id ${input.targetLayerId}. Every operation you send must name it.`
        : "",
      `Recoverable chat history:\n${input.history}`,
      `Instruction:\n${input.instruction}`,
    ]
      .filter(Boolean)
      .join("\n\n"), viewable, input.presetReferences),
    tools,
    toolChoice: "required",
    // Every step appends a restatement of the whole animation and a layer-by-layer summary of what
    // it compiled to, so a loop that spends its step budget repairing timing is the one most likely
    // to outgrow its context.
    prepareStep: compactingPrepareStep({ loop: "animate" }),
    // The model ends the turn by calling finalize_animation. The step cap is the backstop for a
    // model that keeps polishing forever; the caller ships whatever landed when it trips.
    stopWhen: [
      // A finalize that landed, not merely the call: a rejected one must reach the model to fix.
      () => state?.finalized === true,
      // Raised from 10 when `view_sticker` landed: a loop that looks, fixes what it saw and looks
      // again spends three steps doing it, and the old budget left no room to act on the second
      // look before the loop was cut off.
      stepCountIs(14),
      () => fatal !== undefined,
    ],
    maxRetries: 2,
    abortSignal: AbortSignal.timeout(180_000),
  });
  await recordTextApiCost(generation);

  if (fatal) throw fatal;
  return state;
}
