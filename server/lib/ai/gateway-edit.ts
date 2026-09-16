// The edit turn, and the guards that keep a model's operations inside what it is allowed to
// change.

import { createWebTools, WEB_RESEARCH_PROMPT } from "./web-tools";
import { gateway } from "@ai-sdk/gateway";
import { generateText, hasToolCall, stepCountIs, tool } from "ai";
import { z } from "zod";
import { compactingPrepareStep } from "@/lib/ai/compaction";
import { recordTextApiCost, reportAiStepUsage } from "@/lib/ai/cost";
import { viewStickerTool } from "@/lib/ai/view-sticker-tool";
import { MAX_LAYER_INDEX, type StickerOperationV1 } from "@/lib/contracts/sticker";
import { ApiError } from "@/lib/http/errors";
import { layoutDiagnostics } from "@/lib/layout/composition";
import { EditOperationsSchema, describeToolError, isTurnAbort, summarizeDocument } from "./gateway-contracts";
import type { AiEditContext, EditDraftState, EditDraftingSession, EditTurnResult } from "./gateway-contracts";
import { IMAGE_TIMEOUT_MS, attachedImagesNote, userTurn, viewableReferences } from "./gateway-models";

export async function editSticker(
  input: AiEditContext,
  session: EditDraftingSession,
): Promise<EditTurnResult | undefined> {
  let state: EditTurnResult | undefined;
  // Set when the session fails for a reason the model cannot fix. Not thrown from the tool body:
  // the SDK converts every `execute` throw into a tool-error part and keeps going, so the loop has
  // to be stopped from the outside and the real error rethrown after it unwinds.
  let fatal: unknown;
  const viewable = await viewableReferences(input.references);

  const guard = async (run: () => Promise<EditDraftState>) => {
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
        throw new Error(
          "This edit turn has been stopped. Do not call any more tools.",
        );
      }
      throw new Error(describeToolError(error));
    }
  };

  const tools = {
    ...createWebTools(),
    view_sticker: viewStickerTool(session, {
      animated: input.document?.kind === "animated",
    }),
    edit_layers: tool({
      description: [
        "Change the layer stack: this is how layers are added, removed, reordered, renamed, and",
        "moved. It draws nothing and costs nothing, so it is the right tool for every request that",
        "does not need new artwork.",
        "addLayer adds a text, shape, or particle layer — send the whole layer object.",
        "Use text layers for app-rendered typography. Requests for cartoon or illustrated lettering",
        "belong to add_image_layer, which generates the lettering artwork.",
        "removeLayer deletes a layer outright. reorderLayer changes what sits in front of what:",
        "layers are drawn in array order, index 0 at the back and the last layer on top, and",
        "reorderLayer removes the layer then re-inserts it at index in the remaining list, so the",
        "last index puts it in front. renameLayer changes only the label.",
        "To change what a text layer says, or how any layer is styled, remove it and add the",
        "replacement in the same call at the same index, keeping the id, name, anchor, and",
        "animations you want it to carry over.",
        "To move, resize, or rotate a layer, send setLayerAnimations for it with its current",
        "animations and a new anchor — the anchor is where a layer rests, and this is the only",
        "operation that sets it.",
        "You cannot add an image layer or point one at a different asset here; artwork has to be",
        "drawn, so use add_image_layer and edit_image_layer for that.",
        "A sequence layer is real frames the user captured of themselves. You can move, resize,",
        "rotate, reorder, rename, retime, and animate one, and setSequencePlayback changes how the",
        "footage repeats. No tool can redraw it and you cannot add one — decorate around it.",
      ].join(" "),
      inputSchema: z.object({ operations: EditOperationsSchema }).strict(),
      execute: async ({ operations }) => guard(() => session.applyOperations(operations)),
    }),
    edit_image_layer: tool({
      description: [
        "Redraw one image layer's artwork from an instruction, keeping its place in the stack, its",
        "size, and its motion. The current artwork is given to the image model, so describe the",
        "change you want rather than the whole picture: 'make the hat red', not 'a cat in a red hat'.",
        "This is the only tool that can change artwork that already exists.",
        "It costs a real image generation and takes a while, so call it once per layer that",
        "genuinely has to change, and never to move, resize, rename, or delete something.",
      ].join(" "),
      inputSchema: z
        .object({
          layerId: z.string().min(1).max(64),
          prompt: z.string().trim().min(1).max(4_000),
        })
        .strict(),
      execute: async ({ layerId, prompt }) =>
        guard(() => session.editImageLayer({ layerId, prompt })),
    }),
    add_image_layer: tool({
      description: [
        "Draw one new element on a transparent background and add it to the top of the stack as its",
        "own image layer, leaving every existing layer untouched. Give it x, y, scaleX and scaleY",
        "for where it should sit, or omit them to have it placed in the largest free area of the",
        "canvas. The artwork is square and fitted inside its box, so send equal scaleX and scaleY;",
        "an unequal pair is applied as the smaller of the two.",
        "The prompt must describe a single element filling its frame edge to edge on a transparent",
        "background, with no other elements and no text unless that layer IS the text.",
        "For illustrated lettering, describe only the exact words and lettering style. Never ask",
        "for a sticker, a scene, or text placed on existing artwork: placement is handled by x and y.",
        "Use this tool for 'add cartoon text': generate a transparent image of only the lettering",
        "and apply that image as an overlay on the existing sticker.",
        "Use it for artwork the sticker does not have yet, including artwork that is replacing an",
        "app-drawn layer — 'make the lettering hand-drawn' is this tool plus a removeLayer.",
        "It costs a real image generation. Use edit_layers for app-rendered text, shapes, and",
        "particles; preserve requests for illustrated lettering by generating the lettering image.",
      ].join(" "),
      inputSchema: z
        .object({
          prompt: z.string().trim().min(1).max(4_000),
          name: z.string().trim().min(1).max(80),
          index: z
            .number()
            .int()
            .min(0)
            .max(MAX_LAYER_INDEX)
            .optional()
            .describe("Where in the stack to insert it. Omit to put it on top."),
          x: z.number().min(0).max(1).optional(),
          y: z.number().min(0).max(1).optional(),
          scaleX: z.number().min(0.05).max(1).optional(),
          scaleY: z.number().min(0.05).max(1).optional(),
        })
        .strict(),
      execute: async (value) => guard(() => session.addImageLayer(value)),
    }),
    // Absent from a static sticker's tool set rather than present and refusing: a clip is frames,
    // and the document contract will not hold more than one of them in a static document. The
    // project's kind is fixed when it is created and no edit can change it, so a tool the model
    // could only ever be told "no" by is better not offered at all.
    ...(input.document?.kind === "animated"
      ? {
        create_video: tool({
          description: [
            "Turn one image layer into a short generated clip: a video model animates the layer's",
            "own artwork, and the layer becomes a video layer that plays that clip in the same",
            "place, at the same size, carrying the same motion you gave it. The artwork stays on as",
            "the layer's still, so nothing about how the sticker looks changes — only that this",
            "part of it now moves on its own.",
            "This is the most expensive tool here: it costs a video generation, it takes longer than",
            "an image does, and once a layer is a clip no tool can turn it back into a still. You",
            "get one clip per turn, and a sticker can hold only one.",
            "Use it only for motion that keyframes genuinely cannot express — a turnaround or any",
            "change of viewing angle, a camera move, cloth, hair, fur, smoke, fire or liquid, a",
            "morph from one form into another. Everything a layer can do while staying the same",
            "picture — moving, spinning flat, scaling, pulsing, fading, shining, wiping — is a",
            "keyframe animation: free, instant, sharper, and transparent by construction. Reach for",
            "those first and leave this alone unless the request is impossible without it.",
            "motion describes what the subject or the camera does over the clip, e.g. 'slow 360°",
            "turntable rotation, one full turn' — not what the subject is, which the artwork",
            "already shows. durationSeconds is how long that motion takes; keep it short.",
            "To animate something the sticker does not have yet, draw it with add_image_layer and",
            "then call this on the layer that call added — which spends an image and a video, so be",
            "sure the request really needs both.",
          ].join(" "),
          inputSchema: z
            .object({
              layerId: z.string().min(1).max(64),
              motion: z.string().trim().min(1).max(500),
              // The same window the plan's `video` source allows: the model's own floor is 2s,
              // and the document timing this loop can set tops out at 4s.
              durationSeconds: z.number().int().min(2).max(4).default(3),
            })
            .strict(),
          execute: async (value) => guard(() => session.createVideoLayer(value)),
        }),
      }
      : {}),
    finalize_edit: tool({
      description: [
        "Finish and show the edited sticker to the user. Call this once, when the sticker matches",
        "what they asked for. Do not call it before you have actually changed something.",
      ].join(" "),
      inputSchema: z.object({}).strict(),
      execute: async () => {
        const result = await guard(() => session.finalizeEdit());
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
      WEB_RESEARCH_PROMPT,
      "You change an existing sticker. It is a stack of layers, and you own all of it: you can",
      "redraw artwork, draw new artwork, and add, remove, reorder, rename, restyle, and move any",
      "layer of any type. Finish by calling finalize_edit.",
      "Change only what the user asked for. Everything you do not touch stays exactly as drawn,",
      "which is the whole reason this is an edit and not a redraw — so never remove or redraw a",
      "layer just to rebuild it the way it already was.",
      "Your calls stack: each one is applied to the result of the last, and there is no undo. Read",
      "the layer list each tool returns before deciding what to do next.",
      "",
      "Some of these tools spend money. edit_image_layer and add_image_layer each run an image",
      "model, which is slow and billed; edit_layers is free and instant. If the request can be",
      "served by moving, removing, or restyling app-rendered layers, serve it with edit_layers",
      "alone.",
      "For a request such as 'Add cartoon text to the sticker says gogogog!', use add_image_layer",
      "to generate a transparent image containing only the exact requested lettering and its",
      "decoration, then overlay it on the existing sticker. Preserve the spelling and punctuation.",
      "For these illustrated-lettering requests, do not substitute an app-rendered text layer.",
      "The generated image must not include the existing subjects, scenery, or a smaller copy of",
      "the sticker. Keep the existing artwork unchanged and use the layer's position and scale",
      "to apply the lettering over it.",
      "Adding text on top of existing artwork is intentional overlap; place it where requested.",
      // Named here as well as in its own description because the failure this guards against is
      // not the model misusing the tool, it is the model reaching for it at all: "make it move"
      // is a keyframe animation nine times out of ten, and a clip is the expensive tenth.
      ...(input.document?.kind === "animated"
        ? [
          "create_video costs the most of all and cannot be undone: it animates one image layer's",
          "artwork into a clip and that layer is a clip from then on. Motion is normally free —",
          "a layer can move, spin, scale, pulse, fade, shine and wipe from its animations without",
          "any generation at all — so reach for create_video only when the sticker has to show",
          "something the same picture cannot: a turnaround or another angle, a camera move, cloth,",
          "hair, fur, smoke, fire, liquid, or a morph into a different form. One clip per turn, one",
          "per sticker.",
        ]
        : []),
      "",
      "Layer types. image layers are drawn artwork and can only be changed by the two image tools.",
      "text, shape, and particle layers are drawn by the app from the document, so edit_layers can",
      "create and change them freely and they cost nothing.",
      "Layout. A layer's anchor is where it rests: position x and y are its normalized centre",
      "(0,0 is top-left, 1,1 is bottom-right) and scale is relative to a box covering 86% of the",
      "canvas. Keep layers on canvas and keep their boxes from overlapping unless the user wants",
      "them stacked. image, sequence, video, and text layers are fitted inside a square box, so",
      "give them equal scaleX and scaleY; an unequal pair is applied as the smaller of the two.",
      "Stacking. Layers are drawn in array order: index 0 is at the back and the last layer is on",
      "top. Put a new element behind or in front of what it belongs with, not just on top.",
      "Every tool result carries diagnostics: offCanvasLayerIds must be empty before finalize_edit,",
      "and an operation that leaves a layer off canvas is rejected with the layers to fix.",
      "substantialOverlaps lists boxes that cover most of a smaller layer — separate them, unless",
      "the user asked for one thing on top of another. Call view_sticker after a change that moves",
      "or adds something, and fix what you see before finishing.",
      "Motion. Animations are named effects with a delay and a duration in seconds; two on the same",
      "layer must not overlap in time if they drive the same property, and every one must finish",
      "within the sticker's duration. Static stickers cannot carry any animations at all.",
      "",
      "If a tool returns an error, read it and fix it — the error text says exactly what was wrong.",
      "Do not give up and do not send the same rejected operation again.",
    ].join(" "),
    messages: userTurn([
      `Current StickerDocument:\n${JSON.stringify(input.document)}`,
      attachedImagesNote(
        viewable.length,
        "Read them for the subject, likeness, style, and colours the user wants. Every redraw you"
        + " ask for is shown them as well, so write its prompt around what you can see in them"
        + " rather than restating that a reference exists.",
      ),
      input.targetLayerId
        ? `The user is pointing at the layer with id ${input.targetLayerId}. Start there, and touch`
          + " another layer only if their words are about it."
        : "",
      input.imagePlacement === "add"
        ? "The request reads as wanting something new alongside what is already there, rather than a"
          + " change to existing artwork."
        : "",
      // Wider than the images above: a redraw also gets the sticker's own artwork back, which is
      // what keeps a re-drawn layer looking like the sticker it belongs to.
      input.attachmentCount > viewable.length
        ? `Each redraw is given ${input.attachmentCount} reference images in total: the ones above,`
          + " and the artwork this sticker already has."
        : "",
      `Recoverable chat history:\n${input.history}`,
      `Instruction:\n${input.instruction}`,
    ]
      .filter(Boolean)
      .join("\n\n"), viewable),
    tools,
    toolChoice: "required",
    // This loop's calls stack and two of them buy images, so its tool history is the one part of
    // the context that must not be forgotten cheaply — hence the wide retention window rather than
    // the SDK example's three messages.
    prepareStep: compactingPrepareStep({ loop: "edit" }),
    // The model ends the turn by calling finalize_edit. The step cap is the backstop for a model
    // that keeps polishing forever; the caller ships whatever landed when it trips.
    stopWhen: [
      hasToolCall("finalize_edit"),
      stepCountIs(14),
      () => fatal !== undefined,
    ],
    maxRetries: 2,
    // Longer than the animation loop's budget because two of these tools wait on an image model,
    // which is minutes rather than seconds. Four redraws is the step's own ceiling.
    abortSignal: AbortSignal.timeout(IMAGE_TIMEOUT_MS * 2),
  });
  await recordTextApiCost(generation);

  if (fatal) throw fatal;
  return state;
}

/**
 * Keeps the edit loop's free tool free.
 *
 * `edit_layers` may restructure the stack however it likes, but it may not conjure artwork: an
 * `assetId` is only real if this turn generated it and paid for it, or if the layer it is already
 * on carries it. Both of those go through `add_image_layer` and `edit_image_layer`, which own the
 * generation and the asset row. Anything else names an asset the model invented or borrowed from
 * another sticker, which `assertDocumentAssetsOwned` would reject a moment later anyway — this
 * turns that into an error the model can read and act on.
 */
export function validateEditOperation(
  operation: StickerOperationV1,
): StickerOperationV1 {
  if (operation.op === "replaceAsset") {
    throw new ApiError(
      422,
      "UNSAFE_EDIT_OPERATION",
      "replaceAsset cannot be used here; redraw the layer with edit_image_layer instead",
    );
  }
  if (operation.op === "addLayer" && operation.layer.type === "image") {
    throw new ApiError(
      422,
      "UNSAFE_EDIT_OPERATION",
      "An image layer has to be drawn; add it with add_image_layer instead",
    );
  }
  // Captured footage enters a sticker exactly one way: the user lifts a subject out of a Live Photo
  // and attaches it. Letting the edit loop conjure a sequence layer would mean pointing one at an
  // atlas the user did not choose for this sticker, which is their own face — not something a model
  // gets to place on its own initiative.
  if (operation.op === "addLayer" && operation.layer.type === "sequence") {
    throw new ApiError(
      422,
      "UNSAFE_EDIT_OPERATION",
      "Captured footage can only be added by the user; it cannot be introduced by an edit",
    );
  }
  // A clip has to be generated, and generating one is what `create_video` owns: it buys the video,
  // stores it, and writes the layer that points at it. An `addLayer` naming a video asset by hand
  // would point at one this turn never produced.
  if (operation.op === "addLayer" && operation.layer.type === "video") {
    throw new ApiError(
      422,
      "UNSAFE_EDIT_OPERATION",
      "A clip has to be generated; turn an image layer into one with create_video instead",
    );
  }
  // A sprite's sheets and face slots are registered by the build; an `addLayer` naming them by hand
  // would point at sheets this turn never drew, or at anchors nothing measured.
  if (operation.op === "addLayer" && operation.layer.type === "sprite") {
    throw new ApiError(
      422,
      "UNSAFE_EDIT_OPERATION",
      "A sprite character has to be planned and built; it cannot be introduced by an edit",
    );
  }
  return operation;
}

/**
 * The layer an operation acts on, or `undefined` for one that acts on the document.
 *
 * `addLayer` is deliberately document-level even though it carries a layer: the layer it describes
 * does not exist yet, so an edit scoped to some other layer must not drop it. `setTiming` and
 * `setMp4Background` name no layer at all and are carried forward the same way.
 */
export function animationOperationLayerId(
  operation: StickerOperationV1,
): string | undefined {
  return "layerId" in operation ? operation.layerId : undefined;
}

export function validatePlannedAnimationOperation(
  operation: StickerOperationV1,
): StickerOperationV1 {
  if (
    operation.op === "replaceAsset" ||
    operation.op === "removeLayer" ||
    (operation.op === "addLayer" && (
      operation.layer.type === "image" || operation.layer.type === "sequence" || operation.layer.type === "video"
      || operation.layer.type === "sprite"
    ))
  ) {
    throw new ApiError(
      422,
      "UNSAFE_ANIMATION_OPERATION",
      "Animation planning cannot change image assets or layer ownership",
    );
  }
  return operation;
}
