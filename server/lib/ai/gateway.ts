import { gateway } from "@ai-sdk/gateway";
import { getVercelOidcToken } from "@vercel/oidc";
import {
  generateImage,
  generateText,
  hasToolCall,
  stepCountIs,
  tool,
} from "ai";
import sharp from "sharp";
import { z } from "zod";
import { compactingPrepareStep } from "@/lib/ai/compaction";
import { viewStickerTool } from "@/lib/ai/view-sticker-tool";
import { countKeyframes } from "@/lib/animation/compile";
import { PlanV1Schema, reusableAssetIds, type PlanV1 } from "@/lib/contracts/plan";
import {
  StickerOperationV1Schema,
  type StickerDocument,
  type StickerOperationV1,
} from "@/lib/contracts/sticker";
import { ApiError } from "@/lib/http/errors";
import { traceEvent, traceSpan } from "@/lib/observability/trace";
import { inspectImage, normalizeTransparentPng } from "@/lib/storage/r2";

export interface AiImageInput {
  prompt: string;
  references: Array<{ bytes: Uint8Array; mimeType: string }>;
  mask?: { bytes: Uint8Array; mimeType: string };
  conversationContext?: string;
  mode: "generate" | "conversation_edit";
}

export interface AiImageOutput {
  bytes: Uint8Array;
  mimeType: "image/png";
  revisedPrompt?: string;
}

export type AiChatAction =
  | { type: "reply"; message: string }
  | { type: "generate"; instruction: string }
  /** Draws one new element on a transparent background and adds it as its own image layer. */
  | { type: "generate_image"; instruction: string }
  | {
      type: "edit";
      instruction: string;
      imagePlacement: "add" | "replace";
      targetLayerId?: string;
    }
  | { type: "animate"; instruction: string; targetLayerId?: string }
  | { type: "plan"; instruction: string }
  | { type: "show"; caption: string };

export interface AiPlanContext {
  instruction: string;
  history: string;
  stickerKind: "static" | "animated";
  document?: StickerDocument;
  /** Reasons the user gave for turning down earlier plans, so the agent does not repeat them. */
  rejectedReasons: string[];
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
  png: Uint8Array;
  /** The instants drawn, in document seconds. One entry for a static sticker. */
  times: number[];
  width: number;
  height: number;
};

/** Sessions that can show the model what it has built. Shared by the animate and edit loops. */
export interface RenderableSession {
  renderSticker(): Promise<StickerRenderResult>;
}

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
  /** Reference images the user attached to this turn. Every redraw is shown them. */
  attachmentCount: number;
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
   * Renders a storyboard of a proposed animation for the user to approve.
   *
   * Deliberately not `generateStickerImage`: that path is instructed never to draw a grid or a
   * contact sheet, which is exactly what a concept board is.
   */
  generateConceptImage(prompt: string): Promise<AiImageOutput>;
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
  if (!document) return { type: "generate", instruction: action.instruction };
  // An id that names no layer is a hallucination rather than a choice: forget it and let the edit
  // loop pick its own target from the layers the document really has.
  return action.targetLayerId &&
    !document.layers.some((layer) => layer.id === action.targetLayerId)
    ? { ...action, targetLayerId: undefined }
    : action;
}

/**
 * Resolves the credential the Gateway is called with, without requiring one to be configured.
 *
 * An explicit `AI_GATEWAY_API_KEY` is optional: on Vercel the platform mints an OIDC token, which
 * `getVercelOidcToken` reads from the request context or refreshes from a linked project locally.
 * Returning undefined is a valid outcome too — the AI SDK runs its own credential resolution, and an
 * unauthenticated call fails with the Gateway's own 401 instead of a preflight guess about env vars.
 */
async function resolveGatewayToken(): Promise<string | undefined> {
  if (process.env.AI_GATEWAY_API_KEY) return process.env.AI_GATEWAY_API_KEY;
  if (process.env.VERCEL_OIDC_TOKEN) return process.env.VERCEL_OIDC_TOKEN;
  try {
    return await getVercelOidcToken();
  } catch {
    return undefined;
  }
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

function dataUrl(file: { bytes: Uint8Array; mimeType: string }): string {
  return `data:${file.mimeType};base64,${Buffer.from(file.bytes).toString("base64")}`;
}

async function generateThroughResponses(
  input: AiImageInput,
): Promise<Uint8Array> {
  const key = await resolveGatewayToken();
  const content: Array<Record<string, unknown>> = [
    {
      type: "input_text",
      text: [
        "Edit the sticker according to the latest instruction.",
        "Return exactly one 1024x1024 PNG with a genuinely transparent background.",
        "Produce exactly one sticker subject. Never draw a grid, contact sheet, storyboard, film strip, or multiple frames or poses side by side.",
        "Preserve the main subject and any requested likeness from the supplied references.",
        input.conversationContext
          ? `Recoverable project context:\n${input.conversationContext}`
          : "",
        `Latest instruction: ${input.prompt}`,
      ]
        .filter(Boolean)
        .join("\n\n"),
    },
  ];
  for (const reference of input.references)
    content.push({ type: "input_image", image_url: dataUrl(reference) });

  const response = await fetch(
    `${process.env.AI_GATEWAY_BASE_URL ?? "https://ai-gateway.vercel.sh/v1"}/responses`,
    {
      method: "POST",
      headers: {
        ...(key ? { authorization: `Bearer ${key}` } : {}),
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6",
        input: [{ role: "user", content }],
        tools: [
          {
            type: "image_generation",
            background: "transparent",
            output_format: "png",
            quality: "high",
            size: "1024x1024",
          },
        ],
        tool_choice: { type: "image_generation" },
      }),
      signal: AbortSignal.timeout(IMAGE_TIMEOUT_MS),
    },
  );
  if (!response.ok) {
    throw new Error(
      `AI Gateway Responses edit failed with HTTP ${response.status}`,
    );
  }
  const body = (await response.json()) as {
    output?: Array<{ type?: string; result?: string; output?: string }>;
  };
  const image = body.output?.find(
    (item) => item.type === "image_generation_call",
  );
  const base64 = image?.result ?? image?.output;
  if (!base64)
    throw new Error("AI Gateway Responses edit returned no image candidate");
  return Uint8Array.from(Buffer.from(base64, "base64"));
}

async function generateThroughImageModel(
  input: AiImageInput,
): Promise<Uint8Array> {
  const prompt =
    input.references.length || input.mask
      ? {
          text: `${input.prompt}\nCreate a centered sticker with a genuinely transparent background. Produce exactly one sticker subject. Never draw a grid, contact sheet, storyboard, film strip, or multiple frames or poses side by side. Return PNG.`,
          images: input.references.map((item) => item.bytes),
          ...(input.mask ? { mask: input.mask.bytes } : {}),
        }
      : `${input.prompt}\nCreate a centered 1024x1024 sticker with a genuinely transparent background. Produce exactly one sticker subject. Never draw a grid, contact sheet, storyboard, film strip, or multiple frames or poses side by side. Return PNG.`;
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
  return result.image.uint8Array;
}

class GatewayAiProvider implements AiProvider {
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

    const throughResponses = input.mode === "conversation_edit" && !input.mask;
    const first = await traceSpan(
      "gateway.image",
      { path: throughResponses ? "responses" : "imageModel" },
      () =>
        throughResponses
          ? generateThroughResponses(input)
          : generateThroughImageModel(input),
    );
    // Between the model returning and the workflow storing the asset sits a decode, an alpha
    // trim, and a re-encode of a 1024x1024 PNG — CPU work, off the network, that the Gateway
    // dashboard cannot see. If the process dies in here the request looks complete and billed
    // while the turn never advances, so both normalize passes are timed separately.
    let normalized = await traceSpan(
      "gateway.normalize",
      { bytes: first.byteLength },
      () => normalizeTransparentPng(first),
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
        { bytes: retry.byteLength, retry: true },
        () => normalizeTransparentPng(retry),
      );
    }
    if (!normalized.inspection.hasTransparentPixels) {
      throw new ApiError(
        502,
        "OPAQUE_AI_OUTPUT",
        "Image generation did not produce a transparent sticker after retry",
      );
    }
    return { bytes: normalized.bytes, mimeType: "image/png" };
  }

  async animateSticker(
    input: AiAnimationContext,
    session: AnimationDraftingSession,
  ): Promise<AnimateTurnResult | undefined> {
    // Threaded through the tool bodies rather than read off the result, because the model refers to
    // the animation by id on every subsequent call and only the session knows the id it was given.
    let state: AnimateTurnResult | undefined;
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

    await generateText({
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
      prompt: [
        `Base StickerDocument:\n${JSON.stringify(input.document)}`,
        input.targetLayerId
          ? `Animate only the layer with id ${input.targetLayerId}. Every operation you send must name it.`
          : "",
        `Recoverable chat history:\n${input.history}`,
        `Instruction:\n${input.instruction}`,
      ]
        .filter(Boolean)
        .join("\n\n"),
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

    const guard = async (run: () => Promise<EditDraftState>) => {
      try {
        const landed = await run();
        state = { revision: landed.revision, finalized: false };
        return { revision: landed.revision, sticker: summarizeDocument(landed.document) };
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
          "removeLayer deletes a layer outright. reorderLayer changes what sits in front of what;",
          "later layers are drawn on top. renameLayer changes only the label.",
          "To change what a text layer says, or how any layer is styled, remove it and add the",
          "replacement in the same call at the same index, keeping the id, name, anchor, and",
          "animations you want it to carry over.",
          "To move, resize, or rotate a layer, send setLayerAnimations for it with its current",
          "animations and a new anchor — the anchor is where a layer rests, and this is the only",
          "operation that sets it.",
          "You cannot add an image layer or point one at a different asset here; artwork has to be",
          "drawn, so use add_image_layer and edit_image_layer for that.",
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
          "own image layer, leaving every existing layer untouched.",
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
              .max(7)
              .optional()
              .describe("Where in the stack to insert it. Omit to put it on top."),
            x: z.number().min(0).max(1).optional(),
            y: z.number().min(0).max(1).optional(),
            scaleX: z.number().min(0.05).max(2).optional(),
            scaleY: z.number().min(0.05).max(2).optional(),
          })
          .strict(),
        execute: async (value) => guard(() => session.addImageLayer(value)),
      }),
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

    await generateText({
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
        "Two of these tools spend money. edit_image_layer and add_image_layer each run an image model,",
        "which is slow and billed; edit_layers is free and instant. If the request can be served by",
        "moving, removing, restyling, or re-lettering layers, serve it with edit_layers alone.",
        "",
        "Layer types. image layers are drawn artwork and can only be changed by the two image tools.",
        "text, shape, and particle layers are drawn by the app from the document, so edit_layers can",
        "create and change them freely and they cost nothing.",
        "Layout. A layer's anchor is where it rests: position x and y are its normalized centre",
        "(0,0 is top-left, 1,1 is bottom-right) and scale is relative to a box covering 86% of the",
        "canvas. Keep layers on canvas and keep their boxes from overlapping unless the user wants",
        "them stacked.",
        "Motion. Animations are named effects with a delay and a duration in seconds; two on the same",
        "layer must not overlap in time if they drive the same property, and every one must finish",
        "within the sticker's duration. Static stickers cannot carry any animations at all.",
        "",
        "If a tool returns an error, read it and fix it — the error text says exactly what was wrong.",
        "Do not give up and do not send the same rejected operation again.",
      ].join(" "),
      prompt: [
        `Current StickerDocument:\n${JSON.stringify(input.document)}`,
        input.targetLayerId
          ? `The user is pointing at the layer with id ${input.targetLayerId}. Start there, and touch`
            + " another layer only if their words are about it."
          : "",
        input.imagePlacement === "add"
          ? "The request reads as wanting something new alongside what is already there, rather than a"
            + " change to existing artwork."
          : "",
        input.attachmentCount > 0
          ? `The user attached ${input.attachmentCount} reference image(s). Every redraw you ask for`
            + " is shown them, so say how they should be used."
          : "",
        `Recoverable chat history:\n${input.history}`,
        `Instruction:\n${input.instruction}`,
      ]
        .filter(Boolean)
        .join("\n\n"),
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

    if (fatal) throw fatal;
    return state;
  }

  async routeChatTurn(input: AiChatContext): Promise<AiChatAction> {
    const tools = {
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
        description:
          "Generate a new sticker candidate when no existing sticker should be preserved.",
        inputSchema: z
          .object({ instruction: z.string().trim().min(1).max(8_000) })
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
        ].join(" "),
        inputSchema: z
          .object({ instruction: z.string().trim().min(1).max(8_000) })
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
      model: gateway(process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
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
        "Only pick generate-sticker, generate-image, edit-sticker, animate-sticker, or plan-sticker when",
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
        "Decide between animate-sticker and plan-sticker by what the requested motion needs.",
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
        "with generate-sticker: one flat image has no separate parts and can never be animated afterwards.",
      ].join(" "),
      prompt: [
        `Sticker kind: ${input.stickerKind}`,
        `Planned as layers already: ${input.hasPlan ? "yes" : "no"}`,
        `Attached reference images: ${input.attachmentCount}`,
        input.document
          ? `Current StickerDocument: ${JSON.stringify(input.document)}`
          : "There is no current sticker document.",
        `Recoverable chat history:\n${input.history}`,
        `Latest user message:\n${input.instruction}`,
      ].join("\n\n"),
      tools,
      toolChoice: "required",
      maxRetries: 2,
      abortSignal: AbortSignal.timeout(90_000),
    });
    if (result.toolCalls.length !== 1)
      throw new Error("Sticker chat agent must return exactly one tool call");
    const call = result.toolCalls[0];
    switch (call.toolName) {
      case "reply": {
        const value = z.object({ message: z.string() }).parse(call.input);
        return { type: "reply", message: value.message };
      }
      case "generate-sticker": {
        const value = z.object({ instruction: z.string() }).parse(call.input);
        return { type: "generate", instruction: value.instruction };
      }
      case "generate-image": {
        const value = z.object({ instruction: z.string() }).parse(call.input);
        return { type: "generate_image", instruction: value.instruction };
      }
      case "edit-sticker": {
        const value = z
          .object({
            instruction: z.string(),
            imagePlacement: z.enum(["replace", "add"]),
            targetLayerId: z.string().optional(),
          })
          .parse(call.input);
        return resolveChatAction(
          {
            type: "edit",
            instruction: value.instruction,
            imagePlacement: value.imagePlacement,
            targetLayerId: value.targetLayerId,
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
          "satisfied with the design. Nothing is generated until the user confirms.",
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

    await generateText({
      model: gateway(process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
      system: [
        "You design stickers as a set of independent layers, then hand the design to the user.",
        "Work in this order: call create_plan once, revise with update_plan as many times as you need,",
        "optionally call show_plan, and finish by calling finalize_plan. Never call create_plan twice.",
        "If a tool returns an error, read it and fix the plan with update_plan — the error text says",
        "exactly what was wrong. Do not give up and do not repeat the same invalid plan.",
        "",
        "Layers. At most 8. Every layer picks its own source, and most good stickers mix drawn",
        "artwork with app-drawn text and effects. The five options are:",
        "  generate — artwork drawn from a prompt by an image model onto a transparent background.",
        "    This is the only source that can draw a subject: a character, creature, face, animal,",
        "    object, food, prop, scene element, or any illustration at all. Use one generate layer",
        "    per element that must move on its own — one per letter for a typewriter effect, one per",
        "    character for a scene. The prompt must describe a single element filling its frame edge",
        "    to edge on a transparent background, with no other elements and no text unless that",
        "    layer IS the text.",
        "  existing — an image layer the current sticker already has, reused exactly as it is and",
        "    free. Copy the assetId verbatim from an image layer of the current StickerDocument.",
        "  text — words drawn by the app in a system font.",
        "  shape — one fixed primitive: circle, roundedRectangle, star, heart, or burst.",
        "  particle — a preset field of sparkles, confetti, hearts, bubbles, or snow.",
        "Prefer text, shape, and particle for lettering, flat accents, and effects: they cost nothing",
        "and stay crisp at any size. That preference stops at illustration. A shape is a plain filled",
        "silhouette and a particle preset is a scatter of dots, so neither is ever a stand-in for",
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
        "Text layers. Give them equal scaleX and scaleY: a glyph is fitted inside its box without",
        "stretching, so unequal values only shrink it. Size a text layer by the box you want the",
        "words to occupy, not by their letter count.",
        "For a staged text reveal, split the phrase into at most 6 chunks and prefer whole words:",
        '"Hello World" is two layers, not eleven. A plan may use at most 8 layers, so one layer',
        "per letter only works for very short words, and cramming a phrase into it produces uneven",
        "spacing and unreadably small type. Lay the chunks out left to right with each chunk's width",
        "roughly proportional to its length so the spacing between them looks even, and leave a",
        "visible gap between neighbouring chunks or the words run together into one string.",
        "",
        "Layout. x and y are the layer's normalized centre (0,0 is top-left, 1,1 is bottom-right).",
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
      prompt: [
        `Sticker kind: ${input.stickerKind}`,
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
        input.rejectedReasons.length > 0
          ? `The user already turned down earlier plans for these reasons — do not repeat them:\n${input.rejectedReasons
              .map((reason) => `- ${reason}`)
              .join("\n")}`
          : "",
        `Recoverable chat history:\n${input.history}`,
        `Latest user request:\n${input.instruction}`,
      ]
        .filter(Boolean)
        .join("\n\n"),
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

    return state;
  }

  async generateConceptImage(prompt: string): Promise<AiImageOutput> {
    // Opaque on purpose. A storyboard is a picture *of* a sticker, not a sticker, so it skips both
    // the transparency provider options and the normalize/retry path that enforces an alpha channel.
    const result = await generateImage({
      model: gateway.imageModel(
        process.env.AI_IMAGE_MODEL ?? "openai/gpt-image-2",
      ),
      prompt: [
        prompt,
        "Draw this as a single flat concept sketch on a plain light background:",
        "a rough storyboard of how the finished sticker will look. Do not add captions, labels,",
        "arrows, watermarks, or UI chrome.",
      ].join(" "),
      n: 1,
      size: "1024x1024",
      maxRetries: 1,
      // Same model as the sticker path, so the same budget: 120s never let a storyboard finish, and
      // a plan silently losing its picture every time is not the "best effort" this was meant to be.
      abortSignal: AbortSignal.timeout(IMAGE_TIMEOUT_MS),
    });
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
    (operation.op === "addLayer" && operation.layer.type === "image")
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
  async generateStickerImage(input: AiImageInput): Promise<AiImageOutput> {
    const label = input.prompt.replace(/[<&>]/g, "").slice(0, 24) || "Sticker";
    const bytes = await sharp(
      Buffer.from(
        `<svg width="1024" height="1024" xmlns="http://www.w3.org/2000/svg"><rect width="1024" height="1024" fill="none"/><circle cx="512" cy="480" r="360" fill="#ff8fa3"/><circle cx="400" cy="430" r="35" fill="#231f20"/><circle cx="624" cy="430" r="35" fill="#231f20"/><path d="M390 570 Q512 670 634 570" fill="none" stroke="#231f20" stroke-width="28" stroke-linecap="round"/><text x="512" y="900" text-anchor="middle" font-family="system-ui" font-size="68" fill="#231f20">${label}</text></svg>`,
      ),
    )
      .png()
      .toBuffer();
    const normalized = await normalizeTransparentPng(bytes);
    return { bytes: normalized.bytes, mimeType: "image/png" };
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
   * the free operation when the words ask for a removal, new artwork when the router said `add` or
   * when there is no artwork to work from, and otherwise a redraw of the targeted image layer —
   * which is the whole of what the edit turn could do before it became a loop.
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

  async generateConceptImage(prompt: string): Promise<AiImageOutput> {
    const label = prompt.replace(/[<&>]/g, "").slice(0, 24) || "Concept";
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
   * Scripts the same create -> update -> show -> finalize shape the real loop produces, so the
   * integration tests exercise the session callbacks and the transcript rows they write.
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
    // Mirrors the instruction the real planner is given: revising a sticker keeps the artwork it
    // already has, so the leading layers reuse it and only the surplus is drawn.
    const reusable = reusableAssetIds(input.document);
    const build = (staggered: boolean): PlanV1 =>
      PlanV1Schema.parse({
        version: 1,
        title: "Planned sticker",
        summary: `Here is a plan with ${characters.length} layers. Confirm to build it.`,
        kind: input.stickerKind,
        timing: { durationSeconds: 2, fps: 30, loop: "loop" },
        layers: characters.map((token, index, all) => ({
          layerId: `part_${index}`,
          name: token.toUpperCase(),
          source: reusable[index]
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
