import { z } from "zod";
import { PosePresetSchema } from "./pose-preset";
import { PlanEditV1Schema } from "./plan";
import { Mp4BackgroundV1Schema, StickerDocumentSchema } from "@/lib/contracts/sticker";

export const StickerKindSchema = z.enum(["static", "animated"]);
export const AssetKindSchema = z.enum([
  "playback",
  "reference",
  "mask",
  "master",
  "preview",
  /**
   * The sharing rendition: an animated, transparent APNG at one of `SHARING_APNG_DIMENSIONS`.
   *
   * This is what the library, the share sheet, and every non-Messages surface show for an animated
   * sticker.
   */
  "apng",
  /**
   * The sharing rendition as it was written before `apng` replaced it. No client produces one any
   * more, but every animated sticker published before the switch still points at one, so the kind
   * has to stay readable — and marketplace-visible — for those revisions to keep rendering.
   */
  "gif",
  "mp4",
  "system",
  "chat_attachment",
  /** A frame atlas: one transparent PNG holding a grid of frames lifted from a Live Photo. */
  "sequence",
  /**
   * A short generated clip: an opaque 1:1 MP4 shot against a chroma backdrop that the client keys
   * out at render time. Never marketplace-visible; the layer's poster still is what other users see.
   */
  "video",
  /**
   * A smaller copy of the sharing rendition, at 408 or 300 px.
   *
   * What WinkySticker attaches when someone picks Medium or Small. Distinct from `apng` because an
   * attachment rendition can be a still — a static sticker has these too — and `apng` rejects a
   * single-frame file by design. Distinct from `system` because nothing here is under Apple's
   * 500 KB ceiling: these carry the document's own frame rate and full palette, which is the whole
   * reason they exist.
   */
  "attachment",
  /**
   * The WebP copy of the sharing rendition, at one of `SHARING_APNG_DIMENSIONS`.
   *
   * A second container for artwork `apng` (or `master`) already holds, and optional everywhere:
   * it exists so an `.image`-mode send from the Messages extension can attach a file a fraction of
   * the APNG's size — a published 618 px APNG measured 9.8 MB and a 1024 px one 23.5 MB, where the
   * same frames as WebP land in hundreds of kilobytes. A sticker without one sends the APNG exactly
   * as it did before, which is why nothing in a publish requires it.
   *
   * Never a `system` rendition. `MSSticker.h` requires a file conforming to `kUTTypePNG`,
   * `kUTTypeGIF` or `kUTTypeJPEG`, and WebP conforms to none of them — so this can only ever be an
   * attachment, never the file Messages puts in the sticker drawer.
   */
  "webp",
  /**
   * The copy WhatsApp accepts: a transparent 512 px WebP, still or animated.
   *
   * Encoded on the phone when the sticker is added to a pack, not at publish time, because that is
   * the first moment a sticker is destined for a messenger at all. The server cannot make one — it
   * has sharp and no VP9 encoder — so this kind only ever arrives from a client.
   */
  "messenger_whatsapp",
  /**
   * The copy Telegram accepts: a transparent 512 px still PNG for a static sticker, or a VP9 WebM
   * with an alpha side-stream for an animated one.
   *
   * One kind rather than two because a sticker has exactly one Telegram rendition and its own
   * `kind` already says which container that is — the same reason `attachment` covers both a still
   * and an animated PNG.
   */
  "messenger_telegram",
]);

/** Sizes an `attachment` rendition may be written at. Large is the sharing rendition itself. */
export const ATTACHMENT_RENDITION_DIMENSIONS = { medium: 408, small: 300 } as const;

/**
 * What the two messengers enforce on a sticker they are handed.
 *
 * WhatsApp: https://github.com/WhatsApp/stickers/blob/main/iOS/README.md
 * Telegram: https://core.telegram.org/import-stickers
 *
 * Kept here rather than derived from the iOS client's `MessengerPackLimits` because they are a
 * contract, not a preference: a file over one of these is refused by the messenger after the
 * hand-off, where nothing in this app can explain the failure. The client walks a quality ladder
 * down to them; the server refuses anything that still missed.
 */
export const MESSENGER_RENDITION_DIMENSION = 512;
export const WHATSAPP_STATIC_BYTE_LIMIT = 100 * 1024;
export const WHATSAPP_ANIMATED_BYTE_LIMIT = 500 * 1024;
export const WHATSAPP_MAX_SECONDS = 10;
export const TELEGRAM_STATIC_BYTE_LIMIT = 512 * 1024;
export const TELEGRAM_ANIMATED_BYTE_LIMIT = 256 * 1024;
export const TELEGRAM_MAX_SECONDS = 3;

/**
 * How a frame atlas is packed, declared by the client because the file cannot say.
 *
 * The atlas is a single still PNG — that is the whole point of the transport, since it means no
 * animated-format decoder is needed anywhere — so nothing on the server can infer the grid or the
 * capture rate by inspecting it. These values are persisted on the asset row and cross-checked
 * against the document's sequence layer whenever one references the asset.
 */
export const SequenceMetadataSchema = z.object({
  columns: z.number().int().min(1).max(8),
  rows: z.number().int().min(1).max(8),
  frameCount: z.number().int().min(1).max(64),
  frameRate: z.number().min(1).max(60),
}).strict();

/**
 * Drawn by `AI_QUICK_IMAGE_MODEL` rather than `AI_IMAGE_MODEL`.
 *
 * Sent only by the Messages extension. Quick mode trades matte quality for latency and price — the
 * quick model cannot draw transparency, so its background is keyed out server-side — and that is a
 * trade only the surface asking can make, which is why it rides on the request instead of being
 * inferred from the sticker.
 *
 * Optional rather than defaulted so that omitting it — which every other client does — stays
 * absent all the way to the job row, where the column's own default decides.
 */
const QuickGenerationSchema = z.boolean().optional();

/**
 * Build the character as a sprite whose mood and pose the viewer can switch, without the user
 * having to ask the agent for it in words.
 *
 * It is a property of the project rather than of this request: the flag is stored on the sticker
 * and every later plan for it — a revision, a re-plan after feedback — has to honour it too.
 * Animated only, and never in quick mode, which draws against a chroma backdrop that cannot be
 * told apart from a sprite sheet's face placeholder.
 *
 * Optional rather than defaulted, exactly as `quick` is: a client that never sends it leaves the
 * column's own default to decide instead of writing a false through every layer on the way down.
 */
const ControllableGenerationSchema = z.boolean().optional();

export const CreateStickerRequestSchema = z.object({
  title: z.string().trim().min(1).max(100),
  kind: StickerKindSchema,
  prompt: z.string().trim().min(1).max(4_000),
  referenceAssetIds: z.array(z.string().uuid()).max(8).default([]),
  quick: QuickGenerationSchema,
  controllable: ControllableGenerationSchema,
  posePreset: PosePresetSchema.optional(),
  useQuickModeAllowance: z.boolean().optional(),
}).strict().superRefine((request, ctx) => {
  if (request.posePreset && !request.controllable) {
    ctx.addIssue({ code: "custom", path: ["posePreset"], message: "Pose presets require a controllable animation" });
  }
  if (!request.controllable) return;
  if (request.kind !== "animated") {
    ctx.addIssue({ code: "custom", path: ["controllable"], message: "Controllable stickers must be animated" });
  }
  if (request.quick) {
    ctx.addIssue({ code: "custom", path: ["controllable"], message: "Controllable stickers are not available in quick mode" });
  }
});

/**
 * A picture the user already has, turned into a sticker project without generating anything.
 *
 * This is the path behind "Add to Sticker": the artwork exists — it is a concept render they are
 * looking at, or a photo they picked — so there is nothing for the model to draw, and routing it
 * through `POST /stickers` would spend a generation reproducing an image the app is holding. The
 * project it makes is an ordinary static sticker with one image layer, so every later turn, edit,
 * and export behaves exactly as it would for a generated one.
 */
export const ImportStickerRequestSchema = z.object({
  title: z.string().trim().min(1).max(100),
  assetId: z.string().uuid(),
}).strict();

export const UpdateStickerRequestSchema = z.object({
  title: z.string().trim().min(1).max(100),
}).strict();

export const PostChatMessageRequestSchema = z.object({
  planPoseUpdate: z.object({
    planId: z.string().uuid(),
    currentRevision: z.number().int().min(1),
    posePreset: PosePresetSchema,
    edit: PlanEditV1Schema.optional(),
  }).strict().optional(),
  text: z.string().trim().min(1).max(8_000),
  intent: z.enum(["generate", "edit", "animate", "chat"]),
  attachments: z.array(z.object({
    assetId: z.string().uuid(),
    kind: z.enum(["reference", "mask"]),
    targetLayerId: z.string().min(1).max(64).optional(),
  }).strict()).max(8).default([]),
  targetLayerId: z.string().min(1).max(64).optional(),
  baseRevisionId: z.string().uuid().optional(),
  imagePlacement: z.enum(["replace", "add"]).default("replace"),
  quick: QuickGenerationSchema,
  useQuickModeAllowance: z.boolean().optional(),
}).strict().superRefine((value, context) => {
  if (value.planPoseUpdate && (value.intent !== "chat" || value.quick || value.targetLayerId || value.attachments.length > 0 || value.imagePlacement !== "replace")) {
    context.addIssue({ code: "custom", path: ["planPoseUpdate"], message: "Pose preset updates must be a planning chat turn" });
  }
  if (value.intent === "animate" && !value.baseRevisionId) {
    context.addIssue({ code: "custom", path: ["baseRevisionId"], message: "Animation requires an explicit base revision" });
  }
  if (value.imagePlacement === "add" && value.attachments.some((attachment) => attachment.kind === "mask")) {
    context.addIssue({ code: "custom", path: ["attachments"], message: "Masks can only replace an existing image layer" });
  }
});

export const CreateUploadRequestSchema = z.object({
  stickerId: z.string().uuid().optional(),
  kind: AssetKindSchema.exclude(["playback"]),
  mimeType: z.enum(["image/png", "image/jpeg", "image/webp", "image/gif", "video/mp4", "video/webm"]),
  byteSize: z.number().int().positive().max(25 * 1024 * 1024),
  filename: z.string().trim().min(1).max(180),
  sha256: z.string().regex(/^[a-f0-9]{64}$/i).optional(),
  /** Required for, and only for, `kind: "sequence"`. */
  sequence: SequenceMetadataSchema.optional(),
}).strict().superRefine((value, context) => {
  if (value.kind === "sequence") {
    if (!value.sequence) {
      context.addIssue({ code: "custom", path: ["sequence"], message: "A frame atlas must declare its grid and capture rate" });
    } else if (value.sequence.frameCount > value.sequence.rows * value.sequence.columns) {
      context.addIssue({
        code: "custom",
        path: ["sequence", "frameCount"],
        message: "A frame atlas cannot declare more frames than its grid holds",
      });
    }
    if (value.mimeType !== "image/png") {
      context.addIssue({ code: "custom", path: ["mimeType"], message: "Frame atlases must be transparent PNGs" });
    }
  } else if (value.sequence) {
    context.addIssue({ code: "custom", path: ["sequence"], message: "Only a frame atlas carries sequence metadata" });
  }
  if (value.kind === "mask" && value.mimeType !== "image/png" && value.mimeType !== "image/webp") {
    context.addIssue({ code: "custom", message: "Masks must be PNG or WebP with an alpha channel" });
  }
  if ((value.kind === "reference" || value.kind === "chat_attachment")
    && value.mimeType !== "image/png" && value.mimeType !== "image/jpeg" && value.mimeType !== "image/webp") {
    context.addIssue({ code: "custom", message: "Reference images must be PNG, JPEG, or WebP" });
  }
  if (value.kind === "system" && value.byteSize >= 500_000) {
    context.addIssue({ code: "custom", message: "System sticker renditions must be below 500 KB" });
  }
  if (value.kind === "system" && value.mimeType !== "image/png" && value.mimeType !== "image/gif") {
    context.addIssue({ code: "custom", message: "System sticker renditions must be PNG, APNG, or GIF" });
  }
  if (value.kind === "mp4" && value.mimeType !== "video/mp4") {
    context.addIssue({ code: "custom", message: "MP4 exports must use video/mp4" });
  }
  // `image/png` rather than `image/apng`: an APNG *is* a PNG, every store and CDN in the path
  // serves it as one, and `image/apng` is not in the mime enum this schema admits. What makes the
  // rendition animated is the `acTL` chunk, which `validateImageForKind` reads back off the bytes.
  if (value.kind === "apng" && value.mimeType !== "image/png") {
    context.addIssue({ code: "custom", message: "Sharing APNG exports must use image/png" });
  }
  if (value.kind === "gif" && value.mimeType !== "image/gif") {
    context.addIssue({ code: "custom", message: "GIF exports must use image/gif" });
  }
  // Unlike `apng`, the container and the mime agree here: a WebP is a WebP whether or not it
  // animates, so there is no still/animated ambiguity for `validateImageForKind` to read back.
  if (value.kind === "webp" && value.mimeType !== "image/webp") {
    context.addIssue({ code: "custom", message: "WebP sharing renditions must use image/webp" });
  }
  if (value.kind === "master" && value.mimeType !== "image/png") {
    context.addIssue({ code: "custom", message: "Static masters must use image/png" });
  }
  // Same reasoning as `apng` above: an animated attachment rendition *is* a PNG to everything that
  // transports it, and a static one genuinely is a still PNG.
  if (value.kind === "attachment" && value.mimeType !== "image/png") {
    context.addIssue({ code: "custom", message: "Attachment renditions must use image/png" });
  }
  // The messenger renditions. Their ceilings are the messengers' own, checked here so a file that
  // could never be handed over is refused before it is uploaded rather than after; `completeUpload`
  // checks them again against the measured bytes, which is the number that actually counts.
  if (value.kind === "messenger_whatsapp") {
    if (value.mimeType !== "image/webp") {
      context.addIssue({ code: "custom", message: "WhatsApp renditions must use image/webp" });
    } else if (value.byteSize > WHATSAPP_ANIMATED_BYTE_LIMIT) {
      context.addIssue({ code: "custom", message: "WhatsApp renditions must be 500 KB or smaller" });
    }
  }
  // One kind, two containers: Telegram takes a still PNG for a static sticker and a transparent VP9
  // WebM for an animated one, and the two have different ceilings. Which one is correct for *this*
  // sticker is not knowable here — the upload does not name a sticker kind — so both are admitted
  // and `bindMessengerRenditions` is what refuses a WebM bound to a static sticker.
  if (value.kind === "messenger_telegram") {
    if (value.mimeType === "image/png") {
      if (value.byteSize > TELEGRAM_STATIC_BYTE_LIMIT) {
        context.addIssue({ code: "custom", message: "Telegram still renditions must be 512 KB or smaller" });
      }
    } else if (value.mimeType === "video/webm") {
      if (value.byteSize > TELEGRAM_ANIMATED_BYTE_LIMIT) {
        context.addIssue({ code: "custom", message: "Telegram video renditions must be 256 KB or smaller" });
      }
    } else {
      context.addIssue({ code: "custom", message: "Telegram renditions must use image/png or video/webm" });
    }
  }
  // WebM exists in this API for exactly one purpose. Saying so here keeps `inspectWebM` off every
  // other kind's path, where nothing would know what to do with a video.
  if (value.mimeType === "video/webm" && value.kind !== "messenger_telegram") {
    context.addIssue({ code: "custom", path: ["mimeType"], message: "Only Telegram renditions may be WebM" });
  }
});

export const CompleteUploadRequestSchema = z.object({
  sha256: z.string().regex(/^[a-f0-9]{64}$/i).optional(),
}).strict();

export const PublishExportsRequestSchema = z.object({
  playbackDocument: StickerDocumentSchema.optional(),
  revisionId: z.string().uuid(),
  pngAssetId: z.string().uuid().optional(),
  apngAssetId: z.string().uuid().optional(),
  mp4AssetId: z.string().uuid().optional(),
  /**
   * The WebP copy of the sharing rendition, when the client could make one.
   *
   * Always optional and never load-bearing: iOS has no system WebP encoder (`ImageIO` reads the
   * format but does not write it), so a client that cannot link one still publishes a complete
   * sticker and its `.image` sends fall back to the APNG.
   */
  webpAssetId: z.string().uuid().optional(),
  systemAssetId: z.string().uuid(),
  /**
   * The 408 px and 300 px copies of the sharing rendition.
   *
   * Optional, and jointly so — a client that predates them still publishes, and its stickers simply
   * offer one size in WinkySticker. Sending one without the other is refused below rather than
   * silently half-populating the set.
   */
  attachmentMediumAssetId: z.string().uuid().optional(),
  attachmentSmallAssetId: z.string().uuid().optional(),
  mp4Background: Mp4BackgroundV1Schema.optional(),
  /**
   * Sent as `still` only by an animated export whose motion could not be squeezed under Apple's
   * 500 KB ceiling at any rung of the client's ladder, which then ships the sticker's poster frame.
   * Absent means the ordinary case, so an older client keeps meaning what it always did.
   */
  systemRenditionKind: z.enum(["animated", "still"]).optional(),
}).strict().superRefine((value, context) => {
  if (Boolean(value.attachmentMediumAssetId) !== Boolean(value.attachmentSmallAssetId)) {
    context.addIssue({
      code: "custom",
      path: ["attachmentSmallAssetId"],
      message: "Attachment renditions are published as a set: send both sizes or neither",
    });
  }
  if (value.attachmentMediumAssetId && value.attachmentMediumAssetId === value.attachmentSmallAssetId) {
    context.addIssue({
      code: "custom",
      path: ["attachmentSmallAssetId"],
      message: "The medium and small renditions must be different assets",
    });
  }
});

/**
 * The single emoji a messenger files a sticker under.
 *
 * Both messengers want exactly one, and neither can be told later, so "one grapheme that is an
 * emoji" is the whole rule. Counted with `Intl.Segmenter` rather than by length: a flag, a keycap
 * and a family are each one emoji made of several code points, and every length-based check gets
 * at least one of them wrong.
 */
export const MessengerEmojiSchema = z.string().min(1).max(64).refine((value) => {
  const graphemes = [...new Intl.Segmenter("en", { granularity: "grapheme" }).segment(value)];
  if (graphemes.length !== 1) return false;
  // Three families, because no single Unicode property covers them. Most emoji are
  // `Extended_Pictographic`; a flag is a pair of regional indicators, which are not pictographic at
  // all; and a keycap is an ASCII digit wearing a combining enclosure. Testing only the first
  // rejects 🇯🇵 and 1️⃣, both of which the messengers accept.
  return /\p{Extended_Pictographic}/u.test(value)
    || /^[\u{1F1E6}-\u{1F1FF}]{2}$/u.test(value)
    || /^[0-9#*]\uFE0F?\u20E3$/u.test(value);
}, { message: "A messenger emoji must be exactly one emoji" });

/**
 * The messenger renditions for one already-published revision.
 *
 * Separate from `PublishExportsRequestSchema` because it is sent at a different moment: a publish
 * uploads the full export set at once and is refused without a system rendition, while these arrive
 * when the sticker is added to a pack, singly, against a revision that is already active. Both
 * asset ids are optional and independent — artwork that fits WhatsApp's ceiling can still overshoot
 * Telegram's, and binding the one that worked beats refusing both.
 */
export const MessengerRenditionsRequestSchema = z.object({
  revisionId: z.string().uuid(),
  whatsappAssetId: z.string().uuid().optional(),
  telegramAssetId: z.string().uuid().optional(),
  emoji: MessengerEmojiSchema.optional(),
}).strict().superRefine((value, context) => {
  if (!value.whatsappAssetId && !value.telegramAssetId && !value.emoji) {
    context.addIssue({ code: "custom", message: "Send at least one rendition or an emoji" });
  }
  if (value.whatsappAssetId && value.whatsappAssetId === value.telegramAssetId) {
    context.addIssue({
      code: "custom",
      path: ["telegramAssetId"],
      message: "The two messengers take different files and cannot share one asset",
    });
  }
});
export type MessengerRenditionsRequest = z.infer<typeof MessengerRenditionsRequestSchema>;

/**
 * A document edited on the client, saved as a new revision.
 *
 * `parentRevisionId` is the revision the user was looking at when they opened the editor. It is
 * required rather than inferred from the sticker's active revision so a save that races a
 * generation is refused rather than silently re-parenting onto whatever landed in the meantime.
 */
export const SaveEditedDocumentRequestSchema = z.object({
  parentRevisionId: z.string().uuid(),
  document: StickerDocumentSchema,
  note: z.string().trim().max(200).optional(),
}).strict();

/**
 * An APNs device token, as the hex string iOS hands the app.
 *
 * Length is bounded rather than fixed at 64 characters: Apple has changed it before (32 bytes to
 * 32-or-more), and rejecting a longer token would silently turn off notifications for a future OS.
 */
export const RegisterDeviceRequestSchema = z.object({
  token: z.string().trim().regex(/^[0-9a-fA-F]{64,256}$/, "Expected a hex APNs device token"),
  platform: z.literal("ios").default("ios"),
  environment: z.enum(["sandbox", "production"]).default("production"),
  bundleId: z.string().trim().min(1).max(200).optional(),
  appVersion: z.string().trim().min(1).max(50).optional(),
}).strict();

export const ApiErrorSchema = z.object({
  error: z.object({
    code: z.string(),
    message: z.string(),
    requestId: z.string(),
    details: z.unknown().optional(),
  }).strict(),
}).strict();

export const GenerationEventV1Schema = z.object({
  id: z.number().int().positive(),
  jobId: z.string().uuid(),
  type: z.enum(["queued", "started", "progress", "document", "candidate", "waiting", "completed", "failed"]),
  createdAt: z.string().datetime(),
  data: z.record(z.string(), z.unknown()),
}).strict().superRefine((event, context) => {
  if (event.type === "document") {
    const document = StickerDocumentSchema.safeParse(event.data.document);
    if (!document.success) context.addIssue({ code: "custom", message: "document events must contain a complete valid StickerDocument" });
  }
});

export const AssetV1Schema = z.object({
  id: z.string().uuid(),
  stickerId: z.string().uuid().nullable(),
  kind: AssetKindSchema,
  state: z.enum(["pending", "ready", "failed", "deleted"]),
  mimeType: z.string(),
  byteSize: z.number().int().nullable(),
  width: z.number().int().nullable(),
  height: z.number().int().nullable(),
  frameCount: z.number().int().nullable(),
  durationSeconds: z.number().nullable(),
  fps: z.number().nullable(),
  sha256: z.string().nullable(),
  hasAlpha: z.boolean().nullable(),
  createdAt: z.string().datetime(),
}).strict();

export const SystemStickerV1Schema = z.object({
  assetId: z.string().uuid(),
  mimeType: z.enum(["image/png", "image/gif"]),
  byteSize: z.number().int().positive().max(499_999),
  sha256: z.string().regex(/^[a-f0-9]{64}$/i),
}).strict();

export const StickerSummaryV1Schema = z.object({
  id: z.string().uuid(),
  title: z.string(),
  kind: StickerKindSchema,
  status: z.enum(["draft", "published", "deleting"]),
  activeRevisionId: z.string().uuid().nullable(),
  playbackRevisionId: z.string().uuid().nullable().optional(),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  previewAsset: AssetV1Schema.nullable(),
  /**
   * The concept render of this draft's newest plan — what the grid shows a draft that has not
   * built any artwork of its own yet.
   *
   * Null on every published sticker, which has its own artwork, and on a draft whose plan never
   * reached a concept render. A reader uses it only *after* `systemSticker` and `previewAsset`:
   * a draft that has already built something should show what it built, not what it planned.
   */
  planConceptAsset: AssetV1Schema.nullable(),
  systemSticker: SystemStickerV1Schema.nullable(),
  /**
   * The smaller sizes WinkySticker can attach, when this sticker has them.
   *
   * Large is deliberately absent: it is `previewAsset`, which every client already reads. Both are
   * null for anything published before attachment renditions existed, and the extension walks up to
   * the next size it does have rather than refusing to send.
   */
  attachmentMedium: AssetV1Schema.nullable(),
  attachmentSmall: AssetV1Schema.nullable(),
  /**
   * The WebP copy of the sharing rendition, when this sticker has one.
   *
   * Null for every sticker published before WebP exports existed, and for any client that cannot
   * encode one — so a reader must treat it as an optimisation and fall back to `previewAsset`.
   */
  webpAsset: AssetV1Schema.nullable(),
  /**
   * The 512 px copies WhatsApp and Telegram accept, when this sticker has them.
   *
   * Written when the sticker is added to a pack, not when it is published, so both are null for
   * every sticker that has never been in one and for every sticker added to a pack before this
   * field existed. Unlike `webpAsset`, these have no fallback: the export sheet sends these bytes
   * or it sends nothing, which is why a member without them is shown grayed rather than offered.
   *
   * Independently null, too — WhatsApp gives an animation 500 KB and Telegram gives it 256 KB, so
   * artwork routinely clears one ceiling and misses the other.
   */
  whatsappAsset: AssetV1Schema.nullable(),
  telegramAsset: AssetV1Schema.nullable(),
  /** The single emoji both messengers file this sticker under, as the creator chose it. */
  messengerEmoji: z.string().nullable(),
}).strict();

export const StickerListResponseV1Schema = z.object({
  data: z.array(StickerSummaryV1Schema),
  nextCursor: z.string().nullable(),
}).strict();

export const AssetDownloadResponseV1Schema = z.object({
  url: z.string().url(),
  expiresAt: z.string().datetime(),
  asset: AssetV1Schema,
}).strict();

export const ChatMessageV1Schema = z.object({
  id: z.string().uuid(),
  role: z.enum(["user", "assistant", "system"]),
  kind: z.enum(["text", "image", "image_edit", "animation", "device_edit", "export", "status"]),
  content: z.string(),
  toolDetails: z.string().optional(),
  targetLayerId: z.string().nullable(),
  baseRevisionId: z.string().uuid().nullable(),
  imagePlacement: z.enum(["replace", "add"]),
  sequence: z.number().int().positive(),
  revisionId: z.string().uuid().nullable(),
  jobId: z.string().uuid().nullable(),
  status: z.enum(["complete", "streaming", "failed"]),
  createdAt: z.string().datetime(),
  attachments: z.array(z.object({
    assetId: z.string().uuid(),
    kind: z.enum(["reference", "mask"]),
    targetLayerId: z.string().nullable(),
  }).strict()),
}).strict();

export const ChatMessagesResponseV1Schema = z.object({
  data: z.array(ChatMessageV1Schema),
  nextBeforeSequence: z.number().int().positive().nullable(),
}).strict();

// ---------------------------------------------------------------------------
// Marketplace
// ---------------------------------------------------------------------------

export const PackStateSchema = z.enum(["draft", "published", "unlisted", "removed"]);
export const PackMonetizationSchema = z.enum(["free", "paid", "subscription"]);
export const PackSortSchema = z.enum(["recent", "popular"]);

/**
 * The public creator byline.
 *
 * `handle` is the only creator identifier that crosses the wire — the OAuth `sub` is every
 * `ownerId` in this schema and must never appear in a URL or a response. `displayName` is always
 * a non-empty string so no client ever renders a blank byline.
 */
export const CreatorV1Schema = z.object({
  handle: z.string().min(3).max(40),
  displayName: z.string().min(1),
  bio: z.string().nullable(),
  packCount: z.number().int().nonnegative(),
  isSelf: z.boolean(),
}).strict();

/**
 * Note that pack members reuse `StickerSummaryV1Schema` verbatim rather than getting a narrower
 * shape of their own. Both clients already decode that type, so a pack sticker needs no new model
 * on either side.
 */
export const PackSummaryV1Schema = z.object({
  id: z.string().uuid(),
  slug: z.string().min(1),
  title: z.string().min(1),
  summary: z.string().nullable(),
  state: PackStateSchema,
  creator: CreatorV1Schema,
  itemCount: z.number().int().nonnegative(),
  installCount: z.number().int().nonnegative(),
  installed: z.boolean(),
  isMine: z.boolean(),
  coverStickers: z.array(StickerSummaryV1Schema).max(4),
  /** Placeholder only. Every pack is free; nothing charges. */
  monetization: z.object({
    kind: PackMonetizationSchema,
    priceCents: z.number().int().nonnegative(),
    currency: z.string().length(3),
  }).strict(),
  publishedAt: z.string().datetime().nullable(),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
}).strict();

export const PackDetailV1Schema = PackSummaryV1Schema.extend({
  stickers: z.array(StickerSummaryV1Schema),
}).strict();

export const PackListResponseV1Schema = z.object({
  data: z.array(PackSummaryV1Schema),
  nextCursor: z.string().nullable(),
}).strict();

export const CreatorPacksResponseV1Schema = z.object({
  creator: CreatorV1Schema,
  data: z.array(PackSummaryV1Schema),
  nextCursor: z.string().nullable(),
}).strict();

export const InstallPackResponseV1Schema = z.object({
  packId: z.string().uuid(),
  installed: z.boolean(),
}).strict();

/**
 * One group in the sectioned library: the user's own stickers, or an installed pack.
 *
 * Sections are never paginated. The Messages extension reconciles its cache by removing whatever
 * a response did not mention, so a pack split across a page boundary would read as a pack that
 * lost half its stickers.
 */
export const LibrarySectionV1Schema = z.object({
  /** `"mine"`, or `"pack:<uuid>"`. */
  id: z.string().min(1),
  kind: z.enum(["mine", "pack"]),
  title: z.string().min(1),
  packId: z.string().uuid().nullable(),
  packSlug: z.string().nullable(),
  creator: CreatorV1Schema.nullable(),
  installedAt: z.string().datetime().nullable(),
  updatedAt: z.string().datetime(),
  stickers: z.array(StickerSummaryV1Schema),
}).strict();

export const LibrarySectionsResponseV1Schema = z.object({
  sections: z.array(LibrarySectionV1Schema),
  generatedAt: z.string().datetime(),
}).strict();

export const CreatePackRequestSchema = z.object({
  title: z.string().trim().min(1).max(60),
  summary: z.string().trim().max(200).optional(),
  stickerIds: z.array(z.string().uuid()).max(60).default([]),
  state: z.enum(["draft", "published"]).default("draft"),
}).strict();

export const UpdatePackRequestSchema = z.object({
  title: z.string().trim().min(1).max(60).optional(),
  summary: z.string().trim().max(200).nullable().optional(),
  coverStickerId: z.string().uuid().nullable().optional(),
}).strict();

export const AddPackItemRequestSchema = z.object({
  stickerId: z.string().uuid(),
  position: z.number().int().nonnegative().optional(),
}).strict();

export const ReorderPackItemsRequestSchema = z.object({
  stickerIds: z.array(z.string().uuid()).max(60),
}).strict();

export const UnpublishPackRequestSchema = z.object({
  state: z.enum(["draft", "unlisted"]).default("draft"),
}).strict();

/**
 * The state of a pending account deletion.
 *
 * ISO-8601 rather than the epoch seconds the identity provider speaks, to match every other instant
 * on this API. `deletionScheduledAt` is the instant both this server and the identity provider will
 * act on; the app shows it so "in 7 days" is never a guess.
 */
export const AccountDeletionStateV1Schema = z.object({
  pendingDeletion: z.boolean(),
  deletionScheduledAt: z.string().datetime().nullable(),
  deletionRequestedAt: z.string().datetime().nullable(),
}).strict();

export type CreateStickerRequest = z.infer<typeof CreateStickerRequestSchema>;
export type ImportStickerRequest = z.infer<typeof ImportStickerRequestSchema>;
export type UpdateStickerRequest = z.infer<typeof UpdateStickerRequestSchema>;
export type RegisterDeviceRequest = z.infer<typeof RegisterDeviceRequestSchema>;
export type CreatePackRequest = z.infer<typeof CreatePackRequestSchema>;
export type UpdatePackRequest = z.infer<typeof UpdatePackRequestSchema>;
export type AddPackItemRequest = z.infer<typeof AddPackItemRequestSchema>;
export type ReorderPackItemsRequest = z.infer<typeof ReorderPackItemsRequestSchema>;
export type UnpublishPackRequest = z.infer<typeof UnpublishPackRequestSchema>;
export type AccountDeletionStateV1 = z.infer<typeof AccountDeletionStateV1Schema>;
export type PostChatMessageRequest = z.infer<typeof PostChatMessageRequestSchema>;
export type CreateUploadRequest = z.infer<typeof CreateUploadRequestSchema>;
export type PublishExportsRequest = z.infer<typeof PublishExportsRequestSchema>;
export type SaveEditedDocumentRequest = z.infer<typeof SaveEditedDocumentRequestSchema>;
