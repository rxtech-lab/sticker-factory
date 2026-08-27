import { z } from "zod";
import { Mp4BackgroundV1Schema, StickerDocumentSchema } from "@/lib/contracts/sticker";

export const StickerKindSchema = z.enum(["static", "animated"]);
export const AssetKindSchema = z.enum([
  "reference",
  "mask",
  "master",
  "preview",
  "gif",
  "mp4",
  "system",
  "chat_attachment",
]);

export const CreateStickerRequestSchema = z.object({
  title: z.string().trim().min(1).max(100),
  kind: StickerKindSchema,
  prompt: z.string().trim().min(1).max(4_000),
  referenceAssetIds: z.array(z.string().uuid()).max(8).default([]),
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
}).strict().superRefine((value, context) => {
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
  if (value.kind === "gif" && value.mimeType !== "image/gif") {
    context.addIssue({ code: "custom", message: "GIF exports must use image/gif" });
  }
  if (value.kind === "master" && value.mimeType !== "image/png") {
    context.addIssue({ code: "custom", message: "Static masters must use image/png" });
  }
});

export const CompleteUploadRequestSchema = z.object({
  sha256: z.string().regex(/^[a-f0-9]{64}$/i).optional(),
}).strict();

export const PublishExportsRequestSchema = z.object({
  revisionId: z.string().uuid(),
  pngAssetId: z.string().uuid().optional(),
  gifAssetId: z.string().uuid().optional(),
  mp4AssetId: z.string().uuid().optional(),
  systemAssetId: z.string().uuid(),
  mp4Background: Mp4BackgroundV1Schema.optional(),
}).strict();

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

export type CreateStickerRequest = z.infer<typeof CreateStickerRequestSchema>;
export type PostChatMessageRequest = z.infer<typeof PostChatMessageRequestSchema>;
export type CreateUploadRequest = z.infer<typeof CreateUploadRequestSchema>;
export type PublishExportsRequest = z.infer<typeof PublishExportsRequestSchema>;
export type SaveEditedDocumentRequest = z.infer<typeof SaveEditedDocumentRequestSchema>;
