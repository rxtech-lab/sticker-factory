// The turns that produce artwork: picking which references a model sees, then drawing a
// sticker, a concept, or a clip.

import { createWebTools, isWebTool, WEB_RESEARCH_PROMPT } from "./web-tools";
import { researchGenerationPrompt } from "./generation-research";
import { gateway } from "@ai-sdk/gateway";
import { experimental_generateVideo as generateVideo, generateImage, generateText, hasToolCall, stepCountIs, tool } from "ai";
import sharp from "sharp";
import { z } from "zod";
import { recordImageApiCost, recordTextApiCost, recordVideoApiCost, reportAiStepUsage } from "@/lib/ai/cost";
import { ApiError } from "@/lib/http/errors";
import { traceEvent, traceSpan } from "@/lib/observability/trace";
import { downscaleForModelInput, inspectImage, normalizeTransparentPng } from "@/lib/storage/r2";
import type { AiImageInput, AiImageOutput, AiReferenceSelectionContext, AiSheetInspection, AiSheetInspectionContext, AiVideoInput, AiVideoOutput } from "./gateway-contracts";
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
    // Feeds the chat screen's live token meter; see `reportAiStepUsage`.
    onLanguageModelCallEnd: reportAiStepUsage,
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

/**
 * Looks at a generated sprite sheet before the build registers it.
 *
 * The pixel gates in `lib/render/sprite-registration.ts` prove a magenta oval exists in every cell;
 * they cannot tell that the model also kept a mouth on the bumper, which the expression plate then
 * draws a second time. A body sheet is shown raw, opening still visible, so the inspector can see
 * both the oval and anything facial outside it. The answer is a single required tool call, like
 * `select_references`, so a rejection always carries the problems the redraw is told to fix.
 */
export async function inspectSpriteSheet(input: AiSheetInspectionContext): Promise<AiSheetInspection> {
  const { columns, rows, count } = input.sheet;
  const face = input.face ?? "the character's head, where the eyes and mouth are";
  const rules = input.kind === "clips"
    ? [
      `Character: ${input.character}. Face region: ${face}.`,
      `Grid: ${columns} columns by ${rows} rows; the first ${count} cells are used.`,
      "In every used cell, all of these must hold:",
      input.faceCompositing === "masked"
        ? "1. A flat solid magenta (#FF00FF) face opening sits behind any hand, cup, instrument, hair, or prop that crosses it. Foreground objects remain fully drawn and may hide some or all of the opening."
        : "1. Exactly one flat, solid magenta (#FF00FF) oval sits on the face region, with no eyes, mouth, outline or other features drawn inside it.",
      "2. No eye, brow, nose, mouth, or teeth remain anywhere on the body outside that oval: not on a grille, bumper, chest, screen, belly, or panel.",
      "3. One character only, with no second head or miniature portrait.",
      input.faceCompositing === "masked"
        ? `Return faceFrames with exactly ${count} entries, in cell order. Each entry is the full unobstructed face opening of that cell, inferred from the head even when the visible magenta is partly or fully covered. Coordinates are relative to that single cell, never the whole sheet: (0,0) is the cell's top-left corner and (1,1) its bottom-right. faceX and faceY are the centre of the face opening; faceSize is its width divided by the cell width. Where magenta is visible, the centre must lie on or next to it; extend the opening only over the part hidden behind a foreground object.`
        : "",
      "Report ok=false when any used cell breaks a rule, one short problem per failing cell naming the cell number and the leftover feature and where it sits.",
    ]
    : [
      `Character: ${input.character}. Face region: ${face}.`,
      `Grid: ${columns} columns by ${rows} rows; the first ${count} cells are used, in this order: ${(input.expressions ?? []).map((label, index) => `${index + 1}. ${label}`).join("; ")}.`,
      "Each used cell must contain only an inner face patch: eyes, brows, nose, mouth, cheeks and the surface directly beneath them, with no enclosing drawn head outline, ears, outer hair silhouette, neck, body, second character, sticker border, or magenta. A borderless oval cutout containing the facial surface and its original colours or markings is the requested patch, even when it contains the whole forehead and muzzle. The cutout boundary itself is not a drawn head outline.",
      input.faceGuide ? "Image 1 is the expression sheet being reviewed. Image 2 is the actual body frame with its magenta face opening, for context only. The facial patch should replace that opening; the body already supplies the outer head and ears. An oval cutout of facial surface is expected and is not by itself a head outline or portrait. Reject actual enclosing head outlines, ears, necks, bodies or duplicate heads; do not reject a borderless patch merely because it has an oval cutout boundary." : "",
      "Each cell's expression should plausibly match its label.",
      "Report ok=false for visible extra head anatomy such as ears, neck or an outer hair silhouette, an enclosing drawn contour around the whole head, a body, an empty cell, or cells out of order. Name the cell and the concrete extra feature; do not reject a valid borderless facial cutout merely by calling it a head or portrait.",
    ];
  const result = await generateText({
    // Feeds the chat screen's live token meter; see `reportAiStepUsage`.
    onLanguageModelCallEnd: reportAiStepUsage,
    model: gateway(process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
    system: [
      "You inspect a generated sprite sheet before it is used, and call report_sheet exactly once.",
      "Cells are read left to right, then top to bottom; only the first N cells are used and the rest stay empty.",
      "Be strict about the listed rules and lenient about style, colour, and drawing quality.",
    ].join(" "),
    messages: userTurn(rules.filter(Boolean).join("\n"), await Promise.all(
      [input.image, ...(input.faceGuide ? [input.faceGuide] : [])].map(image => downscaleForModelInput(image.bytes)),
    )),
    tools: {
      report_sheet: tool({
        description: "Report whether the sheet follows every rule, with one short problem per failing cell.",
        inputSchema: z.object({
          ok: z.boolean(),
          problems: z.array(z.string().trim().min(1).max(300)).max(12).default([]),
          faceFrames: z.array(z.object({
            faceX: z.number().min(0).max(1),
            faceY: z.number().min(0).max(1),
            faceSize: z.number().min(0.02).max(1),
          }).strict()).optional().describe("One full face opening per used cell, in cell order. Coordinates are fractions of that single cell, not the sheet; faceX/faceY is the opening's centre."),
        }).strict(),
      }),
    },
    toolChoice: "required",
    stopWhen: [hasToolCall("report_sheet"), stepCountIs(3)],
    maxRetries: 2,
    abortSignal: AbortSignal.timeout(60_000),
  });
  await recordTextApiCost(result);
  const call = result.toolCalls.find((item) => item.toolName === "report_sheet");
  if (!call) throw new Error("Sheet inspector must call report_sheet exactly once");
  const report = z.object({
    ok: z.boolean(),
    problems: z.array(z.string()).default([]),
    faceFrames: z.array(z.object({ faceX: z.number(), faceY: z.number(), faceSize: z.number() }).strict()).optional(),
  }).parse(call.input);
  const problems = report.problems.map((problem) => problem.trim()).filter(Boolean);
  if (input.kind === "clips" && input.faceCompositing === "masked" && report.faceFrames?.length !== count) {
    return { ok: false, problems: [...problems, `Report full-face registration for all ${count} used cells`], faceFrames: report.faceFrames };
  }
  traceEvent("ai.sheet.inspected", { kind: input.kind, character: input.character, ok: report.ok, problems: problems.length });
  return report.ok || problems.length === 0
    ? { ok: true, faceFrames: report.faceFrames }
    : { ok: false, problems, faceFrames: report.faceFrames };
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
            input.isolatedLayer
              ? `Remove the background and any unrelated illustration. Keep only the isolated element described here: ${input.prompt}. Preserve its exact lettering and styling with clean antialiased transparent edges; do not add a checkerboard or a preview of the full sticker.`
              : input.sheet
              ? "Remove only the background from the supplied sprite sheet, including the gaps inside and between cells. Preserve the exact grid, frame order, character scale, positions, and all artwork in each cell. Keep any magenta face placeholders intact. Do not merge, rearrange, crop, or enlarge the drawings; do not add a checkerboard."
              : "Remove the entire background. Keep only the sticker subject with clean antialiased transparent edges; do not add a checkerboard.",
          references: [{ bytes: normalized.bytes, mimeType: "image/png" }],
          mode: "conversation_edit",
          isolatedLayer: input.isolatedLayer,
          ...(input.sheet ? { sheet: input.sheet, keepFrame: true, quality: input.quality } : {}),
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
  purpose?: "animation-summary" | "extension";
  prompt: string;
  references: Array<{ bytes: Uint8Array; mimeType: string }>;
}): Promise<AiImageOutput> {
  if (input.purpose === "extension") return generateStickerImage({
    prompt: input.prompt + " Draw ONLY the proposed additions at their planned positions on a transparent 1024x1024 canvas. Existing reference subjects are style context only; never copy them into this image. Do not add backgrounds, panels or labels.",
    references: input.references, mode: "generate", keepFrame: true, isolatedLayer: true,
  });
  const isSummary = input.purpose === "animation-summary";
  if (!isSummary && input.references.length > 0) {
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
  if (!isSummary) input = { ...input, prompt: await researchGenerationPrompt(input.prompt) };
  // Opaque on purpose. The reference is a picture *of* the complete sticker, not one of the
  // transparent parts later extracted from it, so it skips the part-generation alpha gate.
  const result = await generateImage({
    model: gateway.imageModel(
      process.env.AI_IMAGE_MODEL ?? "openai/gpt-image-2",
    ),
    prompt: isSummary ? {
      text: input.prompt,
      images: input.references.map((reference) => reference.bytes),
    } : [
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
  await reportAiStepUsage(result);
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
