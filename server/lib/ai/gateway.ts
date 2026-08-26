import { gateway } from "@ai-sdk/gateway";
import { getVercelOidcToken } from "@vercel/oidc";
import { generateImage, generateText, hasToolCall, Output, stepCountIs, streamText, tool } from "ai";
import sharp from "sharp";
import { z } from "zod";
import { PlanV1Schema, type PlanV1 } from "@/lib/contracts/plan";
import {
  StickerOperationsV1Schema,
  type StickerDocumentV1,
  type StickerOperationV1,
} from "@/lib/contracts/sticker";
import { ApiError } from "@/lib/http/errors";
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
  | { type: "edit"; instruction: string; imagePlacement: "add" | "replace"; targetLayerId?: string }
  | { type: "animate"; instruction: string; targetLayerId?: string }
  | { type: "plan"; instruction: string }
  | { type: "show"; caption: string };

export interface AiPlanContext {
  instruction: string;
  history: string;
  stickerKind: "static" | "animated";
  document?: StickerDocumentV1;
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
  updatePlan(planId: string, plan: PlanV1): Promise<{ planId: string; revision: number }>;
  showPlan(planId: string): Promise<{ planId: string; revision: number }>;
  finalizePlan(planId: string): Promise<{ planId: string; revision: number }>;
}

export type PlanTurnResult = { planId: string; revision: number; finalized: boolean };

export interface AiChatContext {
  instruction: string;
  history: string;
  stickerKind: "static" | "animated";
  document?: StickerDocumentV1;
  attachmentCount: number;
}

export interface AiProvider {
  generateStickerImage(input: AiImageInput): Promise<AiImageOutput>;
  /**
   * Drafts a sticker plan, revising it as many times as it needs before finalizing.
   *
   * Unlike every other method here this one is a real multi-step tool loop: the model decides how
   * many times to call `update_plan` and stops itself by calling `finalize_plan`.
   */
  planSticker(input: AiPlanContext, session: PlanDraftingSession): Promise<PlanTurnResult | undefined>;
  /**
   * Renders a storyboard of a proposed animation for the user to approve.
   *
   * Deliberately not `generateStickerImage`: that path is instructed never to draw a grid or a
   * contact sheet, which is exactly what a concept board is.
   */
  generateConceptImage(prompt: string): Promise<AiImageOutput>;
  /**
   * Plans a document's motion as a stream of operations.
   *
   * `rejection` carries the error a previous attempt's operations were refused with. The compiler's
   * messages name the offending specs and say what to change, so handing one back is what turns a
   * rejected plan into a repaired one — without it the retry is the same call and fails identically.
   */
  streamAnimationOperations(
    document: StickerDocumentV1,
    instruction: string,
    history: string,
    rejection?: string,
  ): AsyncIterable<StickerOperationV1>;
  routeChatTurn(input: AiChatContext): Promise<AiChatAction>;
  showSticker(revisionId: string, kind: "static" | "animated", instruction: string, history: string): Promise<string>;
  reply(instruction: string, history: string): Promise<string>;
}

/**
 * Reconciles a routed action with the document it will actually run against.
 *
 * The router is shown the whole document, so every layer id is pickable — including the text, shape,
 * and particle layers that the image tools cannot touch. Left alone, an `edit` naming one of those
 * reaches the workflow's image-layer guard and fails the turn over a word the user never typed, so
 * the routing mistakes are corrected into the tool that can serve the request instead.
 */
export function resolveChatAction(action: AiChatAction, document?: StickerDocumentV1): AiChatAction {
  if (action.type === "animate") {
    // Animation keyframes any layer type, so only an id naming nothing at all is unusable. Dropping
    // it animates the document as a whole, which is what an untargeted request asks for anyway.
    return action.targetLayerId && !document?.layers.some((layer) => layer.id === action.targetLayerId)
      ? { ...action, targetLayerId: undefined }
      : action;
  }
  if (action.type !== "edit") return action;
  const named = action.targetLayerId
    ? document?.layers.find((layer) => layer.id === action.targetLayerId)
    : undefined;
  // Text, shape, and particle layers are drawn by the app, not by the image model. Only planning can
  // change one — including swapping it for drawn artwork, which is what "make the text an image"
  // asks for — and a plan is proposed for confirmation, so nothing is lost if the guess was wrong.
  if (named && named.type !== "image") return { type: "plan", instruction: action.instruction };
  const imageLayers = document?.layers.filter((layer) => layer.type === "image") ?? [];
  // An id that names no layer at all is a hallucination rather than a choice: forget it and let the
  // edit fall back to the document's own image layer.
  const resolved = action.targetLayerId && !named ? { ...action, targetLayerId: undefined } : action;
  if (imageLayers.length > 0) return resolved;
  // There is no artwork to edit. Adding one drawn element is a generate-image, and on an empty
  // canvas a plain generate; anything else means the artwork the user is describing has to be
  // designed rather than edited.
  if (!document) return { type: "generate", instruction: action.instruction };
  return resolved.imagePlacement === "add"
    ? { type: "generate_image", instruction: action.instruction }
    : { type: "plan", instruction: action.instruction };
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
  if (input.references.length > 8) throw new ApiError(422, "TOO_MANY_REFERENCES", "At most 8 reference images are allowed");
  if (files.reduce((total, file) => total + file.bytes.byteLength, 0) > 32 * 1024 * 1024) {
    throw new ApiError(422, "AI_INPUT_TOO_LARGE", "Combined AI image inputs must not exceed 32 MB");
  }
  for (const file of files) {
    if (file.bytes.byteLength >= 50 * 1024 * 1024) {
      throw new ApiError(422, "AI_IMAGE_TOO_LARGE", "Each image input must be smaller than 50 MB");
    }
    if (!new Set(["image/png", "image/jpeg", "image/webp"]).has(file.mimeType)) {
      throw new ApiError(422, "UNSUPPORTED_AI_IMAGE", "AI image inputs must be PNG, JPEG, or WebP");
    }
  }
}

const transparentProviderOptions = {
  openai: {
    background: "transparent",
    output_format: "png",
    quality: "high",
  },
};

function dataUrl(file: { bytes: Uint8Array; mimeType: string }): string {
  return `data:${file.mimeType};base64,${Buffer.from(file.bytes).toString("base64")}`;
}

async function generateThroughResponses(input: AiImageInput): Promise<Uint8Array> {
  const key = await resolveGatewayToken();
  const content: Array<Record<string, unknown>> = [{
    type: "input_text",
    text: [
      "Edit the sticker according to the latest instruction.",
      "Return exactly one 1024x1024 PNG with a genuinely transparent background.",
      "Produce exactly one sticker subject. Never draw a grid, contact sheet, storyboard, film strip, or multiple frames or poses side by side.",
      "Preserve the main subject and any requested likeness from the supplied references.",
      input.conversationContext ? `Recoverable project context:\n${input.conversationContext}` : "",
      `Latest instruction: ${input.prompt}`,
    ].filter(Boolean).join("\n\n"),
  }];
  for (const reference of input.references) content.push({ type: "input_image", image_url: dataUrl(reference) });

  const response = await fetch(`${process.env.AI_GATEWAY_BASE_URL ?? "https://ai-gateway.vercel.sh/v1"}/responses`, {
    method: "POST",
    headers: { ...(key ? { authorization: `Bearer ${key}` } : {}), "content-type": "application/json" },
    body: JSON.stringify({
      model: process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6",
      input: [{ role: "user", content }],
      tools: [{
        type: "image_generation",
        background: "transparent",
        output_format: "png",
        quality: "high",
        size: "1024x1024",
      }],
      tool_choice: { type: "image_generation" },
    }),
    signal: AbortSignal.timeout(180_000),
  });
  if (!response.ok) {
    throw new Error(`AI Gateway Responses edit failed with HTTP ${response.status}`);
  }
  const body = await response.json() as {
    output?: Array<{ type?: string; result?: string; output?: string }>;
  };
  const image = body.output?.find((item) => item.type === "image_generation_call");
  const base64 = image?.result ?? image?.output;
  if (!base64) throw new Error("AI Gateway Responses edit returned no image candidate");
  return Uint8Array.from(Buffer.from(base64, "base64"));
}

async function generateThroughImageModel(input: AiImageInput): Promise<Uint8Array> {
  const prompt = input.references.length || input.mask
    ? {
      text: `${input.prompt}\nCreate a centered sticker with a genuinely transparent background. Produce exactly one sticker subject. Never draw a grid, contact sheet, storyboard, film strip, or multiple frames or poses side by side. Return PNG.`,
      images: input.references.map((item) => item.bytes),
      ...(input.mask ? { mask: input.mask.bytes } : {}),
    }
    : `${input.prompt}\nCreate a centered 1024x1024 sticker with a genuinely transparent background. Produce exactly one sticker subject. Never draw a grid, contact sheet, storyboard, film strip, or multiple frames or poses side by side. Return PNG.`;
  const result = await generateImage({
    model: gateway.imageModel(process.env.AI_IMAGE_MODEL ?? "openai/gpt-image-2"),
    prompt,
    n: 1,
    size: "1024x1024",
    maxRetries: 2,
    providerOptions: transparentProviderOptions,
    abortSignal: AbortSignal.timeout(180_000),
  });
  return result.image.uint8Array;
}

class GatewayAiProvider implements AiProvider {
  async generateStickerImage(input: AiImageInput): Promise<AiImageOutput> {
    assertImageInputBounds(input);
    if (input.mask) {
      if (!input.references[0]) throw new ApiError(422, "MASK_TARGET_REQUIRED", "Masked edits require a target image");
      const [target, mask] = await Promise.all([inspectImage(input.references[0].bytes), inspectImage(input.mask.bytes)]);
      if (target.mimeType !== mask.mimeType || target.width !== mask.width || target.height !== mask.height) {
        throw new ApiError(422, "MASK_DIMENSIONS_MISMATCH", "The mask and target image must have the same format and dimensions");
      }
      if (!mask.hasTransparentPixels || !mask.hasNonTransparentPixels) {
        throw new ApiError(422, "MASK_REQUIRES_ALPHA", "The mask must contain both transparent and painted alpha pixels");
      }
    }

    const first = input.mode === "conversation_edit" && !input.mask
      ? await generateThroughResponses(input)
      : await generateThroughImageModel(input);
    let normalized = await normalizeTransparentPng(first);

    if (!normalized.inspection.hasTransparentPixels) {
      const retry = await generateThroughImageModel({
        prompt: "Remove the entire background. Keep only the sticker subject with clean antialiased transparent edges; do not add a checkerboard.",
        references: [{ bytes: normalized.bytes, mimeType: "image/png" }],
        mode: "conversation_edit",
      });
      normalized = await normalizeTransparentPng(retry);
    }
    if (!normalized.inspection.hasTransparentPixels) {
      throw new ApiError(502, "OPAQUE_AI_OUTPUT", "Image generation did not produce a transparent sticker after retry");
    }
    return { bytes: normalized.bytes, mimeType: "image/png" };
  }

  async *streamAnimationOperations(
    document: StickerDocumentV1,
    instruction: string,
    history: string,
    rejection?: string,
  ): AsyncIterable<StickerOperationV1> {
    const result = streamText({
      model: gateway(process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
      output: Output.array({ element: StickerOperationsV1Schema.element }),
      system: [
        "You plan safe SwiftUI sticker animation changes.",
        "Return an array of allowlisted StickerOperationV1 operations validated by the provided schema.",
        "Strongly prefer setLayerAnimations: it takes named effects (fadeIn, popIn, slideIn, spin,",
        "wiggle, pulse, bounce, float, blurIn, hueShift, moveTo, scaleTo, rotateTo) with a delay and a",
        "duration in seconds, and the server compiles them into keyframes for you. Stagger layers by",
        "giving each a larger delay.",
        // The rule was already here in the abstract and was still broken constantly, always the same
        // way: an entrance and an idle effect both starting at 0. Naming that case and showing the
        // arithmetic is what makes it stick.
        "Two effects on one layer must never overlap in time if they drive the same property, and",
        "every effect must finish within the sticker's duration. An entrance and an idle effect are",
        "the usual trap: popIn, fadeIn, slideIn, blurIn, scaleTo and pulse, bounce, float, wiggle,",
        "spin all drive scale or position. Sequence them — popIn with delay 0 and duration 0.5 means",
        "the pulse after it starts at delay 0.5, not 0. Two effects on different layers, or on the",
        "same layer driving different properties, may overlap freely.",
        "Fall back to the raw setXKeyframes operations only for motion no named effect can express;",
        "their timeSeconds values are absolute seconds, never percentages or deltas, and they cannot",
        "be used on a layer that already has named animations.",
        "You may add validated text, shape, or allowlisted particle layers. Do not add/remove image layers or replace assets. Do not emit Swift, JavaScript, URLs, shaders, expressions, or external asset identifiers.",
        "Keep total document limits at 8 layers and 128 keyframes, duration 0.5-4s, and FPS <=30.",
      ].join(" "),
      prompt: [
        `Current StickerDocumentV1:\n${JSON.stringify(document)}`,
        `Recoverable chat history:\n${history}`,
        `Instruction:\n${instruction}`,
        // Last, so it is the freshest thing in context: this is a correction, not background.
        rejection
          ? "Your previous attempt at this was rejected by the compiler:\n"
            + `${rejection}\n`
            + "Plan the same motion again with that fixed. Do not repeat the rejected timing."
          : undefined,
      ].filter(Boolean).join("\n\n"),
      maxRetries: 2,
      abortSignal: AbortSignal.timeout(120_000),
    });
    let count = 0;
    for await (const operation of result.elementStream) {
      count += 1;
      yield validatePlannedAnimationOperation(operation);
    }
    if (count === 0) throw new Error("Animation planner returned no operations");
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
        inputSchema: z.object({ message: z.string().trim().min(1).max(2_000) }).strict(),
        execute: async (value) => value,
      }),
      "generate-sticker": tool({
        description: "Generate a new sticker candidate when no existing sticker should be preserved.",
        inputSchema: z.object({ instruction: z.string().trim().min(1).max(8_000) }).strict(),
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
        inputSchema: z.object({ instruction: z.string().trim().min(1).max(8_000) }).strict(),
        execute: async (value) => value,
      }),
      "edit-sticker": tool({
        description: [
          "Edit artwork that already exists in the current sticker from natural-language instructions.",
          "It redraws one image layer, so it only applies when the document has an image layer.",
          "Replace is the default; add creates another ordered image layer.",
        ].join(" "),
        inputSchema: z.object({
          instruction: z.string().trim().min(1).max(8_000),
          imagePlacement: z.enum(["replace", "add"]),
          targetLayerId: z.string().min(1).max(64).optional()
            .describe([
              "Id of the image layer to redraw. Only ids of layers with \"type\": \"image\" in the",
              "current document are valid — text, shape, and particle layers are drawn by the app and",
              "cannot be edited here. Omit this unless the user clearly names one of them.",
            ].join(" ")),
        }).strict(),
        execute: async (value) => value,
      }),
      "animate-sticker": tool({
        description: [
          "Add motion to an accepted animated sticker by keyframing the layers it already has.",
          "It can move, scale, rotate, fade, and apply effects to existing layers.",
          "It cannot create new artwork, so it cannot reveal elements that are not already separate",
          "layers — a word drawn inside one flat image cannot be typed out letter by letter.",
        ].join(" "),
        inputSchema: z.object({
          instruction: z.string().trim().min(1).max(8_000),
          targetLayerId: z.string().min(1).max(64).optional(),
        }).strict(),
        execute: async (value) => value,
      }),
      "plan-sticker": tool({
        description: [
          "Design a sticker as a set of independent layers before anything is generated: which",
          "layers exist, where each one sits, and how each one moves.",
          "Use this when the sticker needs elements that appear, move, or are positioned",
          "independently — per-letter text effects such as a typewriter reveal, multi-character",
          "scenes, staged reveals, or motion where different parts move at different times.",
          "Also use it for text, shape, or particle layers, which cannot be drawn as artwork.",
          "This only drafts a plan for the user to confirm; it does not generate anything.",
          "Prefer generate-sticker when one unified image would do.",
        ].join(" "),
        inputSchema: z.object({ instruction: z.string().trim().min(1).max(8_000) }).strict(),
        execute: async (value) => value,
      }),
      "show-sticker": tool({
        description: "Show the current sticker inline in chat as an attachment without changing it.",
        inputSchema: z.object({ caption: z.string().trim().min(1).max(1_000) }).strict(),
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
        "'put a… next to it', or 'give it a…'. edit-sticker changes artwork that is already there.",
        "edit-sticker only redraws image layers. A text, shape, or particle layer is drawn by the app,",
        "so never pass its id as targetLayerId: use generate-image when the user wants that element",
        "drawn as artwork instead, and plan-sticker when they want it restyled, reworded, or moved.",
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
      ].join(" "),
      prompt: [
        `Sticker kind: ${input.stickerKind}`,
        `Attached reference images: ${input.attachmentCount}`,
        input.document ? `Current StickerDocumentV1: ${JSON.stringify(input.document)}` : "There is no current sticker document.",
        `Recoverable chat history:\n${input.history}`,
        `Latest user message:\n${input.instruction}`,
      ].join("\n\n"),
      tools,
      toolChoice: "required",
      maxRetries: 2,
      abortSignal: AbortSignal.timeout(90_000),
    });
    if (result.toolCalls.length !== 1) throw new Error("Sticker chat agent must return exactly one tool call");
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
      const value = z.object({
        instruction: z.string(),
        imagePlacement: z.enum(["replace", "add"]),
        targetLayerId: z.string().optional(),
      }).parse(call.input);
      return resolveChatAction({
        type: "edit",
        instruction: value.instruction,
        imagePlacement: value.imagePlacement,
        targetLayerId: value.targetLayerId,
      }, input.document);
    }
    case "animate-sticker": {
      const value = z.object({ instruction: z.string(), targetLayerId: z.string().optional() }).parse(call.input);
      return resolveChatAction(
        { type: "animate", instruction: value.instruction, targetLayerId: value.targetLayerId },
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

  async planSticker(input: AiPlanContext, session: PlanDraftingSession): Promise<PlanTurnResult | undefined> {
    // Threaded through the tool bodies rather than read off the result, because the model refers to
    // the plan by id on every subsequent call and only the session knows the id it was given.
    let state: PlanTurnResult | undefined;

    const requirePlan = (planId: string) => {
      if (!state) throw new Error("Call create_plan before any other plan tool");
      if (state.planId !== planId) throw new Error(`Unknown plan id ${planId}; the current plan is ${state.planId}`);
      return state;
    };

    const tools = {
      create_plan: tool({
        description: "Create the first draft of the plan. Call this exactly once, before any other plan tool.",
        inputSchema: z.object({ plan: PlanV1Schema }).strict(),
        execute: async ({ plan }) => {
          if (state) throw new Error(`A plan already exists (${state.planId}); use update_plan to change it`);
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
        inputSchema: z.object({ planId: z.string().min(1), plan: PlanV1Schema }).strict(),
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
        "artwork with app-drawn text and effects. The four options are:",
        "  generate — artwork drawn from a prompt by an image model onto a transparent background.",
        "    This is the only source that can draw a subject: a character, creature, face, animal,",
        "    object, food, prop, scene element, or any illustration at all. Use one generate layer",
        "    per element that must move on its own — one per letter for a typewriter effect, one per",
        "    character for a scene. The prompt must describe a single element filling its frame edge",
        "    to edge on a transparent background, with no other elements and no text unless that",
        "    layer IS the text.",
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
        "Text layers. Give them equal scaleX and scaleY: a glyph is fitted inside its box without",
        "stretching, so unequal values only shrink it. Size a text layer by the box you want the",
        "words to occupy, not by their letter count.",
        "For a staged text reveal, split the phrase into at most 6 chunks and prefer whole words:",
        "\"Hello World\" is two layers, not eleven. There is a hard ceiling of 8 layers, so one layer",
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
        "and scaleTo drive scale, spin and wiggle and rotateTo drive rotation.",
        "Every animation must finish within the sticker's duration (delay + duration <= durationSeconds).",
        "Static stickers cannot carry any animations at all.",
        "",
        "The summary is shown to the user as your chat message: one or two friendly sentences.",
      ].join("\n"),
      prompt: [
        `Sticker kind: ${input.stickerKind}`,
        input.document
          ? `Current StickerDocumentV1: ${JSON.stringify(input.document)}`
          : "There is no current sticker document.",
        input.rejectedReasons.length > 0
          ? `The user already turned down earlier plans for these reasons — do not repeat them:\n${
            input.rejectedReasons.map((reason) => `- ${reason}`).join("\n")}`
          : "",
        `Recoverable chat history:\n${input.history}`,
        `Latest user request:\n${input.instruction}`,
      ].filter(Boolean).join("\n\n"),
      tools,
      toolChoice: "required",
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
      model: gateway.imageModel(process.env.AI_IMAGE_MODEL ?? "openai/gpt-image-2"),
      prompt: [
        prompt,
        "Draw this as a single flat concept sketch on a plain light background:",
        "a rough storyboard of how the finished sticker will look. Do not add captions, labels,",
        "arrows, watermarks, or UI chrome.",
      ].join(" "),
      n: 1,
      size: "1024x1024",
      maxRetries: 1,
      abortSignal: AbortSignal.timeout(120_000),
    });
    const bytes = await sharp(Buffer.from(result.image.uint8Array))
      .resize(1024, 1024, { fit: "contain", background: { r: 255, g: 255, b: 255, alpha: 1 } })
      .png({ compressionLevel: 9 })
      .toBuffer();
    return { bytes: new Uint8Array(bytes), mimeType: "image/png" };
  }

  async showSticker(revisionId: string, kind: "static" | "animated", instruction: string, history: string): Promise<string> {
    const tools = {
      "show-sticker": tool({
        description: "Attach the completed sticker revision to the assistant's next chat message.",
        inputSchema: z.object({ caption: z.string().trim().min(1).max(1_000) }).strict(),
        execute: async (value) => value,
      }),
    };
    const result = await generateText({
      model: gateway(process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
      system: "A sticker revision is ready. Call show-sticker exactly once with a concise caption that says what changed and invites further natural-language refinement.",
      prompt: `Revision id: ${revisionId}\nSticker kind: ${kind}\nUser request: ${instruction}\nRecoverable chat history:\n${history}`,
      tools,
      toolChoice: { type: "tool", toolName: "show-sticker" },
      maxRetries: 2,
      abortSignal: AbortSignal.timeout(60_000),
    });
    if (result.toolCalls.length !== 1) throw new Error("Sticker agent must call show-sticker exactly once");
    const call = result.toolCalls[0];
    if (call.toolName !== "show-sticker") throw new Error("Sticker agent did not call show-sticker");
    return z.object({ caption: z.string() }).parse(call.input).caption;
  }

  async reply(instruction: string, history: string): Promise<string> {
    const result = await generateText({
      model: gateway(process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
      system: "You are Sticker Factory's concise creative assistant. Help refine the user's private sticker project. Never claim an edit was made unless an image or animation revision was actually created.",
      prompt: `Recoverable project transcript:\n${history}\n\nLatest user message:\n${instruction}`,
      maxRetries: 2,
      abortSignal: AbortSignal.timeout(90_000),
    });
    return result.text.trim();
  }
}

export function validatePlannedAnimationOperation(operation: StickerOperationV1): StickerOperationV1 {
  if (operation.op === "replaceAsset" || operation.op === "removeLayer"
    || (operation.op === "addLayer" && operation.layer.type === "image")) {
    throw new ApiError(422, "UNSAFE_ANIMATION_OPERATION", "Animation planning cannot change image assets or layer ownership");
  }
  return operation;
}

class MockAiProvider implements AiProvider {
  async generateStickerImage(input: AiImageInput): Promise<AiImageOutput> {
    const label = input.prompt.replace(/[<&>]/g, "").slice(0, 24) || "Sticker";
    const bytes = await sharp(Buffer.from(
      `<svg width="1024" height="1024" xmlns="http://www.w3.org/2000/svg"><rect width="1024" height="1024" fill="none"/><circle cx="512" cy="480" r="360" fill="#ff8fa3"/><circle cx="400" cy="430" r="35" fill="#231f20"/><circle cx="624" cy="430" r="35" fill="#231f20"/><path d="M390 570 Q512 670 634 570" fill="none" stroke="#231f20" stroke-width="28" stroke-linecap="round"/><text x="512" y="900" text-anchor="middle" font-family="system-ui" font-size="68" fill="#231f20">${label}</text></svg>`,
    )).png().toBuffer();
    const normalized = await normalizeTransparentPng(bytes);
    return { bytes: normalized.bytes, mimeType: "image/png" };
  }
  async *streamAnimationOperations(document: StickerDocumentV1): AsyncIterable<StickerOperationV1> {
    // Key off the document's real layers so composed documents (part_0, part_1, …) are animated
    // the same way a single-layer `hero` document is.
    for (const layer of document.layers) {
      yield {
        op: "setScaleKeyframes",
        layerId: layer.id,
        keyframes: [
          { timeSeconds: 0, x: 0.9, y: 0.9, easing: "easeOut" },
          { timeSeconds: 1, x: 1.08, y: 1.08, easing: "springSoft" },
          { timeSeconds: 2, x: 0.9, y: 0.9, easing: "easeIn" },
        ],
      };
      yield {
        op: "setRotationKeyframes",
        layerId: layer.id,
        keyframes: [
          { timeSeconds: 0, degrees: -5, easing: "easeOut" },
          { timeSeconds: 1, degrees: 5, easing: "easeInOut" },
          { timeSeconds: 2, degrees: -5, easing: "easeIn" },
        ],
      };
    }
  }
  async generateConceptImage(prompt: string): Promise<AiImageOutput> {
    const label = prompt.replace(/[<&>]/g, "").slice(0, 24) || "Concept";
    const bytes = await sharp(Buffer.from(
      `<svg width="1024" height="1024" xmlns="http://www.w3.org/2000/svg"><rect width="1024" height="1024" fill="#f4f0ff"/><rect x="96" y="96" width="832" height="640" rx="32" fill="none" stroke="#7c3aed" stroke-width="8" stroke-dasharray="24 16"/><text x="512" y="860" text-anchor="middle" font-family="system-ui" font-size="56" fill="#3b2a5a">${label}</text></svg>`,
    )).png().toBuffer();
    return { bytes: new Uint8Array(bytes), mimeType: "image/png" };
  }

  /**
   * Scripts the same create -> update -> show -> finalize shape the real loop produces, so the
   * integration tests exercise the session callbacks and the transcript rows they write.
   */
  async planSticker(input: AiPlanContext, session: PlanDraftingSession): Promise<PlanTurnResult | undefined> {
    // Deterministic so integration tests can assert exact layer ids and layout.
    const tokens = (input.instruction.match(/[\p{L}\p{N}]/gu) ?? ["A", "B"]).slice(0, 8);
    const characters = tokens.length >= 2 ? tokens : ["A", "B"];
    const animated = input.stickerKind === "animated";
    const build = (staggered: boolean): PlanV1 => PlanV1Schema.parse({
      version: 1,
      title: "Planned sticker",
      summary: `Here is a plan with ${characters.length} layers. Confirm to build it.`,
      kind: input.stickerKind,
      timing: { durationSeconds: 2, fps: 30, loop: "loop" },
      layers: characters.map((token, index, all) => ({
        layerId: `part_${index}`,
        name: token.toUpperCase(),
        source: {
          kind: "generate",
          prompt: `The single character "${token}" as a bold sticker letter filling the frame on a transparent background.`,
        },
        x: (index + 0.5) / all.length,
        y: 0.5,
        scaleX: Math.min(0.9, 1 / all.length),
        scaleY: 0.6,
        animations: animated && staggered
          ? [{ type: "popIn", delay: Math.min(index * 0.2, 1.5), duration: 0.4, easing: "springBouncy" }]
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
    if (/\b(plan|compose|typewriter|letter by letter|one at a time|separately)\b/.test(normalized)) {
      return { type: "plan", instruction };
    }
    if (input.stickerKind === "animated" && /\b(animate|bounce|move|motion|rotate|spin|wiggle|wave)\b/.test(normalized)) {
      return { type: "animate", instruction };
    }
    // Narrower than the edit branch below on purpose: "add" alone still means edit, so the mock only
    // routes to a new layer when the request says so in as many words.
    if (input.document && /\b(layer|alongside|next to it|on top of it)\b/.test(normalized)) {
      return { type: "generate_image", instruction };
    }
    if (input.attachmentCount > 0 || /\b(add|change|create|draw|edit|generate|make|remove|replace|recolor|turn)\b/.test(normalized)) {
      return input.document
        ? resolveChatAction({ type: "edit", instruction, imagePlacement: "replace" }, input.document)
        : { type: "generate", instruction };
    }
    return { type: "reply", message: "Tell me what you would like to change, animate, or preview." };
  }
  async showSticker(_revisionId: string, kind: "static" | "animated"): Promise<string> {
    return kind === "animated"
      ? "I updated the animation and attached it here. Tell me what you want to refine next."
      : "I updated the sticker and attached it here. Tell me what you want to refine next.";
  }
  async reply(): Promise<string> { return "Tell me what you would like to change, or ask me to animate the accepted image."; }
}

let testProvider: AiProvider | undefined;
let provider: AiProvider | undefined;

export function setAiProviderForTests(value?: AiProvider): void { testProvider = value; }

export function getAiProvider(): AiProvider {
  if (testProvider) return testProvider;
  if (process.env.NODE_ENV === "test"
    || (process.env.NODE_ENV !== "production" && process.env.STICKER_FACTORY_MOCK_SERVICES === "true")) {
    testProvider = new MockAiProvider();
    return testProvider;
  }
  provider ??= new GatewayAiProvider();
  return provider;
}
