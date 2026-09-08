// The turns that produce artwork: picking which references a model sees, then drawing a
// sticker, a concept, or a clip.

import { createWebTools, isWebTool, WEB_RESEARCH_PROMPT } from "./web-tools";
import { researchGenerationPrompt } from "./generation-research";
import { gateway } from "@ai-sdk/gateway";
import { experimental_generateVideo as generateVideo, generateImage, generateText, hasToolCall, stepCountIs, tool } from "ai";
import sharp from "sharp";
import { z } from "zod";
import { recordImageApiCost, recordTextApiCost, recordVideoApiCost } from "@/lib/ai/cost";
import { ApiError } from "@/lib/http/errors";
import { traceEvent, traceSpan } from "@/lib/observability/trace";
import { downscaleForModelInput, inspectImage, normalizeTransparentPng } from "@/lib/storage/r2";
import type { AiImageInput, AiImageOutput, AiReferenceSelectionContext, AiVideoInput, AiVideoOutput } from "./gateway-contracts";
import { IMAGE_TIMEOUT_MS, VIDEO_FPS, VIDEO_MODEL, VIDEO_RESOLUTION, VIDEO_TIMEOUT_MS, assertImageInputBounds, generateKeyedStickerImage, generateThroughImageModel, userTurn, videoInstruction } from "./gateway-models";

export async function selectImageReferences(
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
      WEB_RESEARCH_PROMPT,
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
      ...createWebTools(),
      select_references: tool({
        description: "Select the candidate reference images that the image model should receive.",
        inputSchema: z.object({
          indices: z.array(z.number().int().min(0).max(input.candidates.length - 1))
            .max(input.maxReferences),
        }).strict(),
      }),
    },
    toolChoice: "required",
    stopWhen: [hasToolCall("select_references"), stepCountIs(8)],
    maxRetries: 2,
    abortSignal: AbortSignal.timeout(90_000),
  });
  await recordTextApiCost(result);
  const actionCalls = result.toolCalls.filter((call) => !isWebTool(call.toolName));
  if (actionCalls.length !== 1 || actionCalls[0].toolName !== "select_references") {
    throw new Error("Reference selector must call select_references exactly once");
  }
  const selected = z.object({ indices: z.array(z.number().int()) })
    .parse(actionCalls[0].input).indices;
  return [...new Set([...required, ...selected])]
    .filter((index) => index >= 0 && index < input.candidates.length)
    .slice(0, input.maxReferences);
}

export async function generateStickerImage(input: AiImageInput): Promise<AiImageOutput> {
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
  input = { ...input, prompt: await researchGenerationPrompt(input.prompt) };
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

export async function generateStickerVideo(input: AiVideoInput): Promise<AiVideoOutput> {
  // Sticker plans allow 2-4s, but Seedance 2.0 requires at least 4s, including i2v.
  // Normalize before building the prompt so request timing, traces and cost agree.
  if (/(?:^|\/)(?:dreamina-)?seedance-v?2[.-]0(?:-|$)/i.test(VIDEO_MODEL)) {
    input = { ...input, durationSeconds: Math.max(4, input.durationSeconds) };
  }
  input = { ...input, motion: await researchGenerationPrompt(input.motion) };
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
    // Supplying `poll` forces the SDK onto Gateway's /video-model/start endpoint.
    // Some models (including MiniMax H3) only support /video-model; let Gateway
    // complete the generation on that endpoint within the same abort budget.
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

export async function generateConceptImage(input: {
  prompt: string;
  references: Array<{ bytes: Uint8Array; mimeType: string }>;
}): Promise<AiImageOutput> {
  if (input.references.length > 0) {
    return generateStickerImage({
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
  input = { ...input, prompt: await researchGenerationPrompt(input.prompt) };
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
