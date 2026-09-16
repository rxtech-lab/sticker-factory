// Model selection, prompt scaffolding and the raw image calls. Everything here is about how a
// request reaches a model, not about what any particular turn asks for.

import { gateway } from "@ai-sdk/gateway";
import { generateImage, generateText, type ModelMessage } from "ai";
import { recordImageApiCost, reportAiStepUsage } from "@/lib/ai/cost";
import { alternateChromaKey, chromaKeyBackground, preferredChromaKey, type ChromaKeyColor } from "@/lib/ai/chroma-key";
import { ApiError } from "@/lib/http/errors";
import { traceEvent, traceSpan } from "@/lib/observability/trace";
import { downscaleForModelInput, normalizeTransparentPng } from "@/lib/storage/r2";
import type { AiImageInput, AiImageOutput, AiPlanVisual, AiReferenceImage, AiVideoInput } from "./gateway-contracts";

export function assertImageInputBounds(input: AiImageInput): void {
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
 * so each attached image is billed ten or fourteen times over a turn. The guided flow permits eight references, and each must remain available to the agents.
 * Preset covers are passed separately with explicit labels.
 */
const VIEWABLE_REFERENCE_LIMIT = 8;

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
export async function viewableReferences(
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
 * The original subject, current sticker, resting concept, and animation summary each have a
 * separate role. Reserve a slot for all four so the storyboard survives a full project context.
 */
const PLAN_VISUAL_LIMIT = 4;

/**
 * Prepares the project's own artwork for a planner that is going to look at it.
 *
 * The same downscale `viewableReferences` applies, and the same tolerance for an image that will not
 * decode: prior art is context, so planning without one of these pictures is worse than planning
 * with it and far better than failing the turn over it. The label travels with the bytes so a
 * dropped image takes its line out of the prompt too, and the numbering never describes an image
 * that is not there.
 */
export async function viewablePlanVisuals(
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
export function userTurn(text: string, images: AiReferenceImage[], presets: AiPlanVisual[] = []): ModelMessage[] {
  if (images.length === 0 && presets.length === 0) return [{ role: "user", content: text }];
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
        ...presets.flatMap(visual => [
          { type: "text" as const, text: `Preset example — ${visual.label}. Creative style/theme guidance only. Do not copy this example's cat, subject, text or background; preserve the user's subject and approved artwork.` },
          { type: "image" as const, image: visual.image.bytes, mediaType: visual.image.mimeType },
        ]),
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
export function attachedImagesNote(count: number, extra?: string): string {
  if (count === 0) return "";
  return [
    `The user attached ${count} image${count === 1 ? "" : "s"} to this turn, shown to you as the`,
    "user reference images, followed separately by any labelled preset examples. They are reference material the user handed over, not the sticker",
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
export function priorArtNote(visuals: AiPlanVisual[]): string {
  if (visuals.length === 0) return "";
  return [
    `The first ${visuals.length} image${visuals.length === 1 ? "" : "s"} in this message`,
    `${visuals.length === 1 ? "is" : "are"} this project as it already exists, in order:`,
    visuals.map((visual, index) => `(${index + 1}) ${visual.label}`).join(" "),
    "Respect each image's role: a storyboard explains motion and expressions; its panels and annotations are not sticker artwork.",
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
export const IMAGE_TIMEOUT_MS = (() => {
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
export const VIDEO_MODEL = process.env.AI_VIDEO_MODEL ?? "bytedance/seedance-v1.0-pro-fast";
/**
 * Sent to the Gateway verbatim. The AI SDK types this as `{width}x{height}`, but the Gateway's
 * own model cards name tiers (`480p`) and it forwards whatever it is given; a form the model
 * rejects comes back as a warning, which `generateStickerVideo` logs. The cast is what lets the
 * deployment choose either spelling without a code change.
 */
export const VIDEO_RESOLUTION = (process.env.AI_VIDEO_RESOLUTION ?? "480p") as `${number}x${number}`;
export const VIDEO_FPS = 24;
export const VIDEO_TIMEOUT_MS = (() => {
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
export function videoInstruction(input: AiVideoInput): string {
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
    input.isolatedLayer
      ? "Draw only the isolated overlay element described by the latest instruction. The app composites it onto an existing sticker."
      : input.mode === "conversation_edit"
      ? "Edit the supplied sticker references according to the latest instruction."
      : "Generate the sticker described by the latest instruction.",
    input.conversationContext && !input.isolatedLayer
      ? `Recoverable project context:\n${input.conversationContext}`
      : "",
    `Latest instruction: ${input.prompt}`,
    input.isolatedLayer
      ? "References provide style or likeness only. Do not reproduce their complete composition, existing subjects, scenery, sticker frame, or background unless that is the requested new element. Do not show the element placed on the sticker or draw a preview of the finished sticker. For lettering, draw only the exact requested words and their lettering decoration; no characters, vehicles, landscape, or other illustration. Centre the isolated element at a readable size with transparent padding; the app handles placement."
      : "",
    keyColor
      ? `${input.isolatedLayer ? "Draw one isolated overlay element." : "Draw one centered sticker subject."} ${chromaBackdropInstruction(keyColor)}`
      : input.sheet
        ? "The whole background of the sheet, and every gap between cells, is genuinely transparent."
        : input.isolatedLayer
          ? "Keep every pixel outside the requested element genuinely transparent."
          : "Create a centered sticker with a genuinely transparent background.",
    input.sheet
      ? sheetInstruction(input.sheet)
      : `${input.isolatedLayer ? "Produce exactly one isolated element." : "Produce exactly one sticker subject."} Never draw a grid, contact sheet, storyboard, film strip, or multiple frames or poses side by side.`,
    "Return PNG.",
  ].filter(Boolean).join("\n\n");
}

/**
 * The sheet paragraph, replacing the one-subject rule above.
 *
 * Everything here is what the registration step depends on: cells of one size in row-major order,
 * the body at one scale and one position in every cell, a face placeholder in one flat colour, and
 * transparent padding so a cell never bleeds into its neighbour.
 */
function sheetInstruction(sheet: NonNullable<AiImageInput["sheet"]>): string {
  return [
    `Draw a sprite sheet: a grid of ${sheet.columns} columns by ${sheet.rows} rows of equal cells filling the 1024x1024 frame,`,
    `containing exactly ${sheet.count} drawings in row-major order (left to right, then top to bottom).`,
    "Every cell is the same size. Reserve at least 15% of each cell's width on both left and right and 15% of its height above and below as completely transparent safety margins. All visible pixels must fit inside the central 70% of the cell's width and height, including outlines, extremities, accessories, shadows, and motion effects.",
    "Plan the full motion envelope before drawing: choose one uniform character scale small enough for the widest and tallest pose across all frames. Keep that scale and the same body anchor throughout. If any pose would reach the safety margins, reduce the character in every frame together; never crop, stretch, or shrink just that frame. A wide character must fit the cell's width even when there is spare height.",
    "The references define the design and proportions, not how much of a cell to fill. Fit the complete drawing inside each cell independently, including cells on the outer edges of the sheet. Never let artwork touch a cell boundary or continue into a neighbouring cell.",
    `Cells after the ${sheet.count}th stay completely transparent.`,
    "No dividers, borders, numbers, labels, arrows, captions, or text anywhere.",
    sheet.tiles
      ? [
        "Each cell contains only an inner facial patch that will fill the body's face opening: eyes, brows, mouth, cheeks, nose, facial markings, and the skin, fur, paint, glass or surface directly beneath them.",
        sheet.faceRegion ? `The opening sits on ${sheet.faceRegion}; the patch contains everything that belongs to that face region and nothing outside it.` : "",
        "No enclosing outline, sticker border, rim, shadow, head or body silhouette, ears, hair, fur, shell, casing, neck, body, or background. Never draw a complete head or miniature portrait inside this patch. Match the surrounding surface's colour and texture so the patch blends into it. Keep transparent padding outside the patch. The patch is the same size, at the same position, and facing the same way in every cell; only the expression changes. Preserve hard pixel edges and the original pixel grid for pixel art.",
      ].filter(Boolean).join(" ")
      : "Draw the same character at exactly the same scale and body position in every cell, so the frames register when flipped through.",
    sheet.facePlaceholder
      ? [
        "Keep the complete outer silhouette of the head or front of the character: ears, hair, fur, shell, casing, frames and trim.",
        sheet.faceRegion ? `The face region is ${sheet.faceRegion}.` : "",
        "Replace the entire face region with a single flat, solid, pure magenta (#FF00FF) filled oval: one shape, with no outline, features, highlights, shading, or gradient, the same size relative to the body in every cell. Every eye, brow, nose, mouth and tooth the reference has anywhere on the body must be inside that oval: none may remain outside or beneath it, whether on a grille, bumper, chest, screen, belly, or panel. This is the opening for an inner facial patch, not for another complete head. Use magenta nowhere else in the image.",
      ].filter(Boolean).join(" ")
      : "",
  ].filter(Boolean).join(" ");
}

export async function generateThroughImageModel(
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
    providerOptions: input.quality
      ? { openai: { ...transparentProviderOptions.openai, quality: input.quality } }
      : transparentProviderOptions,
    abortSignal: AbortSignal.timeout(IMAGE_TIMEOUT_MS),
  });
  await reportAiStepUsage(result);
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
    // Feeds the chat screen's live token meter; see `reportAiStepUsage`.
    onLanguageModelCallEnd: reportAiStepUsage,
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
export async function generateKeyedStickerImage(input: AiImageInput): Promise<AiImageOutput> {
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
