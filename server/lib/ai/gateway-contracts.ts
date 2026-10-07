import type { PET_CLASSES, PET_WEATHER_KINDS, PetIdentityV1, PetMemoryCategory, PetSignalsV1, PetThemeCategory } from "@/lib/contracts/api";
import type { DesignedTheme } from "@/lib/pets/themes";
import type { StickerControl, StickerControlValues } from "@/lib/contracts/configuration";
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
  /** What this image is to the drawing, e.g. "original or carried reference 1". Named to the image model in order. */
  label?: string;
}

export interface AiImageInput {
  prompt: string;
  references: AiReferenceImage[];
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
  sheet?: { columns: number; rows: number; count: number; facePlaceholder?: boolean; tiles?: boolean; faceRegion?: string; independentCells?: boolean };
  /** The image model's quality tier. Sheets ask for more than the default, since a cell is a third of the canvas. */
  quality?: "low" | "medium" | "high";
  /**
   * The project's style is pixel art: keep hard, grid-aligned pixels through normalization
   * (nearest-neighbour resampling and a binary alpha edge) instead of smoothing them.
   */
  pixelArt?: boolean;
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
  faceCompositing?: "overlay" | "masked";
  image: AiReferenceImage;
  /** Expression labels in cell order, for `expressions` sheets. */
  expressions?: string[];
  /** Actual body frame with the opening this expression patch must fill. */
  faceGuide?: AiReferenceImage;
}

export type AiSheetInspection =
  | { ok: true; faceFrames?: Array<{ faceX: number; faceY: number; faceSize: number }> }
  | { ok: false; problems: string[]; faceFrames?: Array<{ faceX: number; faceY: number; faceSize: number }> };

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
  /**
   * The user asked for the subject to travel around the canvas. Off by default, and like
   * `controllable` it was chosen with a switch rather than in words, so `instruction` will not
   * mention it either way.
   */
  motion: boolean;
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
  /** Recovers foreground-safe face masks from retained raw sprite sheets. No image generation. */
  repairSpriteFaces(input: { layerId: string }): Promise<EditDraftState>;
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

/**
 * What the pet-status pass is shown: the pet's own controls, the pose it is holding now, and the
 * sticker its owner just sent to someone.
 *
 * The sent sticker is the evidence, not the pet — it may be any sticker the user can send, posable
 * or not, and its picture is there so a sticker titled "IMG 2041" can still be read for its mood.
 */
/** When and where the owner is right now, so the pet can tell a sleepy midnight from a sunny noon. */
export interface AiOwnerMoment {
  /** The owner's local date and time, e.g. "Sunday 5 October, 21:40". */
  localTime?: string | null;
  /** Roughly where the owner is, as rounded coordinates the model can place. */
  location?: { latitude: number; longitude: number } | null;
}

export interface AiPetStatusContext extends AiOwnerMoment, AiPetRecall {
  petTitle: string;
  controls: StickerControl[];
  current: StickerControlValues | null;
  sent: { title: string; kind: "static" | "animated"; emoji: string | null; image: AiReferenceImage | null };
  /** Who the pet is and what it knows of the world; absent on pets from before identities. */
  identity?: PetIdentityV1 | null;
  signals?: PetSignalsV1 | null;
  stats?: { happiness: number; hp: number; energy: number };
  /** A random event that happened alongside the send, for the pet to mention. */
  event?: { title: string; detail: string } | null;
}

/** What the pet remembers that bears on the moment it is answering, most relevant first. */
export interface AiPetRecall {
  memories?: string[];
}

/** One thing that just happened between a pet and its owner, as its memory agent reads it. */
export interface AiPetMoment {
  kind: string;
  title: string;
  detail: string;
  /** ISO instant. */
  at: string;
}

/** A memory the pet already has, offered to its memory agent to keep, rewrite or forget. */
export interface AiPetMemory {
  id: string;
  content: string;
  category: PetMemoryCategory;
  importance: number;
}

export interface AiPetMemoryContext {
  petTitle: string;
  identity: PetIdentityV1 | null;
  moments: AiPetMoment[];
  /** The memories nearest to the moments by meaning; the only ones it may rewrite or forget. */
  memories: AiPetMemory[];
}

/** What the memory agent decided: a new note, a rewritten one, or one that is no longer true. */
export type AiPetMemoryOperation =
  | { op: "add"; content: string; category: PetMemoryCategory; importance: number }
  | { op: "update"; id: string; content: string; category: PetMemoryCategory; importance: number }
  | { op: "delete"; id: string };

/** The pose the pet should take, and a few words for the watch face to say about it. */
export interface AiPetStatus {
  values: StickerControlValues;
  caption: string;
  /** How often the app plays the pet's animation through once. Omitted keeps the app's default. */
  animateEverySeconds?: number;
  /** Lines to say after the caption, each `afterMinutes` after the one before. Omitted says nothing more. */
  musings?: { text: string; afterMinutes: number }[];
  /** How the sent sticker's mood moves the stats, each -8 to 8. Omitted means no change. */
  effects?: { happiness: number; hp: number; energy: number };
  /**
   * The pet decided this moment is worth growing from: a brief for the planner, asking for one new
   * item, with a pose and movement to go with it, on its own sticker. `redrawWeather` asks for its
   * weather to be drawn again once it has grown, for a growth that changes its whole look. Only ever
   * set when the context allowed it.
   */
  evolve?: { brief: string; redrawWeather?: boolean };
}

/** Whether the pet may decide to grow from this moment; see `AiPetStatus.evolve`. */
export interface AiPetEvolutionChoice {
  canEvolve?: boolean;
}

/** A sticker its owner just made, for the pet to notice — or, as often, to let pass. */
export interface AiPetStickerContext extends AiOwnerMoment {
  petTitle: string;
  identity: PetIdentityV1 | null;
  signals: PetSignalsV1 | null;
  stats: { happiness: number; hp: number; energy: number };
  controls: StickerControl[];
  current: StickerControlValues | null;
  made: { title: string; kind: "static" | "animated"; image: AiReferenceImage | null };
}

/** `react: false` leaves the pet as it was; otherwise a pose, a line and how it felt. */
export type AiPetStickerReaction = { react: false } | ({ react: true } & AiPetStatus);

/** What the model decides about a pet at adoption; the server turns it into numbers. */
export interface AiPetPersona {
  class: (typeof PET_CLASSES)[number];
  personality: string;
  likes: string[];
  dislikes: string[];
  favoriteWeather: (typeof PET_WEATHER_KINDS)[number];
}

export interface AiPetPersonaContext {
  petTitle: string;
  controls: StickerControl[];
  image: AiReferenceImage | null;
  /** The world the pet is born into, for flavour. */
  birth: PetSignalsV1;
}

/** Where to look for news: the owner's rough place and day, and what the pet cares about. */
export interface AiPetHeadlinesContext {
  timeZone: string | null;
  latitude: number | null;
  longitude: number | null;
  interests: string[];
  date: string;
}

/** Something that happened to the pet on its own — a life-workflow visit. */
export interface AiPetEventContext extends AiOwnerMoment, AiPetRecall {
  petTitle: string;
  identity: PetIdentityV1 | null;
  signals: PetSignalsV1;
  event: { title: string; detail: string };
  stats: { happiness: number; hp: number; energy: number };
  controls: StickerControl[];
  current: StickerControlValues | null;
}

export interface AiPetInteractionContext extends AiOwnerMoment, AiPetEvolutionChoice, AiPetRecall {
  petTitle: string;
  action: Pick<PetAction, "title" | "description">;
  stats: { happiness: number; hp: number; energy: number };
  controls: StickerControl[];
  current: StickerControlValues | null;
}

/** A picture the owner just showed their pet, for it to look at and react to. */
export interface AiPetPhotoContext extends AiOwnerMoment, AiPetEvolutionChoice, AiPetRecall {
  petTitle: string;
  photo: AiReferenceImage;
  identity: PetIdentityV1 | null;
  signals: PetSignalsV1 | null;
  stats: { happiness: number; hp: number; energy: number };
  controls: StickerControl[];
  current: StickerControlValues | null;
}

/** Article, HTML, text, or link the owner intentionally showed the pet. */
export interface AiPetSharedContentContext extends AiOwnerMoment {
  petTitle: string;
  identity: PetIdentityV1 | null;
  title: string | null;
  url: string | null;
  content: string | null;
  html: string | null;
  stats: { happiness: number; hp: number; energy: number };
  controls: StickerControl[];
  current: StickerControlValues | null;
}

/** Something the owner just said to their pet, and what it said back, for the pet to strike a pose to. */
export interface AiPetPoseContext extends AiOwnerMoment {
  petTitle: string;
  identity: PetIdentityV1 | null;
  stats: { happiness: number; hp: number; energy: number };
  controls: StickerControl[];
  current: StickerControlValues | null;
  words: string;
  reply: string | null;
}

/** The pose and expression the decision model picked; omitted controls keep their value. */
export interface AiPetPose {
  values: StickerControlValues;
  animateEverySeconds?: number;
}

/** What the agent knows when it writes the day's encounter for the pet. */
export interface AiPetEncounterContext extends AiOwnerMoment {
  petTitle: string;
  identity: PetIdentityV1 | null;
  signals: PetSignalsV1 | null;
  stats: { happiness: number; hp: number; energy: number; gold: number };
  /** What the pet is ill with, or null while it is well. */
  illness: string | null;
  mood: string | null;
  /** The titles of recent encounters, so a new day brings something new. */
  previous: string[];
}

/** A situation the owner has to decide, and what each choice leads to. */
export type AiPetEncounter = {
  title: string;
  prompt: string;
  choices: Array<{
    title: string;
    description: string;
    correct: boolean;
    outcome: string;
    effects: { happiness: number; hp: number; energy: number; gold: number };
    medicine: number;
    sickens: boolean;
  }>;
};

/**
 * What the pet's agent knows when it decides who the pet just met: the weather and where its owner
 * is, what it remembers, and how it feels. The friend should come out of that moment.
 */
export interface AiPetFriendContext extends AiOwnerMoment, AiPetRecall {
  petTitle: string;
  identity: PetIdentityV1 | null;
  signals: PetSignalsV1 | null;
  stats: { happiness: number; hp: number; energy: number };
  mood: string | null;
  /** What just happened on the visit the friend turned up on, when anything did. */
  happening?: string | null;
  /** The names of friends it already made, so a new one is someone new. */
  previous: string[];
}

/** A friend the pet just met: who they are, how they look for the artist, and how the pet introduces them. */
export type AiPetFriend = {
  name: string;
  brief: string;
  story: string;
  greeting: string;
};

/** A room the pet's agent dreamed up for its shop: what it is, what living there does, and its price. */
export type AiPetRoom = {
  title: string;
  description: string;
  /** What to draw: the room as a scene, for the image model. */
  scene: string;
  effects: { happiness: number; hp: number; energy: number };
  price: number;
};

/**
 * One room drawn as a full portrait background, in the pet's own art style. Its window glass is
 * flooded with `windowKey` so the server can cut it out and the app can show the live weather behind.
 */
export interface AiPetRoomArtInput {
  scene: string;
  reference: AiReferenceImage | null;
  windowKey: ChromaKeyColor;
}

/** A place the pet's agent discovered for it, before the server holds it to the rules. */
export type AiPetTheme = DesignedTheme;

/** What the pet's agent knows when it goes looking for new places. */
export interface AiPetThemeDiscoveryContext extends AiPetActionsContext {
  /** Places already known, so new ones are new. */
  known: Array<{ title: string; category: PetThemeCategory }>;
  /** Kinds of limited place the moment calls for, which must be among those found. */
  needs: Array<"travel" | "accident">;
  /** How many places to find, at most. */
  max: number;
  /** Whether the owner is far from home, and how far. */
  traveling: { distanceKm: number } | null;
  /** Whether the server knows where the owner is: a place pinned there is impossible without it. */
  hasLocation: boolean;
  illness?: string | null;
}

/** What the pet's agent weighs when it decides whether the pet should go somewhere else. */
export interface AiPetThemeChoiceContext extends AiOwnerMoment {
  petTitle: string;
  identity: PetIdentityV1 | null;
  signals: PetSignalsV1 | null;
  stats: { happiness: number; hp: number; energy: number };
  illness: string | null;
  traveling: boolean;
  /** Where the pet is now, and for how long; null at home. */
  current: { id: string; title: string; category: PetThemeCategory; minutesHere: number } | null;
  /** The places it could go right now. */
  candidates: Array<{ id: string; title: string; description: string; category: PetThemeCategory;
    effects: { happiness: number; hp: number; energy: number }; minutesLeftToday: number | null; expiresInHours: number | null }>;
}

/** Stay where it is, or go: to a place by id, or home with null. */
export type AiPetThemeChoice = { move: false } | { move: true; themeId: string | null; reason: string };

/** One place drawn as a full portrait background, in the pet's own art style. */
export interface AiPetThemeArtInput {
  scene: string;
  reference: AiReferenceImage | null;
}

export type PetAction = {
  id: string;
  title: string;
  description: string;
  effects: { happiness: number; hp: number; energy: number; gold: number };
  /** Items only: what kind of thing it is. */
  kind?: "food" | "ticket" | "toy";
  /** Shop items only: when it leaves the shelf. */
  leavesAt?: string;
  /** Items only: hours one keeps in the bag once bought, or null when it never expires. */
  keepsHours?: number | null;
};

/** An item the agent stocks the shop with: how long it stays on the shelf, and keeps once bought. */
export type AiPetItem = Omit<PetAction, "id" | "leavesAt" | "keepsHours"> & {
  kind: "food" | "ticket" | "toy";
  shelfHours: number;
  keepsHours: number | null;
};

/**
 * What the agent knows when it decides what the owner can do next. Everything but the pet itself
 * is optional: a pet just adopted has no mood yet, and its first actions come from its look alone.
 */
export interface AiPetActionsContext extends AiOwnerMoment {
  petTitle: string;
  controls: StickerControl[];
  image: AiReferenceImage | null;
  identity?: PetIdentityV1 | null;
  signals?: PetSignalsV1 | null;
  stats?: { happiness: number; hp: number; energy: number; gold?: number };
  /** What the pet is feeling or just went through, in a line. */
  mood?: string | null;
  /** The titles offered until now, so a refreshed list moves on instead of repeating itself. */
  previous?: string[];
}

/**
 * What the agent knows when it restocks the item shop: how many new things it may add — it picks
 * the number — and what is still on the shelf.
 */
export interface AiPetItemsContext extends AiPetActionsContext {
  minCount: number;
  maxCount: number;
  /** Items still on the shelf, which the new ones must differ from. */
  keeping: Omit<PetAction, "id">[];
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
  /**
   * Reads a sticker the user just sent and decides how their pet should look about it.
   *
   * Values the model invents are not trusted: the caller normalizes them against the pet's controls,
   * so an unknown option falls back to that control's default rather than reaching the watch.
   */
  choosePetStatus(input: AiPetStatusContext): Promise<AiPetStatus>;
  generatePetActions(input: AiPetActionsContext): Promise<Omit<PetAction, "id">[]>;
  generatePetItems(input: AiPetItemsContext): Promise<AiPetItem[]>;
  /** Dreams up the rooms the pet's shop offers, each with its own daily effect and price. */
  generatePetRooms(input: AiPetActionsContext): Promise<AiPetRoom[]>;
  /** Draws one room as the background the pet stands in. */
  generatePetRoomArt(input: AiPetRoomArtInput): Promise<AiImageOutput>;
  /** Looks for new places the pet could go, from its owner's world and what the moment calls for. */
  discoverPetThemes(input: AiPetThemeDiscoveryContext): Promise<AiPetTheme[]>;
  /** Decides whether the pet should go somewhere else now, or home. */
  choosePetTheme(input: AiPetThemeChoiceContext): Promise<AiPetThemeChoice>;
  /** Draws one place as the background the pet stands in. */
  generatePetThemeArt(input: AiPetThemeArtInput): Promise<AiImageOutput>;
  respondToPetInteraction(input: AiPetInteractionContext): Promise<AiPetStatus>;
  reactToPetPhoto(input: AiPetPhotoContext): Promise<AiPetStatus>;
  reactToPetSharedContent(input: AiPetSharedContentContext): Promise<AiPetStatus>;
  /** Picks the pose and expression the pet answers its owner's words with, on the decision model. */
  decidePetPose(input: AiPetPoseContext): Promise<AiPetPose>;
  /** Chooses a new pet's class, personality and preferences. */
  generatePetPersona(input: AiPetPersonaContext): Promise<AiPetPersona>;
  /** Up to three short headlines from a web search, for the pet to have heard about. */
  searchPetHeadlines(input: AiPetHeadlinesContext): Promise<string[]>;
  /** The pet's line and pose about something that just happened to it. */
  narratePetEvent(input: AiPetEventContext): Promise<AiPetStatus>;
  /** Writes the day's encounter: a situation the owner decides, with right and wrong choices. */
  generatePetEncounter(input: AiPetEncounterContext): Promise<AiPetEncounter>;
  /** Decides who the pet just met, from the weather, the place, its memories and its mood. */
  meetPetFriend(input: AiPetFriendContext): Promise<AiPetFriend>;
  /** The pet decides whether a sticker its owner just made is worth reacting to, and how. */
  noticePetSticker(input: AiPetStickerContext): Promise<AiPetStickerReaction>;
  /** One embedding per text, `PET_MEMORY_DIMENSIONS` wide, for storing and finding memories. */
  embedPetMemories(values: string[]): Promise<number[][]>;
  /** Reads what just happened beside what the pet remembers, and decides what to remember now. */
  updatePetMemory(input: AiPetMemoryContext): Promise<AiPetMemoryOperation[]>;
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
