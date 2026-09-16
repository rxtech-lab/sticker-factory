import type { StickerControlValues } from "@/lib/contracts/configuration";
// The shape of every AI turn: what a caller hands the provider, what the provider hands back,
// and the drafting sessions a long turn streams its partial work through.

import { z } from "zod";
import type { PosePreset } from "@/lib/contracts/pose-preset";
import { type ChromaKeyColor } from "@/lib/ai/chroma-key";
import { countKeyframes } from "@/lib/animation/compile";
import { type PlanV1 } from "@/lib/contracts/plan";
import { StickerOperationV1Schema, type StickerDocument, type StickerOperationV1 } from "@/lib/contracts/sticker";
import { type LayoutAdjustment } from "@/lib/layout/composition";
import type { SubjectBounds } from "@/lib/images/subject-bounds";

export interface AiReferenceImage {
  bytes: Uint8Array;
  mimeType: string;
}

export interface AiImageInput {
  prompt: string;
  references: Array<{ bytes: Uint8Array; mimeType: string }>;
  mask?: { bytes: Uint8Array; mimeType: string };
  conversationContext?: string;
  mode: "generate" | "conversation_edit";
  /** Draw only a new overlay element; references provide style, not a composition to reproduce. */
  isolatedLayer?: boolean;
  /**
   * Draw this one on `AI_QUICK_IMAGE_MODEL` instead of `AI_IMAGE_MODEL`.
   *
   * Set only for turns started from the Messages extension, where someone is standing inside a
   * conversation waiting to send something. The quick model costs and takes a fraction of what the
   * main one does, and the trade is real: it cannot produce transparency at all, so the sticker is
   * drawn against a chroma backdrop and cut out here (see `lib/ai/chroma-key.ts`). That is a worse
   * matte than a model-native alpha channel, which is why the main app never takes this path.
   */
  quick?: boolean;
  /**
   * Store the frame as drawn instead of cropping it to its visible subject.
   *
   * The crop is what makes a layer's box describe its pixels, so nearly everything wants it. The
   * exceptions are images whose frame *is* the point: a concept reference, whose coordinates the
   * parts separated from it are later measured against.
   */
  keepFrame?: boolean;
  /**
   * Draw a sprite sheet rather than one subject: `count` cells on a `columns` x `rows` grid.
   *
   * The ordinary instruction forbids grids outright — one sticker, never a contact sheet — so this
   * is what turns that rule off and says what to draw instead. `facePlaceholder` asks for a flat
   * magenta oval where the face goes in every cell, which `lib/render/sprite-registration.ts`
   * measures and paints out; `tiles` asks for face plates alone, one expression per cell.
   * `faceRegion` is the plan's description of where that face sits, so the sheet paragraph can
   * name it rather than assume a head.
   */
  sheet?: { columns: number; rows: number; count: number; facePlaceholder?: boolean; tiles?: boolean; faceRegion?: string };
  /** The image model's quality tier. Sheets ask for more than the default, since a cell is a third of the canvas. */
  quality?: "low" | "medium" | "high";
}

export interface AiImageReferenceCandidate {
  /** Human-readable role shown to the orchestrator alongside the image. */
  label: string;
  image: AiReferenceImage;
  /** Required inputs are always passed; the orchestrator chooses the remaining slots. */
  required?: boolean;
}

export interface AiReferenceSelectionContext {
  instruction: string;
  history: string;
  candidates: AiImageReferenceCandidate[];
  maxReferences: number;
}

/**
 * A generated sprite sheet to look at before it is registered and paid for again.
 *
 * `clips` sheets arrive raw, with the magenta face opening still visible, so the inspector can see
 * both the opening and anything facial the model left outside it; `expressions` sheets are the
 * face plates, checked for being plates alone and in the planned order.
 */
export interface AiSheetInspectionContext {
  kind: "clips" | "expressions";
  /** The plan layer's name. */
  character: string;
  /** The plan's `face` region, when the sprite has one. */
  face?: string;
  sheet: { columns: number; rows: number; count: number };
  image: AiReferenceImage;
  /** Expression labels in cell order, for `expressions` sheets. */
  expressions?: string[];
  /** Actual body frame with the opening this expression patch must fill. */
  faceGuide?: AiReferenceImage;
}

export type AiSheetInspection = { ok: true } | { ok: false; problems: string[] };

export interface AiImageOutput {
  bytes: Uint8Array;
  mimeType: "image/png";
  revisedPrompt?: string;
  /**
   * Where the artwork sat in the frame the model returned, when it was cropped to it. Absent for
   * masked inpaints and kept frames, and for a provider that does not measure.
   */
  subject?: SubjectBounds;
}

/**
 * One clip to animate from a still.
 *
 * The still arrives as a URL rather than as bytes because the default video model accepts image
 * input by URL only; the caller flattens the transparent part onto the key colour, stores that as
 * a scratch object, and presigns it for longer than a download would need, since the provider
 * queues before it fetches.
 */
export interface AiVideoInput {
  /** Presigned URL of the subject already flattened onto `keyColor`. */
  imageUrl: string;
  /** What the subject or camera does over the clip. */
  motion: string;
  durationSeconds: number;
  keyColor: ChromaKeyColor;
}

export interface AiVideoOutput {
  bytes: Uint8Array;
  mimeType: string;
  modelId: string;
}

export interface AiRetryableGeneration {
  jobId: string;
  kind: string;
  instruction: string;
  state: "failed" | "cancelled";
  error?: string;
  steps: Array<{ id: string; name: string; status: "streaming" | "complete" | "failed" }>;
}

export type AiChatAction =
  | { type: "retry_generation"; stepId?: string }
  | { type: "reply"; message: string }
  | { type: "generate"; instruction: string; usePlanImage?: boolean }
  /** Draws one new element on a transparent background and adds it as its own image layer. */
  | { type: "generate_image"; instruction: string; usePlanImage?: boolean }
  | {
      type: "edit";
      instruction: string;
      imagePlacement: "add" | "replace";
      targetLayerId?: string;
      usePlanImage?: boolean;
    }
  | { type: "animate"; instruction: string; targetLayerId?: string }
  | { type: "generate_video"; instruction: string; layerId: string; durationSeconds: number }
  | { type: "plan"; instruction: string }
  | { type: "show"; caption: string };

/**
 * A frame atlas the user attached to this turn: real frames of themselves, already cut out.
 *
 * Handed to the planner as data rather than left for it to infer, because the grid and the capture
 * rate were fixed on device and nothing the model writes may reinterpret them. The atlas itself
 * arrives separately, in `AiPlanContext.references`, so the planner also sees the motion as a
 * contact sheet and can design around what the subject actually does.
 */
export interface AiSequenceAsset {
  assetId: string;
  columns: number;
  rows: number;
  frameCount: number;
  frameRate: number;
}

export interface AiPlanContext {
  baseRevisionId?: string;
  /** Immutable project guidance, separate from the compacted transcript. */
  presetGuidance?: string;
  /** Labelled cover artwork, distinct from subject/approved references. */
  presetReferences?: AiPlanVisual[];
  instruction: string;
  history: string;
  stickerKind: "static" | "animated";
  /**
   * The project was created with the controllable switch on, so every plan for it has to build the
   * character as a sprite with mood and pose controls. The user turned it on instead of asking for
   * it in words, so nothing in `instruction` need mention it.
   */
  controllable: boolean;
  posePreset?: PosePreset;
  document?: StickerDocument;
  /** Reasons the user gave for turning down earlier plans, so the agent does not repeat them. */
  rejectedReasons: string[];
  /** Captures attached to this turn. Empty for every turn that is not capture-led. */
  sequenceAssets: AiSequenceAsset[];
  /**
   * The images the user attached to this turn, shown to the planner.
   *
   * Includes the atlas of any capture in `sequenceAssets`, so the same attachment arrives twice:
   * once as the numbers the plan has to copy, and once as a contact sheet the planner can look at.
   */
  references: AiReferenceImage[];
  /**
   * What the project already looks like: pictures from earlier turns rather than from this one.
   *
   * The planner used to be shown `references` and nothing else, which meant a turn where the user
   * attached nothing — every "make the text bigger", every re-plan — was planned blind. It had the
   * document's JSON and the transcript's prose, and no way to see the artwork it was revising, so it
   * would redesign details nobody asked it to change. These are that missing evidence.
   *
   * Kept apart from `references` because the two mean opposite things to the prompt: an attachment
   * is material the user handed over for the sticker to draw *from*, while this is the sticker
   * *itself*. Conflating them is how a planner starts treating its own last render as a mood board.
   */
  priorArt: AiPlanVisual[];
}

/** One piece of prior art, with the words the prompt introduces it by. */
export interface AiPlanVisual {
  /** Names the picture, so a model looking at four images knows which one it is reading. */
  label: string;
  image: AiReferenceImage;
}

/**
 * The side effects a planning turn is allowed to perform.
 *
 * The provider drives the conversation but owns no database access: the workflow step supplies
 * these, so it can wrap each call in the transcript's tool-call rows and keep persistence out of
 * the AI layer. It also makes the mock provider a few lines instead of a fake database.
 */
export interface PlanDraftingSession {
  createPlan(plan: PlanV1): Promise<{ planId: string; revision: number }>;
  updatePlan(
    planId: string,
    plan: PlanV1,
  ): Promise<{ planId: string; revision: number }>;
  showPlan(planId: string): Promise<{ planId: string; revision: number }>;
  finalizePlan(planId: string): Promise<{ planId: string; revision: number }>;
}

export type PlanTurnResult = {
  planId: string;
  revision: number;
  finalized: boolean;
};

export interface AiAnimationContext {
  /** Immutable project guidance, separate from the compacted transcript. */
  presetGuidance?: string;
  /** Labelled cover artwork, distinct from subject/approved references. */
  presetReferences?: AiPlanVisual[];
  /** The document the motion is planned against. Every revision is applied to this, never to the last attempt. */
  document: StickerDocument;
  instruction: string;
  history: string;
  /**
   * When set, every operation must name this layer.
   *
   * Enforced by the session rather than the schema, so a stray operation reaches the model as a
   * tool error it can correct instead of failing the turn.
   */
  targetLayerId?: string;
  /**
   * The images the user attached to this turn, shown to the animator.
   *
   * Motion is the one thing a picture can carry that the document cannot: "make it wave like this"
   * is a request about the attachment, and a capture's atlas is a contact sheet of the movement
   * itself. Usually empty — most animate turns are words about artwork that already exists.
   */
  references: AiReferenceImage[];
}

/**
 * The side effects one animation-drafting turn is allowed to perform.
 *
 * Same contract as `PlanDraftingSession`: the provider drives the conversation, the workflow step
 * owns the working document, the transcript rows, and the snapshot events. Nothing here reaches a
 * database — an animation draft only ever lives in the step's memory, because unlike a plan it
 * costs nothing to rebuild and is never handed to the user for a decision until it is finished.
 */
export interface AnimationDraftingSession extends RenderableSession {
  /** Applies the first operation set to the base document. Retryable until one succeeds. */
  createAnimation(
    operations: StickerOperationV1[],
  ): Promise<AnimationDraftState>;
  /**
   * Replaces the whole animation with a revised operation set, re-applied to the base document.
   *
   * Deliberately not a patch onto the previous attempt: a restatement is what makes each revision
   * independently reproducible, so a repair cannot inherit half of the timing that was rejected.
   */
  updateAnimation(
    animationId: string,
    operations: StickerOperationV1[],
  ): Promise<AnimationDraftState>;
  /**
   * Replaces one layer's motion, keeping every other layer's exactly as it stands.
   *
   * The restatement rule above is what makes a revision reproducible, but it charges the whole
   * animation for a change to one layer: "start the hat a little later" arrives as every operation
   * the sticker has, retyped, and a layer dropped in the retyping is silently un-animated.
   *
   * So this narrows the restatement to a single layer rather than abandoning it. The operations
   * naming `layerId` are swapped for these, the rest are carried forward untouched, and the merged
   * set is re-applied to the base document exactly as an update would be — the draft stays a pure
   * function of the base and one operation list, and only the model's typing gets shorter.
   */
  editLayerAnimation(
    animationId: string,
    layerId: string,
    operations: StickerOperationV1[],
  ): Promise<AnimationDraftState>;
  /** Ends the loop. The caller creates the candidate revision and shows it in chat. */
  finalizeAnimation(animationId: string): Promise<AnimationDraftState>;
}

export type AnimationDraftState = {
  animationId: string;
  /** How many operation sets have landed. Drives the transcript's `#N` labels. */
  revision: number;
  document: StickerDocument;
};

export type AnimateTurnResult = {
  animationId: string;
  revision: number;
  finalized: boolean;
};

/**
 * Wraps a session failure the model cannot repair: cancellation, a vanished asset, a database error.
 *
 * The SDK turns every `execute` throw into a tool-error part and keeps looping, so without this
 * distinction a cancelled turn would spend its whole step budget being told to try again. The
 * loop stops on it and the original error is rethrown once the loop has unwound.
 *
 * Shared by the animation and edit loops: both drive a session the workflow step owns, so both have
 * the same two classes of failure — the model's own mistakes, and everything else.
 */
/**
 * A picture of the working document, for the agent to look at.
 *
 * The one capability the loops had no way to get on their own: every export is rendered by the iOS
 * client, so until this existed the server — and therefore the model — could only ever read a
 * document as JSON. An agent asked to "make the entrance snappier" was reasoning entirely about
 * numbers it had written itself.
 */
export type StickerRenderResult = {
  bytes: Uint8Array;
  /** The encoding of `bytes`; see `SHEET_MIME`. Never assume PNG. */
  mimeType: string;
  controlValues?: StickerControlValues;
  /** Control selections still needing inspection for the current edit draft. */
  pendingReviewSelections?: StickerControlValues[];
  /** The instants drawn, in document seconds. One entry for a static sticker. */
  times: number[];
  width: number;
  height: number;
};

/** Sessions that can show the model what it has built. Shared by the animate and edit loops. */
export interface RenderableSession {
  renderSticker(values?: StickerControlValues): Promise<StickerRenderResult>;
}

export interface AiLayoutContext {
  /** Immutable project guidance, separate from the compacted transcript. */
  presetGuidance?: string;
  /** Labelled cover artwork, distinct from subject/approved references. */
  presetReferences?: AiPlanVisual[];
  /** User and carried project reference photos, separate from preset cover examples. */
  references?: AiReferenceImage[];
  /** The confirmed plan's motion/expression storyboard, distinct from its resting composition. */
  animationSummary?: AiReferenceImage;
  /** The assembled document whose actual generated pixels are now available for review. */
  document: StickerDocument;
  /** The approved plan's human-readable intent. */
  instruction: string;
  history: string;
}

export type LayoutDraftState = {
  revision: number;
  document: StickerDocument;
};

export interface LayoutDraftingSession extends RenderableSession {
  /** Returns the approved static plan image on demand. Absent for plans that did not produce one. */
  viewPlanImage?: () => Promise<AiReferenceImage>;
  /** Moves, scales, rotates, or reorders existing layers; it cannot change their artwork or motion. */
  applyLayout(adjustment: LayoutAdjustment): Promise<LayoutDraftState>;
  finalizeLayout(): Promise<LayoutDraftState>;
}

export type LayoutTurnResult = {
  revision: number;
  finalized: boolean;
};

export class TurnAbort extends Error {
  constructor(public readonly reason: unknown) {
    super("The turn was aborted");
    this.name = "TurnAbort";
  }
}

/** Recognises a `TurnAbort` across bundle boundaries, where `instanceof` alone cannot be trusted. */
export function isTurnAbort(error: unknown): error is TurnAbort {
  // Name as well as identity: this module and the workflow step are bundled into separate server
  // chunks, and a duplicated class would break `instanceof` while the name still holds.
  return error instanceof TurnAbort || (error instanceof Error && error.name === "TurnAbort");
}

/**
 * Turns a session failure into text the model can act on.
 *
 * A `ZodError`'s own message is a JSON dump of every issue; `z.prettifyError` is one readable line
 * per problem with the path attached, which is what makes "read the error and fix it" achievable.
 */
export function describeToolError(error: unknown): string {
  const text =
    error instanceof z.ZodError
      ? z.prettifyError(error)
      : error instanceof Error
        ? error.message
        : String(error);
  return text.slice(0, 1_200);
}

/**
 * What a layer is, in the few words a tool result can afford.
 *
 * Enough for the model to tell two layers apart when it has to pick one — the words in a text
 * layer, the preset behind a particle field — without echoing the paint, stroke, and markup that
 * the document JSON in the prompt already carries.
 */
function describeLayer(layer: StickerDocument["layers"][number]): string {
  switch (layer.type) {
  case "image":
    return `artwork ${layer.assetId}`;
  case "text":
    return `text "${layer.text}"`;
  case "shape":
    return `shape ${layer.shape.kind}`;
  case "svg":
    return "vector artwork";
  case "particle":
    return `${layer.count} ${layer.preset}`;
  case "sequence":
    return `${layer.frameCount}-frame live capture ${layer.assetId}`;
  case "video":
    return `${layer.frameCount}-frame generated clip ${layer.assetId}`;
  case "sprite":
    return `sprite character: clips ${layer.clips.map((clip) => clip.id).join("/")}, `
      + `expressions ${layer.expressions.tiles.map((tile) => tile.id).join("/")}, showing ${layer.clipId} ${layer.expressionId}`;
  }
}

/**
 * A compact digest of the working document for the tool result.
 *
 * The compiled keyframe tracks are up to 128 objects of purely derived data, so echoing the whole
 * document back on every step would crowd the conversation out for no gain. The layer stack in
 * order, the specs the model authored, and a count of what they compiled to is everything it needs
 * to judge its own work.
 */
export function summarizeDocument(document: StickerDocument) {
  return {
    configuration: document.configuration,
    durationSeconds: document.durationSeconds,
    fps: document.fps,
    loop: document.loop,
    layers: document.layers.map((layer, index) => ({
      index,
      layerId: layer.id,
      type: layer.type,
      name: layer.name,
      description: describeLayer(layer),
      hidden: layer.hidden,
      position: layer.anchor.position,
      scale: layer.anchor.scale,
      animations: layer.animations.map((spec) => ({
        type: spec.type,
        delay: spec.delay,
        duration: spec.duration,
      })),
      keyframes: countKeyframes(layer.animation),
    })),
  };
}

/**
 * One tool call's worth of operations.
 *
 * Smaller than the document-level `StickerOperationsV1Schema` cap of 32: a single call revises the
 * motion of an 8-layer document, and a bound that low keeps a runaway restatement from arriving as
 * one unreviewable wall of JSON.
 */
export const AnimationOperationsSchema = z
  .array(StickerOperationV1Schema)
  .min(1)
  .max(16);

export interface AiEditContext {
  /** Immutable project guidance, separate from the compacted transcript. */
  presetGuidance?: string;
  /** Labelled cover artwork, distinct from subject/approved references. */
  presetReferences?: AiPlanVisual[];
  /** The sticker being changed. Every operation is applied on top of this. */
  document: StickerDocument;
  instruction: string;
  history: string;
  /** The layer the user pointed at, when the request or the router named one. */
  targetLayerId?: string;
  /** The router's read of whether new artwork is wanted alongside the old, or in place of it. */
  imagePlacement: "add" | "replace";
  /**
   * How many reference images every redraw this turn asks for will be given.
   *
   * Wider than `references` below: a redraw is also shown the artwork the sticker already has, so
   * that a re-drawn layer still looks like the sticker it belongs to.
   */
  attachmentCount: number;
  /** The images the user attached to this turn, shown to the model that decides what to redraw. */
  references: AiReferenceImage[];
}

/**
 * The side effects one edit turn is allowed to perform.
 *
 * Same contract as `PlanDraftingSession` and `AnimationDraftingSession`: the provider drives the
 * conversation, the workflow step owns the working document, the transcript rows, and the money.
 *
 * The asymmetry worth knowing is that these calls *stack*. An animation update restates the whole
 * animation against the base document because timing is cheap to redo; an edit cannot work that way,
 * because half of these calls have already bought an image. So each one is applied to the result of
 * the last, and there is no undo.
 */
export interface EditDraftingSession extends RenderableSession {
  /** Redraws one image layer's artwork in place. Costs one image generation. */
  editImageLayer(input: {
    layerId: string;
    prompt: string;
  }): Promise<EditDraftState>;
  /** Draws one new element and adds it to the stack as its own image layer. Costs one generation. */
  addImageLayer(input: {
    prompt: string;
    name: string;
    index?: number;
    x?: number;
    y?: number;
    scaleX?: number;
    scaleY?: number;
  }): Promise<EditDraftState>;
  /**
   * Animates one image layer into a generated clip, replacing it with a `video` layer in place.
   *
   * The layer's own artwork is the still the clip is animated from, and stays on as the layer's
   * poster — so this is a change of layer kind, not a redraw: the sticker keeps looking like
   * itself, and everything that cannot decode video keeps drawing the frame it already knows.
   *
   * The most expensive call in the loop, and the only one that is not undoable by another tool:
   * costs one video generation, and no tool turns a clip back into a still.
   */
  createVideoLayer(input: {
    layerId: string;
    motion: string;
    durationSeconds: number;
  }): Promise<EditDraftState>;
  /**
   * Applies free document operations: adding, removing, reordering, renaming, and re-laying-out
   * layers the app draws itself. Nothing here generates artwork, so nothing here costs anything.
   */
  applyOperations(operations: StickerOperationV1[]): Promise<EditDraftState>;
  /** Ends the loop. The caller creates the candidate revision and shows it in chat. */
  finalizeEdit(): Promise<EditDraftState>;
}

export type EditDraftState = {
  pendingReviewSelections?: StickerControlValues[];
  /** How many tool calls have changed the document. Drives the transcript's `#N` labels. */
  revision: number;
  document: StickerDocument;
};

export type EditTurnResult = {
  revision: number;
  finalized: boolean;
};

/**
 * One tool call's worth of layer operations.
 *
 * Half the cap the animation loop gets: an edit call is a structural change to the layer stack —
 * a removal, a rename, a re-layout — and eight of those at once is already more than a user's one
 * sentence can have asked for.
 */
export const EditOperationsSchema = z.array(StickerOperationV1Schema).min(1).max(8);

export interface AiChatContext {
  /** Immutable project guidance, separate from the compacted transcript. */
  presetGuidance?: string;
  /** Labelled cover artwork, distinct from subject/approved references. */
  presetReferences?: AiPlanVisual[];
  instruction: string;
  history: string;
  stickerKind: "static" | "animated";
  document?: StickerDocument;
  attachmentCount: number;
  /**
   * The images the user attached to this turn, shown to the router.
   *
   * What was attached is often the whole of the request — a photo with "make this a sticker" reads
   * completely differently from the same words with nothing attached — and the router used to see
   * only the count.
   */
  references: AiReferenceImage[];
  /**
   * Pictures already present in the project, including the latest plan's static reference.
   *
   * A follow-up such as "use the plan image" normally has no new attachment. Without these, the
   * router sees the words in the transcript but not the image the user is pointing at, and can only
   * answer by incorrectly asking them to upload it again.
   */
  priorArt: AiPlanVisual[];
  /**
   * Whether this project has ever been planned.
   *
   * An animated project that has never been planned has no set of independently moving layers to
   * keyframe, so redrawing it as one flat image is a dead end: nothing downstream can animate it.
   * The router is told so it can reach for `plan-sticker` instead of `generate-sticker`.
   */
  hasPlan?: boolean;
  /** Persisted request and step outcomes from the previous failed or stopped generation. */
  retryableGeneration?: AiRetryableGeneration;
}

export interface AiTitleContext {
  /**
   * The name the project already carries: the opening words of the first prompt, or the summary an
   * earlier turn settled on. Passed in so a name that still fits can simply be kept.
   */
  currentTitle: string;
  history: string;
  stickerKind: "static" | "animated";
}

export interface AiProvider {
  /** Chooses which candidate images the image model needs for one concrete draw. */
  selectImageReferences(input: AiReferenceSelectionContext): Promise<number[]>;
  generateStickerImage(input: AiImageInput): Promise<AiImageOutput>;
  /**
   * Looks at a generated sprite sheet for what the pixel gates cannot see: facial features left on
   * the body outside the face opening, or an expression plate drawn as a whole head. A rejection
   * lists the problems so the sheet can be redrawn once with them as feedback.
   */
  inspectSpriteSheet(input: AiSheetInspectionContext): Promise<AiSheetInspection>;
  /**
   * Drafts a sticker plan, revising it as many times as it needs before finalizing.
   *
   * Unlike every other method here this one is a real multi-step tool loop: the model decides how
   * many times to call `update_plan` and stops itself by calling `finalize_plan`.
   */
  planSticker(
    input: AiPlanContext,
    session: PlanDraftingSession,
  ): Promise<PlanTurnResult | undefined>;
  /**
   * Renders the finished static appearance of a proposed animation for the user to approve.
   *
   * Deliberately separate from `generateStickerImage`: this image shows the complete composition,
   * while the ordinary path produces one transparent, independently animatable part.
   */
  generateConceptImage(input: {
    purpose?: "animation-summary" | "extension";
    prompt: string;
    references: Array<{ bytes: Uint8Array; mimeType: string }>;
  }): Promise<AiImageOutput>;
  /**
   * Animates a still into a short 1:1 clip on a chroma backdrop, for a plan's `video` layer.
   *
   * Low resolution on purpose: the clip is composited into a sticker that is looked at at
   * thumbnail size, and every second of it is metered.
   */
  generateStickerVideo(input: AiVideoInput): Promise<AiVideoOutput>;
  /** Reviews a built multi-layer sticker and corrects composition without regenerating artwork. */
  refineStickerLayout(
    input: AiLayoutContext,
    session: LayoutDraftingSession,
  ): Promise<LayoutTurnResult | undefined>;
  /**
   * Plans a document's motion, revising it as many times as it needs before finalizing.
   *
   * Like `planSticker` and unlike everything else here this is a real multi-step tool loop. Compile
   * and schema failures come back as tool errors, so a rejected timing is repaired in the same
   * conversation that produced it rather than by re-planning the animation from scratch.
   */
  animateSticker(
    input: AiAnimationContext,
    session: AnimationDraftingSession,
  ): Promise<AnimateTurnResult | undefined>;
  /**
   * Changes an existing sticker: its artwork, and the layer stack that artwork sits in.
   *
   * The third of the real multi-step tool loops. It exists as a loop rather than as a single
   * redraw because most requests to change a sticker are not one redraw — "drop the caption and
   * make the badge bigger" is a removal and a re-layout, and neither of them draws anything.
   */
  editSticker(
    input: AiEditContext,
    session: EditDraftingSession,
  ): Promise<EditTurnResult | undefined>;
  routeChatTurn(input: AiChatContext): Promise<AiChatAction>;
  showSticker(
    revisionId: string,
    kind: "static" | "animated",
    instruction: string,
    history: string,
  ): Promise<string>;
  reply(instruction: string, history: string): Promise<string>;
  /**
   * Names the project from what its chat has become, so the library stops showing the first words
   * the user happened to type.
   *
   * Returning `input.currentTitle` unchanged is a real answer, not a failure: a sticker whose name
   * still describes it should keep it rather than be renamed once per turn.
   */
  summarizeStickerTitle(input: AiTitleContext): Promise<string>;
}

/**
 * Reconciles a routed action with the document it will actually run against.
 *
 * The router picks from the user's words; this checks the picks against the layers that exist. It
 * used to do a great deal more: an `edit` naming a text, shape, or particle layer was rewritten into
 * a `plan`, because the edit tool could only redraw image layers and would otherwise have failed the
 * turn. The edit tool now owns the whole layer stack, so that redirect is gone — a request to remove
 * a caption is served by the tool the user's words actually asked for, in one turn and for free,
 * instead of by a plan card they have to confirm.
 */
export function resolveChatAction(
  action: AiChatAction,
  document?: StickerDocument,
): AiChatAction {
  if (action.type === "animate") {
    // Animation keyframes any layer type, so only an id naming nothing at all is unusable. Dropping
    // it animates the document as a whole, which is what an untargeted request asks for anyway.
    return action.targetLayerId &&
      !document?.layers.some((layer) => layer.id === action.targetLayerId)
      ? { ...action, targetLayerId: undefined }
      : action;
  }
  if (action.type !== "edit") return action;
  // There is nothing to edit at all, so the sticker the user is describing has to be drawn first.
  if (!document) {
    return {
      type: "generate",
      instruction: action.instruction,
      ...(action.usePlanImage ? { usePlanImage: true } : {}),
    };
  }
  // An id that names no layer is a hallucination rather than a choice: forget it and let the edit
  // loop pick its own target from the layers the document really has.
  return action.targetLayerId &&
    !document.layers.some((layer) => layer.id === action.targetLayerId)
    ? { ...action, targetLayerId: undefined }
    : action;
}
