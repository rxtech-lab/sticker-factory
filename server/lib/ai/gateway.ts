import { gateway } from "@ai-sdk/gateway";
import {
  experimental_generateVideo as generateVideo,
  generateImage,
  generateText,
  hasToolCall,
  stepCountIs,
  tool,
  type ModelMessage,
  type LanguageModel,
} from "ai";
import { readFile } from "node:fs/promises";
import path from "node:path";
import sharp from "sharp";
import { z } from "zod";
import { compactingPrepareStep } from "@/lib/ai/compaction";
import { recordImageApiCost, recordTextApiCost, recordVideoApiCost } from "@/lib/ai/cost";
import {
  alternateChromaKey,
  chromaKeyBackground,
  preferredChromaKey,
  type ChromaKeyColor,
} from "@/lib/ai/chroma-key";
import { viewPlanImageTool } from "@/lib/ai/view-plan-image-tool";
import { viewStickerTool } from "@/lib/ai/view-sticker-tool";
import { countKeyframes } from "@/lib/animation/compile";
import { PlanV1Schema, reusableAssetIds, type PlanV1 } from "@/lib/contracts/plan";
import {
  MAX_LAYER_INDEX,
  StickerOperationV1Schema,
  type StickerDocument,
  type StickerOperationV1,
} from "@/lib/contracts/sticker";
import { ApiError } from "@/lib/http/errors";
import {
  LayoutAdjustmentSchema,
  layoutDiagnostics,
  type LayoutAdjustment,
} from "@/lib/layout/composition";
import { traceEvent, traceSpan } from "@/lib/observability/trace";
import type { SubjectBounds } from "@/lib/images/subject-bounds";
import {
  downscaleForModelInput,
  inspectImage,
  normalizeTransparentPng,
} from "@/lib/storage/r2";

/**
 * One image a turn carries: a photo the user attached, a capture's frame atlas, or artwork the
 * sticker already has.
 *
 * The same shape reaches two very different consumers. An image model is given these as the thing
 * to draw from, and the reasoning loops are *shown* them, so they can decide what to do about a
 * picture rather than being told a number of pictures exists.
 */
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

export type AiChatAction =
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
  instruction: string;
  history: string;
  stickerKind: "static" | "animated";
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
  /** The instants drawn, in document seconds. One entry for a static sticker. */
  times: number[];
  width: number;
  height: number;
};

/** Sessions that can show the model what it has built. Shared by the animate and edit loops. */
export interface RenderableSession {
  renderSticker(): Promise<StickerRenderResult>;
}

export interface AiLayoutContext {
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
function isTurnAbort(error: unknown): error is TurnAbort {
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
const AnimationOperationsSchema = z
  .array(StickerOperationV1Schema)
  .min(1)
  .max(16);

export interface AiEditContext {
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
const EditOperationsSchema = z.array(StickerOperationV1Schema).min(1).max(8);

export interface AiChatContext {
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

function assertImageInputBounds(input: AiImageInput): void {
  const files = [...input.references, ...(input.mask ? [input.mask] : [])];
  if (input.references.length > 8)
    throw new ApiError(
      422,
      "TOO_MANY_REFERENCES",
      "At most 8 reference images are allowed",
    );
  if (
    files.reduce((total, file) => total + file.bytes.byteLength, 0) >
    32 * 1024 * 1024
  ) {
    throw new ApiError(
      422,
      "AI_INPUT_TOO_LARGE",
      "Combined AI image inputs must not exceed 32 MB",
    );
  }
  for (const file of files) {
    if (file.bytes.byteLength >= 50 * 1024 * 1024) {
      throw new ApiError(
        422,
        "AI_IMAGE_TOO_LARGE",
        "Each image input must be smaller than 50 MB",
      );
    }
    if (
      !new Set(["image/png", "image/jpeg", "image/webp"]).has(file.mimeType)
    ) {
      throw new ApiError(
        422,
        "UNSUPPORTED_AI_IMAGE",
        "AI image inputs must be PNG, JPEG, or WebP",
      );
    }
  }
}

/**
 * How many of a turn's attachments the reasoning loops are shown.
 *
 * The image models take up to eight, because a redraw wants every scrap of likeness it can get and
 * pays for them once. A tool loop is the opposite case: its first message is re-sent on every step,
 * so each attached image is billed ten or fourteen times over a turn. Four covers what a person
 * actually attaches — a subject, a couple of angles, a style — and the rest still reach the artwork.
 */
const VIEWABLE_REFERENCE_LIMIT = 4;

/**
 * Prepares a turn's attachments for a model that is going to *look* at them.
 *
 * Not the same job as feeding an image model: those are given the originals, because the likeness
 * they draw from is the whole point. Here the picture is evidence, so it is downscaled to a single
 * tile first — see `downscaleForModelInput` for what that costs and why.
 *
 * An attachment that cannot be decoded is dropped rather than thrown. The turn's actual work does
 * not depend on the model seeing it, and failing a plan because one of three photos is a malformed
 * PNG would be a worse trade than planning from the other two.
 */
async function viewableReferences(
  references: AiReferenceImage[],
): Promise<AiReferenceImage[]> {
  const prepared = await Promise.all(
    references.slice(0, VIEWABLE_REFERENCE_LIMIT).map(async (reference) => {
      try {
        return [await downscaleForModelInput(reference.bytes)];
      } catch (error) {
        traceEvent("ai.reference.undecodable", {
          mimeType: reference.mimeType,
          byteSize: reference.bytes.byteLength,
          error: error instanceof Error ? error.message : String(error),
        });
        return [];
      }
    }),
  );
  return prepared.flat();
}

/**
 * How many pictures of the project itself the planner is shown.
 *
 * Three, and they answer three different questions: what the user gave us to work from, what the
 * sticker looks like now, and what they last approved. A fourth would cost a step's worth of tokens
 * on every step of a twelve-step loop to say something the first three already said.
 */
const PLAN_VISUAL_LIMIT = 3;

/**
 * Prepares the project's own artwork for a planner that is going to look at it.
 *
 * The same downscale `viewableReferences` applies, and the same tolerance for an image that will not
 * decode: prior art is context, so planning without one of these pictures is worse than planning
 * with it and far better than failing the turn over it. The label travels with the bytes so a
 * dropped image takes its line out of the prompt too, and the numbering never describes an image
 * that is not there.
 */
async function viewablePlanVisuals(
  visuals: AiPlanVisual[],
): Promise<AiPlanVisual[]> {
  const prepared = await Promise.all(
    visuals.slice(0, PLAN_VISUAL_LIMIT).map(async (visual) => {
      try {
        return [{ ...visual, image: await downscaleForModelInput(visual.image.bytes) }];
      } catch (error) {
        traceEvent("ai.priorArt.undecodable", {
          label: visual.label,
          mimeType: visual.image.mimeType,
          byteSize: visual.image.bytes.byteLength,
          error: error instanceof Error ? error.message : String(error),
        });
        return [];
      }
    }),
  );
  return prepared.flat();
}

/**
 * The one user message a loop starts from: its instructions, and the pictures they are about.
 *
 * `generateText` takes either a `prompt` string or a `messages` list, and an image can only travel
 * in the second — so a turn with attachments becomes a single user message with the text first and
 * the images after it, which is the order every provider's own guidance asks for.
 */
function userTurn(text: string, images: AiReferenceImage[]): ModelMessage[] {
  if (images.length === 0) return [{ role: "user", content: text }];
  return [
    {
      role: "user",
      content: [
        { type: "text", text },
        ...images.map((image) => ({
          type: "image" as const,
          image: image.bytes,
          mediaType: image.mimeType,
        })),
      ],
    },
  ];
}

/**
 * The line that tells a model what the images at the end of its message are.
 *
 * Without it an attachment reads as part of the sticker rather than as something the user handed
 * over this turn, and a plan comes back describing the photo's background as a layer.
 */
function attachedImagesNote(count: number, extra?: string): string {
  if (count === 0) return "";
  return [
    `The user attached ${count} image${count === 1 ? "" : "s"} to this turn, shown to you as the`,
    "last images in this message. They are reference material the user handed over, not the sticker",
    "itself, so never treat their background, framing, or surroundings as something the sticker",
    "contains.",
    extra ?? "",
  ]
    .filter(Boolean)
    .join(" ");
}

/**
 * Introduces the pictures of the project itself, which come before any attachment.
 *
 * Numbered rather than described in a lump because the model is handed a flat list of images and has
 * no other way to tell the current render from the last approved reference — and it needs to, since
 * they say different things: one is what the user is looking at, the other is what they signed off.
 */
function priorArtNote(visuals: AiPlanVisual[]): string {
  if (visuals.length === 0) return "";
  return [
    `The first ${visuals.length} image${visuals.length === 1 ? "" : "s"} in this message`,
    `${visuals.length === 1 ? "is" : "are"} this project as it already exists, in order:`,
    visuals.map((visual, index) => `(${index + 1}) ${visual.label}`).join(" "),
    "Look at them before you plan. A request that arrives on top of existing artwork is a change to",
    "what the user can already see, so carry over its subject, style, palette, proportions, and",
    "composition, and change only what was actually asked for. If what you are looking at does not",
    "match the plan you would have written from the text alone, believe the picture.",
  ]
    .filter(Boolean)
    .join(" ");
}

const transparentProviderOptions = {
  openai: {
    background: "transparent",
    output_format: "png",
    quality: "low",
  },
};

/**
 * The whole budget for one image generation, retries included — a single `AbortSignal` covers the
 * SDK's internal attempts, so this is not a per-attempt limit.
 *
 * Sized off what the model actually costs: `gpt-image-2` at `quality: "high"` spends ~170s on a
 * 1024x1024, measured end to end through the Gateway. The previous 180s ceiling sat inside that
 * spread, so a normal generation aborted a few seconds from landing — and because the workflow
 * retries the step, every abort started another full generation instead of surfacing anything, which
 * is what a turn stuck on "generate-image / Running…" for many minutes actually was. Env-overridable
 * so a slower model can be dialled in without a deploy.
 */
const IMAGE_TIMEOUT_MS = (() => {
  const configured = Number(process.env.AI_IMAGE_TIMEOUT_MS);
  return Number.isFinite(configured) && configured > 0 ? configured : 420_000;
})();

/**
 * The video model and its budget.
 *
 * Seedance 1.0 Pro Fast is the default because it is the cheapest model on the Gateway that takes
 * an image, renders 1:1 at 480p, and returns H.264 — which `inspectMp4` insists on. The timeout is
 * shorter than the image one deliberately: a clip and the still it is animated from are produced
 * in the same workflow step, and the two budgets together have to stay under the function's own
 * ceiling, or a slow pair fails at the runtime instead of at the provider with a message the user
 * can act on.
 */
const VIDEO_MODEL = process.env.AI_VIDEO_MODEL ?? "bytedance/seedance-v1.0-pro-fast";
/**
 * Sent to the Gateway verbatim. The AI SDK types this as `{width}x{height}`, but the Gateway's
 * own model cards name tiers (`480p`) and it forwards whatever it is given; a form the model
 * rejects comes back as a warning, which `generateStickerVideo` logs. The cast is what lets the
 * deployment choose either spelling without a code change.
 */
const VIDEO_RESOLUTION = (process.env.AI_VIDEO_RESOLUTION ?? "480p") as `${number}x${number}`;
const VIDEO_FPS = 24;
const VIDEO_TIMEOUT_MS = (() => {
  const configured = Number(process.env.AI_VIDEO_TIMEOUT_MS);
  return Number.isFinite(configured) && configured > 0 ? configured : 300_000;
})();

/**
 * What the video model is told, beyond the motion the planner wrote.
 *
 * The backdrop paragraph is the image one's argument made again for a moving picture: a video
 * model's instinct is to light the scene, and a lit scene casts a shadow onto the floor, which
 * survives the key as a grey smudge under the subject in every frame. The design paragraph exists
 * because a model animating a still will happily redraw it along the way — the sticker the user
 * approved has to be the sticker that turns.
 */
function videoInstruction(input: AiVideoInput): string {
  return [
    input.motion,
    "The subject is a sticker illustration: keep its exact design, colours, proportions, and outline",
    "throughout, and do not redraw, restyle, or add to it.",
    `Keep the flat, solid, pure ${input.keyColor.name} background (${input.keyColor.hex}) perfectly`,
    "uniform in every frame: no shadows, reflections, gradients, vignette, floor, scenery, or props.",
    "Nothing else enters the frame. Keep the whole subject inside the frame for the entire clip.",
    "No camera cuts, no text, no captions, no watermark.",
  ].join(" ");
}

/**
 * How the quick model is asked for a background it is incapable of leaving empty.
 *
 * `AI_QUICK_IMAGE_MODEL` has no transparency mode, so the alternative to a keyed backdrop is a
 * sticker with a white box behind it. The wording is blunt on purpose: "solid", "uniform", "every
 * pixel", and an explicit list of the things a model reaches for when it thinks it is being asked
 * for a *background* — gradients, vignettes, cast shadows, checkerboards — each of which survives
 * the key as a grey smear around the subject.
 *
 * Telling the model what the colour is *for* matters as much as naming it. Left unexplained, the
 * backdrop colour leaks into the artwork: a green screen becomes green grass under the character's
 * feet, and the character then stands in a hole.
 */
function chromaBackdropInstruction(color: ChromaKeyColor): string {
  return [
    `Place the sticker on a solid, uniform, pure ${color.name} background of exactly ${color.hex}.`,
    "Every pixel that is not part of the sticker subject must be that exact colour: no gradient,",
    "shading, vignette, texture, cast shadow, glow, checkerboard, border, or frame.",
    `That background is removed afterwards to make the sticker transparent, so nothing drawn in ${color.name}`,
    `survives — keep ${color.hex} and colours close to it out of the subject itself, including its outline,`,
    "and never draw scenery, ground, or props in it.",
  ].join(" ");
}

/**
 * Everything the drawing model is told, on either path.
 *
 * Shared so the two models are asked for the same picture and differ in exactly one paragraph: how
 * the background is supposed to arrive. Anything else that drifts between them shows up as quick
 * mode quietly drawing a different kind of sticker.
 */
function stickerInstruction(input: AiImageInput, keyColor?: ChromaKeyColor): string {
  return [
    input.mode === "conversation_edit"
      ? "Edit the supplied sticker references according to the latest instruction."
      : "Generate the sticker described by the latest instruction.",
    input.conversationContext
      ? `Recoverable project context:\n${input.conversationContext}`
      : "",
    `Latest instruction: ${input.prompt}`,
    keyColor
      ? `Draw one centered sticker subject. ${chromaBackdropInstruction(keyColor)}`
      : "Create a centered sticker with a genuinely transparent background.",
    "Produce exactly one sticker subject. Never draw a grid, contact sheet, storyboard, film strip, or multiple frames or poses side by side.",
    "Return PNG.",
  ].filter(Boolean).join("\n\n");
}

async function generateThroughImageModel(
  input: AiImageInput,
): Promise<Uint8Array> {
  const instruction = stickerInstruction(input);
  const prompt =
    input.references.length || input.mask
      ? {
          text: instruction,
          images: input.references.map((item) => item.bytes),
          ...(input.mask ? { mask: input.mask.bytes } : {}),
        }
      : instruction;
  const result = await generateImage({
    model: gateway.imageModel(
      process.env.AI_IMAGE_MODEL ?? "openai/gpt-image-2",
    ),
    prompt,
    n: 1,
    size: "1024x1024",
    maxRetries: 2,
    providerOptions: transparentProviderOptions,
    abortSignal: AbortSignal.timeout(IMAGE_TIMEOUT_MS),
  });
  await recordImageApiCost(result);
  return result.image.uint8Array;
}

/**
 * The quick model's budget. Far below the main model's, because the whole reason to take this path
 * is that someone is waiting inside a conversation: an image that has not arrived in two minutes
 * has already lost the argument against opening the main app.
 */
const QUICK_IMAGE_TIMEOUT_MS = (() => {
  const configured = Number(process.env.AI_QUICK_IMAGE_TIMEOUT_MS);
  return Number.isFinite(configured) && configured > 0 ? configured : 120_000;
})();

/**
 * Draws through the quick model, which is not an image model at all.
 *
 * Gemini's image models are multimodal *language* models that happen to answer with pictures, and
 * the Gateway says so — routing one through `generateImage` is refused outright with "is a language
 * model, not an image model". So the request is an ordinary chat completion: the instruction and any
 * reference images go up as one user message, and the drawing comes back as a file part alongside
 * whatever the model felt like saying about it.
 *
 * There is no `size` to ask for and no transparency option to set. The frame arrives at whatever
 * shape the model chose, opaque, and `normalizeTransparentPng` squares it up after the key.
 */
async function generateThroughQuickImageModel(
  input: AiImageInput,
  keyColor: ChromaKeyColor,
): Promise<Uint8Array> {
  const result = await generateText({
    model: gateway(process.env.AI_QUICK_IMAGE_MODEL ?? "google/gemini-3.1-flash-lite-image"),
    messages: [{
      role: "user",
      content: [
        { type: "text", text: stickerInstruction(input, keyColor) },
        ...input.references.map((item) => ({
          type: "file" as const,
          data: item.bytes,
          mediaType: item.mimeType,
        })),
      ],
    }],
    maxRetries: 2,
    abortSignal: AbortSignal.timeout(QUICK_IMAGE_TIMEOUT_MS),
  });
  // Billed as an image, not as text, because that is what it is: this call replaces a `gpt-image-2`
  // generation and belongs in the same column as one, however the provider happens to serve it.
  await recordImageApiCost({
    providerMetadata: result.providerMetadata ?? result.steps.at(-1)?.providerMetadata,
  });
  const drawn = result.files.find((file) => file.mediaType.startsWith("image/"));
  if (!drawn) {
    // A refusal, or an answer in words. Either way there is no picture, and the sentence the model
    // wrote instead is the only clue about why, so it goes into the trace rather than nowhere.
    traceEvent("gateway.quickImage:noImage", {
      finishReason: result.finishReason,
      said: result.text.slice(0, 200),
    });
    throw new Error("The quick image model answered without an image");
  }
  return drawn.uint8Array;
}

/**
 * How much of the frame the key has to take for the cut-out to be believable, and how much is too
 * much.
 *
 * Both ends are failures of the same instruction, read off the same number. Under the floor the
 * model ignored the backdrop and returned an ordinary opaque illustration, so there is nothing to
 * cut out. Over the ceiling the subject itself matched the key — a green frog on green — and what
 * came back is a sticker-shaped hole. A sticker sitting in the middle of a flooded frame keys
 * somewhere around half, and even a very large subject leaves well over a twentieth of the frame as
 * background, so the band is wide enough that nothing legitimate lands outside it.
 */
const MINIMUM_KEYED_FRACTION = 0.05;
const MAXIMUM_KEYED_FRACTION = 0.97;

/**
 * Quick mode's generation: draw the sticker against a chroma backdrop, then cut the backdrop out.
 *
 * Run twice at most, and the second run is not a repeat — it swaps the backdrop colour. Both ways
 * the key can fail are colour-dependent, and neither is fixable by asking the same model for the
 * same picture against the same screen again: a subject that matched green will match green a
 * second time. Against blue it will not. This costs a second image on the quick model, which is
 * roughly what one image on the main model costs, so it is worth doing once and not worth doing
 * twice.
 */
async function generateKeyedStickerImage(input: AiImageInput): Promise<AiImageOutput> {
  let keyColor: ChromaKeyColor = preferredChromaKey(input.prompt);
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const raw = await traceSpan(
      "gateway.image",
      { path: "quickImageModel", mode: input.mode, key: keyColor.name, attempt },
      () => generateThroughQuickImageModel(input, keyColor),
    );
    // Keying walks every pixel of a 1024x1024 image twice over — once in the matte pass, once in
    // the re-encode — and like the normalize passes below it, it is CPU work the Gateway dashboard
    // cannot see. Timed separately so a turn stalled in here is distinguishable from one waiting on
    // the model.
    const keyed = await traceSpan(
      "gateway.chromaKey",
      { bytes: raw.byteLength, key: keyColor.name },
      () => chromaKeyBackground(raw, keyColor),
    );
    const normalized = await traceSpan(
      "gateway.normalize",
      { bytes: keyed.bytes.byteLength, key: keyColor.name },
      () => normalizeTransparentPng(keyed.bytes),
    );
    if (
      normalized.inspection.hasTransparentPixels
      && normalized.inspection.hasNonTransparentPixels
      && keyed.keyedFraction >= MINIMUM_KEYED_FRACTION
      && keyed.keyedFraction <= MAXIMUM_KEYED_FRACTION
    ) {
      // Already cropped by the keyer, so the measurement is the keyer's too.
      return { bytes: normalized.bytes, mimeType: "image/png", subject: keyed.subject };
    }
    traceEvent("gateway.chromaKey:unusable", {
      key: keyColor.name,
      keyedFraction: Number(keyed.keyedFraction.toFixed(4)),
      hasSubject: normalized.inspection.hasNonTransparentPixels,
      attempt,
    });
    keyColor = alternateChromaKey(keyColor);
  }
  throw new ApiError(
    502,
    "OPAQUE_AI_OUTPUT",
    "Image generation did not produce a sticker that could be separated from its background",
  );
}

class GatewayAiProvider implements AiProvider {
  constructor(private readonly chatModel?: LanguageModel) {}

  async selectImageReferences(
    input: AiReferenceSelectionContext,
  ): Promise<number[]> {
    if (input.candidates.length === 0 || input.maxReferences <= 0) return [];

    const visible = (
      await Promise.all(
        input.candidates.slice(0, 8).map(async (candidate, index) => {
          try {
            return [{ index, candidate, image: await downscaleForModelInput(candidate.image.bytes) }];
          } catch (error) {
            traceEvent("ai.reference.undecodable", {
              index,
              label: candidate.label,
              mimeType: candidate.image.mimeType,
              byteSize: candidate.image.bytes.byteLength,
              error: error instanceof Error ? error.message : String(error),
            });
            return [];
          }
        }),
      )
    ).flat();
    const required = input.candidates
      .map((candidate, index) => (candidate.required ? index : -1))
      .filter((index) => index >= 0);
    if (visible.length === 0) return required.slice(0, input.maxReferences);

    const result = await generateText({
      model: gateway(process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
      system: [
        "You select reference images for a separate image-generation model.",
        "Inspect every candidate and call select_references exactly once.",
        "Choose only images that materially help this exact draw: likeness, exact approved design, style, pose, or source pixels to edit.",
        "Do not select an image merely because it is available. Required candidates are already guaranteed and do not consume your decision.",
        "Return candidate indices only. Never invent an index.",
      ].join(" "),
      messages: userTurn([
        `Candidate images:\n${visible.map(({ index, candidate }) => (
          `- ${index}: ${candidate.label}${candidate.required ? " (required; always passed)" : ""}`
        )).join("\n")}`,
        `Maximum references, including required images: ${input.maxReferences}`,
        `Recoverable project context:\n${input.history}`,
        `Exact image-generation instruction:\n${input.instruction}`,
      ].join("\n\n"), visible.map(({ image }) => image)),
      tools: {
        select_references: tool({
          description: "Select the candidate reference images that the image model should receive.",
          inputSchema: z.object({
            indices: z.array(z.number().int().min(0).max(input.candidates.length - 1))
              .max(input.maxReferences),
          }).strict(),
        }),
      },
      toolChoice: { type: "tool", toolName: "select_references" },
      maxRetries: 2,
      abortSignal: AbortSignal.timeout(90_000),
    });
    await recordTextApiCost(result);
    if (result.toolCalls.length !== 1 || result.toolCalls[0].toolName !== "select_references") {
      throw new Error("Reference selector must call select_references exactly once");
    }
    const selected = z.object({ indices: z.array(z.number().int()) })
      .parse(result.toolCalls[0].input).indices;
    return [...new Set([...required, ...selected])]
      .filter((index) => index >= 0 && index < input.candidates.length)
      .slice(0, input.maxReferences);
  }

  async generateStickerImage(input: AiImageInput): Promise<AiImageOutput> {
    assertImageInputBounds(input);
    if (input.mask) {
      if (!input.references[0])
        throw new ApiError(
          422,
          "MASK_TARGET_REQUIRED",
          "Masked edits require a target image",
        );
      const [target, mask] = await Promise.all([
        inspectImage(input.references[0].bytes),
        inspectImage(input.mask.bytes),
      ]);
      if (
        target.mimeType !== mask.mimeType ||
        target.width !== mask.width ||
        target.height !== mask.height
      ) {
        throw new ApiError(
          422,
          "MASK_DIMENSIONS_MISMATCH",
          "The mask and target image must have the same format and dimensions",
        );
      }
      if (!mask.hasTransparentPixels || !mask.hasNonTransparentPixels) {
        throw new ApiError(
          422,
          "MASK_REQUIRES_ALPHA",
          "The mask must contain both transparent and painted alpha pixels",
        );
      }
    }

    // A mask is the one thing the quick path cannot honour: it is an inpainting argument the quick
    // model has no equivalent for, and the alpha the mask is drawn in is exactly what a chroma
    // backdrop replaces. Masked edits come from the main app's brush anyway, never from Messages,
    // so this is a guard rather than a fallback anyone actually hits.
    if (input.quick && !input.mask) return generateKeyedStickerImage(input);

    const first = await traceSpan(
      "gateway.image",
      { path: "imageModel", mode: input.mode },
      () => generateThroughImageModel(input),
    );
    // Between the model returning and the workflow storing the asset sits a decode, an alpha
    // trim, and a re-encode of a 1024x1024 PNG — CPU work, off the network, that the Gateway
    // dashboard cannot see. If the process dies in here the request looks complete and billed
    // while the turn never advances, so both normalize passes are timed separately.
    // A masked inpaint is never cropped: the result has to stay pixel-aligned with the target it
    // replaces, and a mask is drawn against that frame, not against the subject inside it.
    const subjectCrop = !input.mask && !input.keepFrame;
    let normalized = await traceSpan(
      "gateway.normalize",
      { bytes: first.byteLength, subjectCrop },
      () => normalizeTransparentPng(first, { subjectCrop }),
    );

    if (!normalized.inspection.hasTransparentPixels) {
      // A second full generation, unbudgeted by the caller: the turn now costs two images and up
      // to twice the wall clock, which is worth knowing when one looks stuck.
      traceEvent("gateway.image:opaque", { retrying: true });
      const retry = await traceSpan(
        "gateway.image",
        { path: "alphaRetry" },
        () =>
          generateThroughImageModel({
            prompt:
              "Remove the entire background. Keep only the sticker subject with clean antialiased transparent edges; do not add a checkerboard.",
            references: [{ bytes: normalized.bytes, mimeType: "image/png" }],
            mode: "conversation_edit",
          }),
      );
      normalized = await traceSpan(
        "gateway.normalize",
        { bytes: retry.byteLength, retry: true, subjectCrop },
        () => normalizeTransparentPng(retry, { subjectCrop }),
      );
    }
    if (!normalized.inspection.hasTransparentPixels) {
      throw new ApiError(
        502,
        "OPAQUE_AI_OUTPUT",
        "Image generation did not produce a transparent sticker after retry",
      );
    }
    return { bytes: normalized.bytes, mimeType: "image/png", subject: normalized.subject };
  }

  async refineStickerLayout(
    input: AiLayoutContext,
    session: LayoutDraftingSession,
  ): Promise<LayoutTurnResult | undefined> {
    let state: LayoutTurnResult | undefined;
    let fatal: unknown;
    const hasPlanImage = Boolean(session.viewPlanImage);

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
      model: gateway(process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
      system: [
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
        `Current layer summary:\n${JSON.stringify(summarizeDocument(input.document))}`,
        `Conservative geometry diagnostics:\n${JSON.stringify(layoutDiagnostics(input.document))}`,
        `Recoverable project context:\n${input.history}`,
      ].filter(Boolean).join("\n\n"), []),
      tools,
      toolChoice: "required",
      stopWhen: [hasToolCall("finalize_layout"), stepCountIs(hasPlanImage ? 9 : 8), () => fatal !== undefined],
      maxRetries: 2,
      abortSignal: AbortSignal.timeout(120_000),
    });
    await recordTextApiCost(generation);

    if (fatal) throw fatal;
    return state;
  }

  async animateSticker(
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
      view_sticker: viewStickerTool(session, { animated: true }),
      create_animation: tool({
        description:
          "Apply your first set of operations to the sticker. Call this once, before any other animation tool.",
        inputSchema: z
          .object({ operations: AnimationOperationsSchema })
          .strict(),
        execute: async ({ operations }) => {
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
        },
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
        execute: async ({ animationId, operations }) => {
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
        },
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
        execute: async ({ animationId, layerId, operations }) => {
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
        },
      }),
      finalize_animation: tool({
        description: [
          "Finish and show the animation to the user. Call this once you are satisfied with the",
          "motion. Only the finalized animation is shown, so nothing you did before it is visible.",
        ].join(" "),
        inputSchema: z.object({ animationId: z.string().min(1) }).strict(),
        execute: async ({ animationId }) => {
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
      model: gateway(process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
      system: [
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
        .join("\n\n"), viewable),
      tools,
      toolChoice: "required",
      // Every step appends a restatement of the whole animation and a layer-by-layer summary of what
      // it compiled to, so a loop that spends its step budget repairing timing is the one most likely
      // to outgrow its context.
      prepareStep: compactingPrepareStep({ loop: "animate" }),
      // The model ends the turn by calling finalize_animation. The step cap is the backstop for a
      // model that keeps polishing forever; the caller ships whatever landed when it trips.
      stopWhen: [
        hasToolCall("finalize_animation"),
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

  async editSticker(
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
      view_sticker: viewStickerTool(session, {
        animated: input.document?.kind === "animated",
      }),
      edit_layers: tool({
        description: [
          "Change the layer stack: this is how layers are added, removed, reordered, renamed, and",
          "moved. It draws nothing and costs nothing, so it is the right tool for every request that",
          "does not need new artwork.",
          "addLayer adds a text, shape, or particle layer — send the whole layer object.",
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
          "Use it for artwork the sticker does not have yet, including artwork that is replacing an",
          "app-drawn layer — 'make the lettering hand-drawn' is this tool plus a removeLayer.",
          "It costs a real image generation, so prefer edit_layers whenever a text, shape, or particle",
          "layer would do.",
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
      model: gateway(process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
      system: [
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
        "served by moving, removing, restyling, or re-lettering layers, serve it with edit_layers",
        "alone.",
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

  async routeChatTurn(input: AiChatContext): Promise<AiChatAction> {
    const priorArt = await viewablePlanVisuals(input.priorArt);
    const viewable = await viewableReferences(input.references);
    const videoLayers = input.stickerKind === "animated" && input.document?.kind === "animated"
      && !input.document.layers.some((layer) => layer.type === "video")
      ? input.document.layers.filter((layer) => layer.type === "image")
      : [];
    const videoInput = z.object({
      layerId: z.enum(videoLayers.length > 0 ? videoLayers.map((layer) => layer.id) : ["unavailable"]),
      motion: z.string().trim().min(1).max(500),
      durationSeconds: z.number().int().min(2).max(4).default(3),
    }).strict();
    const tools = {
      ...(videoLayers.length > 0 ? {
        "generate-video": tool({
          description: [
            "Generate a video clip from an existing image layer in this animated sticker.",
            "The layer becomes a looping video in the same position, keeping its artwork as the poster.",
            "Use for explicit video-generation requests or motion requiring new frames, such as a",
            "character turning around, speaking, flapping its wings, or changing expression.",
            "motion describes the subject or camera movement. Select the image layer from the document.",
            "Costs a video generation; takes longer than keyframes. Duration is 2–4 seconds, one clip per sticker.",
            "For simple movement, scaling, flat rotation, or fading, prefer animate-sticker.",
          ].join(" "),
          inputSchema: videoInput,
          execute: async (value) => value,
        }),
      } : {}),
      reply: tool({
        description: [
          "Answer the user in words and change nothing. This is the correct choice whenever the user",
          "is asking a question, chatting, giving feedback, or saying anything that is not a request",
          "to change the sticker — for example 'who is this?', 'what can you do?', 'why did it look",
          "like that?', 'thanks', or 'I like it'.",
          "Generating or editing a sticker destroys the current candidate, so when it is unclear",
          "whether the user wants a change, reply and ask them instead of guessing.",
        ].join(" "),
        inputSchema: z
          .object({ message: z.string().trim().min(1).max(2_000) })
          .strict(),
        execute: async (value) => value,
      }),
      "generate-sticker": tool({
        description: [
          "Generate a new sticker candidate when no existing sticker should be preserved.",
          "Set usePlanImage when the user explicitly asks to use the previous plan image or static",
          "plan reference as the visual source; that image is one of the labeled project images.",
        ].join(" "),
        inputSchema: z
          .object({
            instruction: z.string().trim().min(1).max(8_000),
            usePlanImage: z.boolean().optional(),
          })
          .strict(),
        execute: async (value) => value,
      }),
      "generate-image": tool({
        description: [
          "Draw one new element as its own image layer on a transparent background and add it to the",
          "current sticker, leaving every existing layer untouched.",
          "This is the only tool that draws new artwork onto an existing sticker, so use it when the",
          "user asks for something to be added alongside what is already there — a hat on the",
          "character, a second creature, a prop, a badge — or when the new element must be its own",
          "layer so it can be moved, scaled, or faded independently later.",
          "It is also the tool for drawing something the sticker currently fakes with a text, shape,",
          "or particle layer — 'make the lettering hand-drawn', 'draw that star properly'.",
          "Prefer generate-sticker when the whole sticker should be redrawn from scratch, and",
          "edit-sticker when artwork that already exists should change.",
          "Set usePlanImage when the user explicitly wants this element styled from the previous",
          "plan image or static plan reference shown among the labeled project images.",
        ].join(" "),
        inputSchema: z
          .object({
            instruction: z.string().trim().min(1).max(8_000),
            usePlanImage: z.boolean().optional(),
          })
          .strict(),
        execute: async (value) => value,
      }),
      "edit-sticker": tool({
        description: [
          "Change the sticker that already exists, from natural-language instructions.",
          "It owns the whole layer stack: it redraws artwork, and it also adds, removes, reorders,",
          "renames, re-letters, restyles, and moves layers of every type — including the text, shape,",
          "and particle layers the app draws itself.",
          "So this is the tool for 'remove the caption', 'make the text smaller', 'put the badge",
          "behind the cat', 'recolour the sparkles', and 'make it blue' alike.",
          "Replace is the default; add means the user wants something new alongside what is there.",
        ].join(" "),
        inputSchema: z
          .object({
            instruction: z.string().trim().min(1).max(8_000),
            imagePlacement: z.enum(["replace", "add"]),
            targetLayerId: z
              .string()
              .min(1)
              .max(64)
              .optional()
              .describe(
                [
                  "Id of the layer the user is pointing at. Any layer id in the current document is",
                  "valid, whatever its type. Omit this unless they clearly name one.",
                ].join(" "),
              ),
            usePlanImage: z.boolean().optional().describe(
              "Use the latest plan's static reference as an image input when the user explicitly points to it.",
            ),
          })
          .strict(),
        execute: async (value) => value,
      }),
      "animate-sticker": tool({
        description: [
          "Add motion to the current animated sticker by keyframing the layers it already has.",
          "It works on whatever sticker is on screen, including a candidate the user has not kept yet.",
          "It can move, scale, rotate, fade, and apply effects to existing layers.",
          "It cannot create new artwork, so it cannot reveal elements that are not already separate",
          "layers — a word drawn inside one flat image cannot be typed out letter by letter.",
        ].join(" "),
        inputSchema: z
          .object({
            instruction: z.string().trim().min(1).max(8_000),
            targetLayerId: z.string().min(1).max(64).optional(),
          })
          .strict(),
        execute: async (value) => value,
      }),
      "plan-sticker": tool({
        description: [
          "Design a sticker as a set of independent layers before anything is generated: which",
          "layers exist, where each one sits, and how each one moves.",
          "Use this when the sticker needs elements that appear, move, or are positioned",
          "independently — per-letter text effects such as a typewriter reveal, multi-character",
          "scenes, staged reveals, or motion where different parts move at different times.",
          "This only drafts a plan for the user to confirm; it does not generate anything, so it is",
          "the slowest way to change a sticker and the only one that needs their approval.",
          "Prefer edit-sticker for any change to a sticker that already exists — it adds, removes,",
          "re-letters, restyles, and rearranges layers directly, in one turn and without a card to",
          "confirm. Reach for a plan only when the sticker has to be restructured into a new set of",
          "independently moving parts.",
          "Prefer generate-sticker when one unified image would do.",
        ].join(" "),
        inputSchema: z
          .object({ instruction: z.string().trim().min(1).max(8_000) })
          .strict(),
        execute: async (value) => value,
      }),
      "show-sticker": tool({
        description:
          "Show the current sticker inline in chat as an attachment without changing it.",
        inputSchema: z
          .object({ caption: z.string().trim().min(1).max(1_000) })
          .strict(),
        execute: async (value) => value,
      }),
    };
    const result = await generateText({
      model: this.chatModel ?? gateway(process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
      system: [
        "You are Sticker Factory's tool-routing agent.",
        "Choose exactly one tool from the user's natural-language request; the app has no edit mode, animation mode, or layer picker.",
        // Every other rule here selects between mutations, which on its own reads as "the user always
        // wants a change". Questions are a large share of real turns, so the not-a-change case has to
        // come first and be stated as strongly as the rest.
        "First decide whether the user is asking for a change to the sticker at all.",
        "If they are not — a question about the sticker or about you, a comment, feedback, thanks,",
        "small talk, or anything you are unsure about — call reply. Questions such as 'who is this?',",
        "'what is that?', 'what can you do?', or 'why does it look like that?' are answered with reply,",
        "never by generating or editing.",
        "Only pick generate-sticker, generate-image, generate-video, edit-sticker, animate-sticker, or plan-sticker when",
        "the user is actually asking for the artwork to change. Those tools discard the current candidate,",
        "so a wrong guess loses the user's work; when in doubt, reply and ask what they want.",
        "Use show-sticker when the user asks to see or preview the current sticker without changing it.",
        "Separate the three ways artwork can change. generate-sticker redraws the whole sticker and",
        "keeps nothing. generate-image draws one new element on a transparent background and adds it",
        "as its own layer, leaving the existing layers alone — this is the right tool for 'add a…',",
        "'put a… next to it', or 'give it a…'. edit-sticker changes the sticker that is already there.",
        "edit-sticker owns the whole layer stack, not just the drawn artwork: removing a caption,",
        "rewording or recolouring text, resizing or reordering a layer, and redrawing an image are all",
        "edit-sticker, and any layer id may be passed as targetLayerId whatever its type.",
        "Use animate-sticker only for animated projects. Prefer the user's exact instruction and omit targetLayerId unless they clearly name one of the supplied layer ids.",
        "When a reference image is attached and the user requests a change, use edit-sticker.",
        "The labeled project images are visible and usable even when the latest message has no new",
        "attachment. If one is the previous plan's static reference and the user says to use the",
        "plan image or static reference, this is a change request: choose generate-sticker,",
        "generate-image, or edit-sticker as appropriate and set usePlanImage to true. Do not call",
        "reply to claim the image is unavailable or ask the user to upload it again.",
        "Decide between animate-sticker and plan-sticker by what the requested motion needs.",
        "When generate-video is available, use it for explicit video requests or motion that needs new",
        "frames, such as talking, wing flapping, or turning to another viewing angle. Do not route those",
        "requests to keyframes or planning when an existing image layer can be animated into a clip.",
        "When describing your capabilities, include video generation if generate-video is available.",
        "Video needs an animated project with an image layer and no existing clip; static projects cannot play it.",
        "animate-sticker only re-keyframes the layers listed in the current document, so it can only move,",
        "scale, rotate, or fade artwork that already exists as its own layer.",
        "If the effect needs elements to appear, build up, or move one at a time — a typewriter or",
        "letter-by-letter reveal, a word spelling itself out, characters entering in sequence — and those",
        "elements are not already separate layers in the current document, use plan-sticker instead:",
        "it designs the sticker as one layer per element so each can be animated on its own.",
        "Never promise a per-element effect that animate-sticker cannot produce.",
        "plan-sticker is the last resort for an existing sticker, because it only drafts a design the",
        "user then has to confirm. Restructuring a sticker one layer at a time — removing a layer,",
        "swapping one kind of layer for another, laying them out differently — is edit-sticker, which",
        "does it in place and in one turn. Keep plan-sticker for a sticker that has to be rebuilt as a",
        "new set of independently moving parts, and never reach for generate-sticker to change a",
        "sticker that exists: it throws every layer away and redraws from nothing.",
        // The kind is the project's whole contract with the user: they picked "animated" before they
        // typed a word, and a flat image cannot be keyframed into anything, so a generate on an
        // unplanned animated project silently delivers the static sticker they did not ask for.
        "The sticker kind below is the user's standing choice for this project, not a detail of this turn.",
        "On a static project the sticker never moves: never call animate-sticker or plan-sticker for motion.",
        "On an animated project the finished sticker has to move, and only layers can be keyframed.",
        "So when an animated project has no plan yet, design it with plan-sticker rather than drawing it",
        "with generate-sticker. An existing image layer can still be animated into a clip with generate-video.",
      ].join(" "),
      messages: userTurn([
        `Sticker kind: ${input.stickerKind}`,
        `Planned as layers already: ${input.hasPlan ? "yes" : "no"}`,
        priorArtNote(priorArt),
        `Attached reference images: ${input.attachmentCount}`,
        attachedImagesNote(
          viewable.length,
          "Route on what they actually are: a photo of a person or a pet is a subject to build the"
          + " sticker from, a screenshot of a sticker is a style to match, and a picture attached to"
          + " a question is usually still a question.",
        ),
        input.document
          ? `Current StickerDocument: ${JSON.stringify(input.document)}`
          : "There is no current sticker document.",
        `Recoverable chat history:\n${input.history}`,
        `Latest user message:\n${input.instruction}`,
      ].filter(Boolean).join("\n\n"), [...priorArt.map((visual) => visual.image), ...viewable]),
      tools,
      toolChoice: "required",
      maxRetries: 2,
      abortSignal: AbortSignal.timeout(90_000),
    });
    await recordTextApiCost(result);
    if (result.toolCalls.length !== 1)
      throw new Error("Sticker chat agent must return exactly one tool call");
    const call = result.toolCalls[0];
    if (!call) throw new Error("Sticker chat agent returned no tool call");
    switch (call.toolName) {
      case "generate-video": {
        if (videoLayers.length === 0) throw new Error("Video generation is unavailable for this sticker");
        const value = videoInput.parse(call.input);
        return { type: "generate_video", instruction: value.motion, layerId: value.layerId, durationSeconds: value.durationSeconds };
      }
      case "reply": {
        const value = z.object({ message: z.string() }).parse(call.input);
        return { type: "reply", message: value.message };
      }
      case "generate-sticker": {
        const value = z.object({ instruction: z.string(), usePlanImage: z.boolean().optional() }).parse(call.input);
        return { type: "generate", instruction: value.instruction, usePlanImage: value.usePlanImage };
      }
      case "generate-image": {
        const value = z.object({ instruction: z.string(), usePlanImage: z.boolean().optional() }).parse(call.input);
        return { type: "generate_image", instruction: value.instruction, usePlanImage: value.usePlanImage };
      }
      case "edit-sticker": {
        const value = z
          .object({
            instruction: z.string(),
            imagePlacement: z.enum(["replace", "add"]),
            targetLayerId: z.string().optional(),
            usePlanImage: z.boolean().optional(),
          })
          .parse(call.input);
        return resolveChatAction(
          {
            type: "edit",
            instruction: value.instruction,
            imagePlacement: value.imagePlacement,
            targetLayerId: value.targetLayerId,
            usePlanImage: value.usePlanImage,
          },
          input.document,
        );
      }
      case "animate-sticker": {
        const value = z
          .object({
            instruction: z.string(),
            targetLayerId: z.string().optional(),
          })
          .parse(call.input);
        return resolveChatAction(
          {
            type: "animate",
            instruction: value.instruction,
            targetLayerId: value.targetLayerId,
          },
          input.document,
        );
      }
      case "plan-sticker": {
        const value = z.object({ instruction: z.string() }).parse(call.input);
        return { type: "plan", instruction: value.instruction };
      }
      case "show-sticker": {
        const value = z.object({ caption: z.string() }).parse(call.input);
        return { type: "show", caption: value.caption };
      }
    }
    throw new Error(`Unsupported sticker chat tool: ${String(call.toolName)}`);
  }

  async planSticker(
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
      model: gateway(process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
      system: [
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
        "Layers. At most 8. Every layer picks its own source. The seven options are:",
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
        '"Hello World" is two layers, not eleven. A plan may use at most 8 layers, so one layer',
        "per letter only works for very short words, and cramming a phrase into it produces uneven",
        "spacing and unreadably small type. Lay the chunks out left to right with each chunk's width",
        "roughly proportional to its length so the spacing between them looks even, and leave a",
        "visible gap between neighbouring chunks or the words run together into one string.",
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
        input.rejectedReasons.length > 0
          ? `The user already turned down earlier plans for these reasons — do not repeat them:\n${input.rejectedReasons
              .map((reason) => `- ${reason}`)
              .join("\n")}`
          : "",
        `Recoverable chat history:\n${input.history}`,
        `Latest user request:\n${input.instruction}`,
      ]
        .filter(Boolean)
        .join("\n\n"), [...priorArt.map((visual) => visual.image), ...viewable]),
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

  async generateStickerVideo(input: AiVideoInput): Promise<AiVideoOutput> {
    const trace = {
      model: VIDEO_MODEL,
      resolution: VIDEO_RESOLUTION,
      durationSeconds: input.durationSeconds,
      keyColor: input.keyColor.name,
    };
    const result = await traceSpan("gateway.video", trace, () => generateVideo({
      model: gateway.videoModel(VIDEO_MODEL),
      prompt: { image: input.imageUrl, text: videoInstruction(input) },
      aspectRatio: "1:1",
      resolution: VIDEO_RESOLUTION,
      duration: input.durationSeconds,
      fps: VIDEO_FPS,
      // One retry, not two: a clip is minutes of wall clock and every attempt is metered.
      maxRetries: 1,
      abortSignal: AbortSignal.timeout(VIDEO_TIMEOUT_MS),
      poll: { intervalMs: 5_000, timeoutMs: VIDEO_TIMEOUT_MS },
    }));
    if (result.warnings.length > 0) {
      // A rejected `resolution` or `aspectRatio` string comes back here rather than as an error,
      // and the clip arrives at whatever the model chose instead. Worth a line: it is the one
      // signal that the model card and this code have drifted apart.
      traceEvent("gateway.video:warnings", { ...trace, warnings: result.warnings });
    }
    const priced = await recordVideoApiCost(result, {
      modelId: VIDEO_MODEL,
      resolution: VIDEO_RESOLUTION,
      durationSeconds: input.durationSeconds,
    });
    if (priced === "estimate") traceEvent("gateway.video:estimatedCost", trace);
    return {
      bytes: result.video.uint8Array,
      mimeType: result.video.mediaType || "video/mp4",
      modelId: VIDEO_MODEL,
    };
  }

  async generateConceptImage(input: {
    prompt: string;
    references: Array<{ bytes: Uint8Array; mimeType: string }>;
  }): Promise<AiImageOutput> {
    if (input.references.length > 0) {
      return this.generateStickerImage({
        prompt: [
          input.prompt,
          "Render the complete polished static sticker composition shown by this plan. Preserve",
          "the subjects and likenesses from the supplied references in one coherent resting pose.",
        ].join(" "),
        references: input.references,
        mode: "generate",
        // A reference is the frame the separated parts are measured against, so it keeps its own.
        keepFrame: true,
      });
    }
    // Opaque on purpose. The reference is a picture *of* the complete sticker, not one of the
    // transparent parts later extracted from it, so it skips the part-generation alpha gate.
    const result = await generateImage({
      model: gateway.imageModel(
        process.env.AI_IMAGE_MODEL ?? "openai/gpt-image-2",
      ),
      prompt: [
        input.prompt,
        "Render one polished static image of the finished sticker on a plain light background.",
        "Show the complete approved resting composition in one coherent illustration, not a rough",
        "sketch. Do not draw multiple poses, animation frames, a grid, contact sheet, captions,",
        "labels, arrows, watermarks, or UI chrome.",
      ].join(" "),
      n: 1,
      size: "1024x1024",
      maxRetries: 1,
      // Same model as the sticker path, so the same budget: 120s never let a static reference finish, and
      // a plan silently losing its picture every time is not the "best effort" this was meant to be.
      abortSignal: AbortSignal.timeout(IMAGE_TIMEOUT_MS),
    });
    await recordImageApiCost(result);
    const bytes = await sharp(Buffer.from(result.image.uint8Array))
      .resize(1024, 1024, {
        fit: "contain",
        background: { r: 255, g: 255, b: 255, alpha: 1 },
      })
      .png({ compressionLevel: 9 })
      .toBuffer();
    return { bytes: new Uint8Array(bytes), mimeType: "image/png" };
  }

  async showSticker(
    revisionId: string,
    kind: "static" | "animated",
    instruction: string,
    history: string,
  ): Promise<string> {
    const tools = {
      "show-sticker": tool({
        description:
          "Attach the completed sticker revision to the assistant's next chat message.",
        inputSchema: z
          .object({ caption: z.string().trim().min(1).max(1_000) })
          .strict(),
        execute: async (value) => value,
      }),
    };
    const result = await generateText({
      model: gateway(process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
      system:
        "A sticker revision is ready. Call show-sticker exactly once with a concise caption that says what changed and invites further natural-language refinement.",
      prompt: `Revision id: ${revisionId}\nSticker kind: ${kind}\nUser request: ${instruction}\nRecoverable chat history:\n${history}`,
      tools,
      toolChoice: { type: "tool", toolName: "show-sticker" },
      maxRetries: 2,
      abortSignal: AbortSignal.timeout(60_000),
    });
    await recordTextApiCost(result);
    if (result.toolCalls.length !== 1)
      throw new Error("Sticker agent must call show-sticker exactly once");
    const call = result.toolCalls[0];
    if (call.toolName !== "show-sticker")
      throw new Error("Sticker agent did not call show-sticker");
    return z.object({ caption: z.string() }).parse(call.input).caption;
  }

  async reply(instruction: string, history: string): Promise<string> {
    const result = await generateText({
      model: gateway(process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
      system:
        "You are Sticker Factory's concise creative assistant. Help refine the user's private sticker project. Never claim an edit was made unless an image or animation revision was actually created.",
      prompt: `Recoverable project transcript:\n${history}\n\nLatest user message:\n${instruction}`,
      maxRetries: 2,
      abortSignal: AbortSignal.timeout(90_000),
    });
    await recordTextApiCost(result);
    return result.text.trim();
  }

  async summarizeStickerTitle(input: AiTitleContext): Promise<string> {
    const result = await generateText({
      // A naming call sits between a finished turn and the client being told the turn finished, so
      // it runs on the cheapest model the deployment has rather than the orchestrator's.
      model: gateway(
        process.env.AI_SUMMARY_MODEL ??
          process.env.AI_ORCHESTRATOR_MODEL ??
          "openai/gpt-5.6",
      ),
      system: [
        "Name a sticker project from its chat transcript. Reply with the name alone:",
        "two to five words, title case, no quotes, no trailing punctuation, at most 48 characters.",
        "Name the sticker — its subject and its mood — not the conversation about it.",
        "If the current name still describes the sticker, repeat it back unchanged.",
      ].join(" "),
      prompt: `Current name: ${input.currentTitle}\nSticker kind: ${input.stickerKind}\nProject transcript:\n${input.history}`,
      // One attempt over again: the turn is already finished and waiting on this, and the caller
      // keeps the old name when it fails.
      maxRetries: 1,
      abortSignal: AbortSignal.timeout(20_000),
    });
    await recordTextApiCost(result);
    return result.text.trim();
  }
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

class MockAiProvider implements AiProvider {
  async selectImageReferences(input: AiReferenceSelectionContext): Promise<number[]> {
    const required = input.candidates
      .map((candidate, index) => (candidate.required ? index : -1))
      .filter((index) => index >= 0);
    const optional = input.candidates
      .map((_, index) => index)
      .filter((index) => !required.includes(index));
    return [...required, ...optional].slice(0, input.maxReferences);
  }

  async generateStickerImage(input: AiImageInput): Promise<AiImageOutput> {
    const label = input.prompt.replace(/[<&>]/g, "").slice(0, 24) || "Sticker";
    const bytes = await sharp(
      Buffer.from(
        `<svg width="1024" height="1024" xmlns="http://www.w3.org/2000/svg"><rect width="1024" height="1024" fill="none"/><circle cx="512" cy="480" r="360" fill="#ff8fa3"/><circle cx="400" cy="430" r="35" fill="#231f20"/><circle cx="624" cy="430" r="35" fill="#231f20"/><path d="M390 570 Q512 670 634 570" fill="none" stroke="#231f20" stroke-width="28" stroke-linecap="round"/><text x="512" y="900" text-anchor="middle" font-family="system-ui" font-size="68" fill="#231f20">${label}</text></svg>`,
      ),
    )
      .png()
      .toBuffer();
    const normalized = await normalizeTransparentPng(bytes, {
      subjectCrop: !input.mask && !input.keepFrame,
    });
    return { bytes: normalized.bytes, mimeType: "image/png", subject: normalized.subject };
  }

  async refineStickerLayout(
    _input: AiLayoutContext,
    session: LayoutDraftingSession,
  ): Promise<LayoutTurnResult | undefined> {
    // Exercise the same mandatory look-before-finalize contract without making tests invent visual
    // judgements. Focused tests cover corrections through the layout session itself.
    if (session.viewPlanImage) await session.viewPlanImage();
    await session.renderSticker();
    const finalized = await session.finalizeLayout();
    return { revision: finalized.revision, finalized: true };
  }
  /**
   * Scripts the same create -> update -> finalize shape the real loop produces, so the integration
   * tests exercise the session callbacks and the transcript rows they write.
   *
   * The update restates the scale operations alongside the new rotation ones, because an update is
   * applied to the base document: sending rotation alone would drop the scale motion the create
   * landed, which is exactly the mistake the tool description warns the real model about.
   */
  async animateSticker(
    input: AiAnimationContext,
    session: AnimationDraftingSession,
  ): Promise<AnimateTurnResult | undefined> {
    // Key off the document's real layers so composed documents (part_0, part_1, …) are animated the
    // same way a single-layer `hero` document is, and honour the target so a multi-layer document
    // asked to animate one layer does not trip the session's own targeting guard.
    const layers = input.targetLayerId
      ? input.document.layers.filter(
          (layer) => layer.id === input.targetLayerId,
        )
      : input.document.layers;
    const scale = layers.map(
      (layer): StickerOperationV1 => ({
        op: "setScaleKeyframes",
        layerId: layer.id,
        keyframes: [
          { timeSeconds: 0, x: 0.9, y: 0.9, easing: "easeOut" },
          { timeSeconds: 1, x: 1.08, y: 1.08, easing: "springSoft" },
          { timeSeconds: 2, x: 0.9, y: 0.9, easing: "easeIn" },
        ],
      }),
    );
    const rotation = layers.map(
      (layer): StickerOperationV1 => ({
        op: "setRotationKeyframes",
        layerId: layer.id,
        keyframes: [
          { timeSeconds: 0, degrees: -5, easing: "easeOut" },
          { timeSeconds: 1, degrees: 5, easing: "easeInOut" },
          { timeSeconds: 2, degrees: -5, easing: "easeIn" },
        ],
      }),
    );

    const created = await session.createAnimation(scale);
    const updated = await session.updateAnimation(created.animationId, [
      ...scale,
      ...rotation,
    ]);
    // One layer given a bigger swell than the rest, sent on its own. The restated scale and rotation
    // above are not repeated: every other layer keeps the motion the update landed, which is the
    // whole of what this tool is for.
    const edited = await session.editLayerAnimation(updated.animationId, layers[0].id, [
      {
        op: "setScaleKeyframes",
        layerId: layers[0].id,
        keyframes: [
          { timeSeconds: 0, x: 0.9, y: 0.9, easing: "easeOut" },
          { timeSeconds: 1, x: 1.2, y: 1.2, easing: "springBouncy" },
          { timeSeconds: 2, x: 0.9, y: 0.9, easing: "easeIn" },
        ],
      },
      rotation[0],
    ]);
    const finalized = await session.finalizeAnimation(edited.animationId);
    return {
      animationId: finalized.animationId,
      revision: finalized.revision,
      finalized: true,
    };
  }
  /**
   * Scripts one landed change followed by a finalize, so the integration tests exercise the session
   * callbacks and the transcript rows they write.
   *
   * Which change it makes is keyed off the request the same way the real model is asked to read it:
   * the free operation when the words ask for a removal, a clip when the words ask for motion no
   * keyframe can express, new artwork when the router said `add` or when there is no artwork to
   * work from, and otherwise a redraw of the targeted image layer — which is the whole of what the
   * edit turn could do before it became a loop.
   */
  async editSticker(
    input: AiEditContext,
    session: EditDraftingSession,
  ): Promise<EditTurnResult | undefined> {
    const normalized = input.instruction.toLowerCase();
    const named = input.targetLayerId
      ? input.document.layers.find((layer) => layer.id === input.targetLayerId)
      : undefined;
    const appDrawn = named && named.type !== "image"
      ? named
      : input.document.layers.find((layer) => layer.type !== "image");
    const artwork = named?.type === "image"
      ? named
      : input.document.layers.find((layer) => layer.type === "image");

    if (/\b(remove|delete|drop)\b/.test(normalized) && appDrawn) {
      await session.applyOperations([{ op: "removeLayer", layerId: appDrawn.id }]);
    // Read off the words the way the real loop's prompt tells it to: a request for an angle change
    // is the one thing keyframes cannot serve, so it is the one that buys a clip.
    } else if (artwork && input.document.kind === "animated" && /\b(turnaround|turntable|spin all the way|clip|video)\b/.test(normalized)) {
      await session.createVideoLayer({
        layerId: artwork.id,
        motion: input.instruction,
        durationSeconds: 2,
      });
    } else if (input.imagePlacement === "add" || !artwork) {
      await session.addImageLayer({ prompt: input.instruction, name: "Generated layer" });
      // Artwork standing in for an app-drawn layer the user named: the layer it replaces goes too.
      if (!artwork && named && named.type !== "image") {
        await session.applyOperations([{ op: "removeLayer", layerId: named.id }]);
      }
    } else {
      await session.editImageLayer({ layerId: artwork.id, prompt: input.instruction });
    }

    const finalized = await session.finalizeEdit();
    return { revision: finalized.revision, finalized: true };
  }

  async generateConceptImage(input: {
    prompt: string;
    references: Array<{ bytes: Uint8Array; mimeType: string }>;
  }): Promise<AiImageOutput> {
    const label = input.prompt.replace(/[<&>]/g, "").slice(0, 24) || "Concept";
    const bytes = await sharp(
      Buffer.from(
        `<svg width="1024" height="1024" xmlns="http://www.w3.org/2000/svg"><rect width="1024" height="1024" fill="#f4f0ff"/><rect x="96" y="96" width="832" height="640" rx="32" fill="none" stroke="#7c3aed" stroke-width="8" stroke-dasharray="24 16"/><text x="512" y="860" text-anchor="middle" font-family="system-ui" font-size="56" fill="#3b2a5a">${label}</text></svg>`,
      ),
    )
      .png()
      .toBuffer();
    return { bytes: new Uint8Array(bytes), mimeType: "image/png" };
  }

  /**
   * A checked-in one-second clip: 480x480, 24 fps, H.264, a red square sliding across pure green.
   *
   * Real bytes rather than a stub, because everything downstream of the provider is the part worth
   * testing — `inspectMp4` has to accept the container, the asset row has to carry its timing, and
   * the document's fps has to be raised to match.
   */
  async generateStickerVideo(): Promise<AiVideoOutput> {
    const bytes = await readFile(path.join(process.cwd(), "fixtures", "video-480.mp4"));
    return { bytes: new Uint8Array(bytes), mimeType: "video/mp4", modelId: "mock/video" };
  }

  /**
   * Scripts the same create -> update -> show -> finalize shape the real loop produces, so the
   * integration tests exercise the session callbacks and the transcript rows they write.
   *
   * An instruction that asks for a turnaround plans its first layer as a `video` source, so the
   * build path's clip branch is exercised end to end.
   */
  async planSticker(
    input: AiPlanContext,
    session: PlanDraftingSession,
  ): Promise<PlanTurnResult | undefined> {
    // Deterministic so integration tests can assert exact layer ids and layout.
    const tokens = (
      input.instruction.match(/[\p{L}\p{N}]/gu) ?? ["A", "B"]
    ).slice(0, 8);
    const characters = tokens.length >= 2 ? tokens : ["A", "B"];
    const animated = input.stickerKind === "animated";
    const wantsClip = animated && /\b(rotat(?:e|es|ing)|spin(?:s|ning)?|turn(?:s|around|table)?)\b/i.test(input.instruction);
    // Mirrors the instruction the real planner is given: revising a sticker keeps the artwork it
    // already has, so the leading layers reuse it and only the surplus is drawn.
    const reusable = reusableAssetIds(input.document);
    const build = (staggered: boolean): PlanV1 =>
      PlanV1Schema.parse({
        version: 1,
        title: "Planned sticker",
        summary: wantsClip
          ? `Here is a plan with ${characters.length} layers; the first is generated as a video so it can turn around. Confirm to build it.`
          : `Here is a plan with ${characters.length} layers. Confirm to build it.`,
        kind: input.stickerKind,
        conceptPrompt: animated
          ? `A polished sticker spelling ${characters.join("").toUpperCase()}, with every character arranged left to right in one coherent bold style.`
          : undefined,
        timing: { durationSeconds: 2, fps: 30, loop: "loop" },
        layers: characters.map((token, index, all) => ({
          layerId: `part_${index}`,
          name: token.toUpperCase(),
          source: wantsClip && index === 0
            ? {
                kind: "video",
                prompt: `The single character "${token}" as a bold sticker letter filling the frame on a transparent background.`,
                motion: "A slow full turnaround, one complete rotation.",
                durationSeconds: 2,
              }
            : reusable[index]
              ? { kind: "existing", assetId: reusable[index] }
              : {
                  kind: "generate",
                  prompt: `The single character "${token}" as a bold sticker letter filling the frame on a transparent background.`,
                },
          x: (index + 0.5) / all.length,
          y: 0.5,
          scaleX: Math.min(0.9, 1 / all.length),
          scaleY: 0.6,
          animations:
            animated && staggered
              ? [
                  {
                    type: "popIn",
                    delay: Math.min(index * 0.2, 1.5),
                    duration: 0.4,
                    easing: "springBouncy",
                  },
                ]
              : [],
        })),
      });

    const created = await session.createPlan(build(false));
    const updated = await session.updatePlan(created.planId, build(true));
    await session.showPlan(updated.planId);
    const finalized = await session.finalizePlan(updated.planId);
    return { ...finalized, finalized: true };
  }

  async routeChatTurn(input: AiChatContext): Promise<AiChatAction> {
    if (process.env.NODE_ENV !== "production" && process.env.STICKER_FACTORY_E2E === "true") {
      const { chatModel } = await import("@/e2e/support/chat-model");
      return new GatewayAiProvider(chatModel()).routeChatTurn(input);
    }
    const instruction = input.instruction.trim();
    const normalized = instruction.toLowerCase();
    if (/\b(show|preview|see|display)\b/.test(normalized)) {
      return { type: "show", caption: "Here is the current sticker." };
    }
    if (
      /\b(plan|compose|typewriter|letter by letter|one at a time|separately)\b/.test(
        normalized,
      )
    ) {
      return { type: "plan", instruction };
    }
    if (
      input.stickerKind === "animated" &&
      /\b(animate|bounce|move|motion|rotate|spin|wiggle|wave|wipe|reveal|shine|sweep|glow|bloom)\b/.test(
        normalized,
      )
    ) {
      return { type: "animate", instruction };
    }
    // Narrower than the edit branch below on purpose: "add" alone still means edit, so the mock only
    // routes to a new layer when the request says so in as many words.
    if (
      input.document &&
      /\b(layer|alongside|next to it|on top of it)\b/.test(normalized)
    ) {
      return { type: "generate_image", instruction };
    }
    if (
      input.attachmentCount > 0 ||
      /\b(add|change|create|draw|edit|generate|make|remove|replace|recolor|turn)\b/.test(
        normalized,
      )
    ) {
      return input.document
        ? resolveChatAction(
            { type: "edit", instruction, imagePlacement: "replace" },
            input.document,
          )
        : { type: "generate", instruction };
    }
    return {
      type: "reply",
      message: "Tell me what you would like to change, animate, or preview.",
    };
  }
  async showSticker(
    _revisionId: string,
    kind: "static" | "animated",
  ): Promise<string> {
    return kind === "animated"
      ? "I updated the animation and attached it here. Tell me what you want to refine next."
      : "I updated the sticker and attached it here. Tell me what you want to refine next.";
  }
  async reply(): Promise<string> {
    return "Tell me what you would like to change, or ask me to animate it.";
  }
  /**
   * Names the project after the user's own most recent words, which is both a plausible summary and
   * a deterministic one — a mock that renamed a sticker differently on every run would make the
   * workflow tests unwritable.
   */
  async summarizeStickerTitle(input: AiTitleContext): Promise<string> {
    const lastUserLine = input.history
      .split("\n")
      .filter((line) => line.startsWith("user: "))
      .at(-1);
    if (!lastUserLine) return input.currentTitle;
    const words = lastUserLine.slice("user: ".length).trim().split(/\s+/);
    const named = words
      .slice(0, 4)
      .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
      .join(" ");
    return named || input.currentTitle;
  }
}

let testProvider: AiProvider | undefined;
let provider: AiProvider | undefined;

export function setAiProviderForTests(value?: AiProvider): void {
  testProvider = value;
}

export function getAiProvider(): AiProvider {
  if (testProvider) return testProvider;
  if (
    process.env.NODE_ENV === "test" ||
    (process.env.NODE_ENV !== "production" &&
      process.env.STICKER_FACTORY_MOCK_SERVICES === "true")
  ) {
    testProvider = new MockAiProvider();
    return testProvider;
  }
  provider ??= new GatewayAiProvider();
  return provider;
}
