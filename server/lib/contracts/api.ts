import { z } from "zod";
import { Mp4BackgroundV1Schema, StickerDocumentSchema } from "@/lib/contracts/sticker";

export const StickerKindSchema = z.enum(["static", "animated"]);
export const AssetKindSchema = z.enum([
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
   * A smaller copy of the sharing rendition, at 408 or 300 px.
   *
   * What WinkySticker attaches when someone picks Medium or Small. Distinct from `apng` because an
   * attachment rendition can be a still — a static sticker has these too — and `apng` rejects a
   * single-frame file by design. Distinct from `system` because nothing here is under Apple's
   * 500 KB ceiling: these carry the document's own frame rate and full palette, which is the whole
   * reason they exist.
   */
  "attachment",
]);

/** Sizes an `attachment` rendition may be written at. Large is the sharing rendition itself. */
export const ATTACHMENT_RENDITION_DIMENSIONS = { medium: 408, small: 300 } as const;

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

export const CreateStickerRequestSchema = z.object({
  title: z.string().trim().min(1).max(100),
  kind: StickerKindSchema,
  prompt: z.string().trim().min(1).max(4_000),
  referenceAssetIds: z.array(z.string().uuid()).max(8).default([]),
  quick: QuickGenerationSchema,
}).strict();

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
}).strict().superRefine((value, context) => {
  if (value.intent === "animate" && !value.baseRevisionId) {
    context.addIssue({ code: "custom", path: ["baseRevisionId"], message: "Animation requires an explicit base revision" });
  }
  if (value.imagePlacement === "add" && value.attachments.some((attachment) => attachment.kind === "mask")) {
    context.addIssue({ code: "custom", path: ["attachments"], message: "Masks can only replace an existing image layer" });
  }
});

export const CreateUploadRequestSchema = z.object({
  stickerId: z.string().uuid().optional(),
  kind: AssetKindSchema,
  mimeType: z.enum(["image/png", "image/jpeg", "image/webp", "image/gif", "video/mp4"]),
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
  if (value.kind === "master" && value.mimeType !== "image/png") {
    context.addIssue({ code: "custom", message: "Static masters must use image/png" });
  }
  // Same reasoning as `apng` above: an animated attachment rendition *is* a PNG to everything that
  // transports it, and a static one genuinely is a still PNG.
  if (value.kind === "attachment" && value.mimeType !== "image/png") {
    context.addIssue({ code: "custom", message: "Attachment renditions must use image/png" });
  }
});

export const CompleteUploadRequestSchema = z.object({
  sha256: z.string().regex(/^[a-f0-9]{64}$/i).optional(),
}).strict();

export const PublishExportsRequestSchema = z.object({
  revisionId: z.string().uuid(),
  pngAssetId: z.string().uuid().optional(),
  apngAssetId: z.string().uuid().optional(),
  mp4AssetId: z.string().uuid().optional(),
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
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  previewAsset: AssetV1Schema.nullable(),
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

export type CreateStickerRequest = z.infer<typeof CreateStickerRequestSchema>;
export type ImportStickerRequest = z.infer<typeof ImportStickerRequestSchema>;
export type UpdateStickerRequest = z.infer<typeof UpdateStickerRequestSchema>;
export type RegisterDeviceRequest = z.infer<typeof RegisterDeviceRequestSchema>;
export type CreatePackRequest = z.infer<typeof CreatePackRequestSchema>;
export type UpdatePackRequest = z.infer<typeof UpdatePackRequestSchema>;
export type AddPackItemRequest = z.infer<typeof AddPackItemRequestSchema>;
export type ReorderPackItemsRequest = z.infer<typeof ReorderPackItemsRequestSchema>;
export type UnpublishPackRequest = z.infer<typeof UnpublishPackRequestSchema>;
export type PostChatMessageRequest = z.infer<typeof PostChatMessageRequestSchema>;
export type CreateUploadRequest = z.infer<typeof CreateUploadRequestSchema>;
export type PublishExportsRequest = z.infer<typeof PublishExportsRequestSchema>;
export type SaveEditedDocumentRequest = z.infer<typeof SaveEditedDocumentRequestSchema>;
