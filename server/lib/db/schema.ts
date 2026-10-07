import type { CreationPresetSnapshot } from "@/lib/contracts/creation-presets";
import { sql } from "drizzle-orm";
import {
  bigint,
  boolean,
  check,
  doublePrecision,
  index,
  integer,
  jsonb,
  pgTable,
  primaryKey,
  text,
  timestamp,
  uniqueIndex,
  vector,
  type AnyPgColumn,
} from "drizzle-orm/pg-core";
import type { PlaybackBundle } from "@/lib/services/playback";
import type { PlanV1 } from "@/lib/contracts/plan";
import type { StickerDocument } from "@/lib/contracts/sticker";
import type { StickerControlValues } from "@/lib/contracts/configuration";
import type { PetAction } from "@/lib/ai/gateway-contracts";
import { PET_MEMORY_CATEGORIES, PET_MEMORY_DIMENSIONS, PET_THEME_CATEGORIES, PET_WEATHER_KINDS, type PetIdentityV1, type PetSignalsV1 } from "@/lib/contracts/api";
type PetWeatherKind = (typeof PET_WEATHER_KINDS)[number];

/**
 * Every instant is a `timestamptz`, read back as a `Date`.
 *
 * On SQLite these were epoch milliseconds in an INTEGER column; Postgres has a real instant type,
 * so the application-side shape (`Date` in, `Date` out) is unchanged while the database can now
 * compare, index, and print them itself.
 */
const timestampColumn = (name: string) => timestamp(name, { withTimezone: true, mode: "date" });

/**
 * A 64-bit counter read back as a JS number.
 *
 * Postgres `integer` is 32 bits, so a running total in nanodollars would overflow at $2.15 — a
 * ceiling SQLite's 64-bit INTEGER never had. Anything that accumulates spend uses this instead.
 */
const counter = (name: string) => bigint(name, { mode: "number" });

/** The set literal a CHECK constraint needs, from the same array the column's TS union comes from. */
const oneOf = (values: readonly string[]) => sql.raw(values.map((value) => `'${value}'`).join(", "));

const stickerKinds = ["static", "animated"] as const;
const stickerStatuses = ["draft", "published", "deleting"] as const;
const jobKinds = ["image", "edit", "animation", "chat", "plan", "compose", "export", "cleanup"] as const;
const jobStates = ["queued", "running", "waiting", "succeeded", "failed", "cancelled"] as const;
/** Who asked for a job: the user, or their pet growing in the background. */
const jobOrigins = ["user", "pet"] as const;
const messageRoles = ["user", "assistant", "system"] as const;
const messageKinds = [
  "text", "image", "image_edit", "animation", "device_edit", "plan", "export", "status",
] as const;
const messageStatuses = ["complete", "streaming", "failed"] as const;
const imagePlacements = ["replace", "add"] as const;
const assetKinds = [
  "reference", "mask", "master", "preview", "apng", "gif", "mp4", "system", "chat_attachment",
  "sequence", "attachment", "video", "webp", "messenger_whatsapp", "messenger_telegram", "playback",
] as const;
const assetStates = ["pending", "ready", "failed", "deleted"] as const;
const candidateStates = ["candidate", "accepted", "rejected", "superseded"] as const;
const attachmentKinds = ["reference", "mask"] as const;
const eventTypes = [
  "queued", "started", "progress", "document", "candidate", "waiting", "completed", "failed",
] as const;
const planStates = ["draft", "finalized", "confirmed", "superseded", "cancelled"] as const;
const payoutStatuses = ["none", "pending", "active"] as const;
const packStates = ["draft", "published", "unlisted", "removed"] as const;
const monetizations = ["free", "paid", "subscription"] as const;
const installStates = ["installed", "uninstalled"] as const;
const acquisitions = ["free", "purchase", "gift", "promo"] as const;
const devicePlatforms = ["ios"] as const;
const apnsEnvironments = ["sandbox", "production"] as const;

/**
 * The stable OAuth subject, plus the record of a delayed account deletion.
 *
 * The row is never deleted, even when the account is. Every owner FK below cascades from here, so
 * dropping it would take the creator's *published* packs with it — and a published pack outlives
 * its author by design. Deletion therefore purges and anonymizes instead: see
 * `lib/services/account-deletion.ts`. `deletedAt` is what marks the row as a tombstone.
 *
 * An account is pending deletion iff `deletionScheduledAt` is non-null. `deletionRequestId` is a
 * fencing token: a finalize only proceeds while it still matches, which is what makes
 * schedule -> cancel -> re-schedule safe against an in-flight sweep.
 */
export const users = pgTable("users", {
  id: text("id").primaryKey(),
  email: text("email"),
  displayName: text("display_name"),
  deletionScheduledAt: timestampColumn("deletion_scheduled_at"),
  deletionRequestedAt: timestampColumn("deletion_requested_at"),
  deletionRequestId: text("deletion_request_id"),
  /** Set once the deletion has run. The account is gone; only public pack attribution remains. */
  deletedAt: timestampColumn("deleted_at"),
  /**
   * The billing environment Apple last proved for this user. It stands in when StoreKit cannot
   * produce a proof at all, and is only ever written from a verified signature — never `xcode`,
   * which the verifier does not accept.
   */
  lastBillingEnvironment: text("last_billing_environment", { enum: ["sandbox", "production"] }),
  createdAt: timestampColumn("created_at").notNull().$defaultFn(() => new Date()),
  updatedAt: timestampColumn("updated_at").notNull().$defaultFn(() => new Date()),
}, (table) => [
  index("users_deletion_scheduled_at_idx").on(table.deletionScheduledAt),
  check("users_last_billing_environment_check", sql`${table.lastBillingEnvironment} IN ('sandbox', 'production')`),
]);

export const stickers = pgTable("stickers", {
  id: text("id").primaryKey(),
  ownerId: text("owner_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  title: text("title").notNull(),
  kind: text("kind", { enum: stickerKinds }).notNull(),
  status: text("status", { enum: stickerStatuses }).notNull().default("draft"),
  activeRevisionId: text("active_revision_id"),
  /**
   * The single emoji WhatsApp and Telegram file this sticker under.
   *
   * On the sticker rather than the revision: it is a labelling choice, not artwork, and re-editing
   * the drawing is no reason to forget it. Null means the creator never chose one, and the client
   * falls back to its own default. A device-local choice still overrides this.
   */
  messengerEmoji: text("messenger_emoji"),
  /**
   * The user asked for a character whose mood and pose they can switch, so every plan for this
   * project must build one as a sprite layer with the controls bound to it.
   *
   * On the sticker rather than the job, for the same reason `kind` is: it is a standing choice made
   * once when the project was created, and a revision two turns later still has to honour it.
   * Animated projects only — a still has no clips to switch between.
   */
  creationPresets: jsonb("creation_presets").$type<CreationPresetSnapshot>(),
  controllable: boolean("controllable").notNull().default(false),
  posePreset: text("pose_preset", { enum: ["low", "medium", "high", "ultra"] }),
  /**
   * Whether the character travels around the canvas rather than resting in place.
   *
   * Defaults to false, and like `controllable` it is a standing choice rather than a per-turn one:
   * a sticker asked to hold still must still hold still two edits later.
   */
  motion: boolean("motion").notNull().default(false),
  createdAt: timestampColumn("created_at").notNull().$defaultFn(() => new Date()),
  updatedAt: timestampColumn("updated_at").notNull().$defaultFn(() => new Date()),
  deletedAt: timestampColumn("deleted_at"),
}, (table) => [
  index("stickers_owner_updated_idx").on(table.ownerId, table.updatedAt, table.id),
  index("stickers_owner_status_updated_idx").on(table.ownerId, table.status, table.updatedAt, table.id),
  check("stickers_pose_preset_check", sql`${table.posePreset} IS NULL OR ${table.posePreset} IN ('low', 'medium', 'high', 'ultra')`),
  check("stickers_kind_check", sql`${table.kind} IN (${oneOf(stickerKinds)})`),
  check("stickers_status_check", sql`${table.status} IN (${oneOf(stickerStatuses)})`),
]);

export const chatThreads = pgTable("chat_threads", {
  id: text("id").primaryKey(),
  stickerId: text("sticker_id").notNull().references(() => stickers.id, { onDelete: "cascade" }),
  ownerId: text("owner_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  createdAt: timestampColumn("created_at").notNull().$defaultFn(() => new Date()),
  updatedAt: timestampColumn("updated_at").notNull().$defaultFn(() => new Date()),
}, (table) => [
  uniqueIndex("chat_threads_sticker_unique").on(table.stickerId),
  index("chat_threads_owner_idx").on(table.ownerId),
]);

export const generationJobs = pgTable("generation_jobs", {
  id: text("id").primaryKey(),
  ownerId: text("owner_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  stickerId: text("sticker_id").notNull().references(() => stickers.id, { onDelete: "cascade" }),
  sourceMessageId: text("source_message_id"),
  kind: text("kind", { enum: jobKinds }).notNull(),
  /**
   * Started from the Messages extension's quick mode, so its images are drawn by
   * `AI_QUICK_IMAGE_MODEL` against a chroma backdrop instead of by `AI_IMAGE_MODEL`.
   */
  quick: boolean("quick").notNull().default(false),
  appClip: boolean("app_clip").notNull().default(false),
  /**
   * `pet` for a turn the user's pet started on its own sticker while evolving. Those are free to
   * the user and announce nothing: the pet says so itself once the new look is published.
   */
  origin: text("origin", { enum: jobOrigins }).notNull().default("user"),
  usageReservationId: text("usage_reservation_id"),
  priorStickerStatus: text("prior_sticker_status", { enum: ["draft", "published"] }),
  state: text("state", { enum: jobStates }).notNull().default("queued"),
  workflowRunId: text("workflow_run_id"),
  /**
   * The RxSubscription hold placed before this job was queued, and its estimate.
   * The exact API-priced amount is accumulated below and settled on success.
   * Null once the hold is closed, or when the job is free — and always null
   * when billing is unconfigured.
   */
  reservationId: text("reservation_id"),
  /** Environment that created the hold; workers/refunds must never infer it from a later request. */
  billingEnvironment: text("billing_environment", { enum: ["xcode", "sandbox", "production"] }),
  reservationAmount: integer("reservation_amount").notNull().default(0),
  /** Text USD is rounded once for the turn; each image is rounded before entering apiImagePoints. */
  apiTextCostNanodollars: counter("api_text_cost_nanodollars").notNull().default(0),
  apiImageCostNanodollars: counter("api_image_cost_nanodollars").notNull().default(0),
  apiImagePoints: integer("api_image_points").notNull().default(0),
  /** Video clips keep the image shape: an exact USD audit total, and points rounded up per clip. */
  apiVideoCostNanodollars: counter("api_video_cost_nanodollars").notNull().default(0),
  apiVideoPoints: integer("api_video_points").notNull().default(0),
  attempts: integer("attempts").notNull().default(0),
  errorCode: text("error_code"),
  errorMessage: text("error_message"),
  createdAt: timestampColumn("created_at").notNull().$defaultFn(() => new Date()),
  updatedAt: timestampColumn("updated_at").notNull().$defaultFn(() => new Date()),
  completedAt: timestampColumn("completed_at"),
}, (table) => [
  index("generation_jobs_owner_created_idx").on(table.ownerId, table.createdAt),
  index("generation_jobs_sticker_state_idx").on(table.stickerId, table.state),
  uniqueIndex("generation_jobs_one_active_per_sticker")
    .on(table.stickerId)
    .where(sql`${table.state} IN ('queued', 'running', 'waiting')`),
  check("generation_jobs_kind_check", sql`${table.kind} IN (${oneOf(jobKinds)})`),
  check("generation_jobs_origin_check", sql`${table.origin} IN (${oneOf(jobOrigins)})`),
  check("generation_jobs_state_check", sql`${table.state} IN (${oneOf(jobStates)})`),
  check("generation_jobs_billing_environment_check", sql`${table.billingEnvironment} IN ('xcode', 'sandbox', 'production')`),
]);

export const chatMessages = pgTable("chat_messages", {
  id: text("id").primaryKey(),
  threadId: text("thread_id").notNull().references(() => chatThreads.id, { onDelete: "cascade" }),
  ownerId: text("owner_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  role: text("role", { enum: messageRoles }).notNull(),
  /** `device_edit` is the on-device editor saving a revision; the transcript draws it as a marker. */
  kind: text("kind", { enum: messageKinds }).notNull(),
  content: text("content").notNull(),
  targetLayerId: text("target_layer_id"),
  baseRevisionId: text("base_revision_id"),
  imagePlacement: text("image_placement", { enum: imagePlacements }).notNull().default("replace"),
  sequence: integer("sequence").notNull(),
  revisionId: text("revision_id"),
  jobId: text("job_id").references(() => generationJobs.id, { onDelete: "set null" }),
  status: text("status", { enum: messageStatuses }).notNull().default("complete"),
  /** For a `kind: "plan"` card: which plan it renders, and which revision it was showing. */
  planId: text("plan_id").references((): AnyPgColumn => plans.id, { onDelete: "set null" }),
  planRevision: integer("plan_revision"),
  createdAt: timestampColumn("created_at").notNull().$defaultFn(() => new Date()),
}, (table) => [
  uniqueIndex("chat_messages_thread_sequence_unique").on(table.threadId, table.sequence),
  index("chat_messages_thread_created_idx").on(table.threadId, table.createdAt),
  check("chat_messages_role_check", sql`${table.role} IN (${oneOf(messageRoles)})`),
  check("chat_messages_kind_check", sql`${table.kind} IN (${oneOf(messageKinds)})`),
  check("chat_messages_status_check", sql`${table.status} IN (${oneOf(messageStatuses)})`),
]);

export const assets = pgTable("assets", {
  id: text("id").primaryKey(),
  ownerId: text("owner_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  stickerId: text("sticker_id").references(() => stickers.id, { onDelete: "cascade" }),
  /**
   * `sequence` is a frame atlas: one transparent PNG holding a grid of frames lifted from a Live
   * Photo. Unlike every other kind, its `frame_count`/`fps`/`duration_seconds` are declared by the
   * client at upload time rather than read out of the file — the file itself is a single still.
   *
   * `video` is a generated clip: an opaque 1:1 MP4 on a chroma backdrop, keyed out on device. Its
   * `frame_count`/`fps`/`duration_seconds` are read out of the container by `inspectMp4`.
   */
  kind: text("kind", { enum: assetKinds }).notNull(),
  state: text("state", { enum: assetStates }).notNull().default("pending"),
  r2Key: text("r2_key").notNull().unique(),
  mimeType: text("mime_type").notNull(),
  byteSize: integer("byte_size"),
  width: integer("width"),
  height: integer("height"),
  frameCount: integer("frame_count"),
  durationSeconds: doublePrecision("duration_seconds"),
  fps: doublePrecision("fps"),
  sha256: text("sha256"),
  hasAlpha: boolean("has_alpha"),
  originalFilename: text("original_filename"),
  createdAt: timestampColumn("created_at").notNull().$defaultFn(() => new Date()),
  readyAt: timestampColumn("ready_at"),
  /**
   * The atlas grid, for `sequence` assets only. `frameCount`/`fps` say how many frames there are
   * and how fast they play; only this says where each one sits, and the image cannot say — a sprite
   * sheet looks exactly like any other still.
   */
  sequenceColumns: integer("sequence_columns"),
  sequenceRows: integer("sequence_rows"),
}, (table) => [
  index("assets_owner_created_idx").on(table.ownerId, table.createdAt),
  index("assets_sticker_kind_idx").on(table.stickerId, table.kind),
  check("assets_kind_check", sql`${table.kind} IN (${oneOf(assetKinds)})`),
  check("assets_state_check", sql`${table.state} IN (${oneOf(assetStates)})`),
]);

export const stickerRevisions = pgTable("sticker_revisions", {
  id: text("id").primaryKey(),
  stickerId: text("sticker_id").notNull().references(() => stickers.id, { onDelete: "cascade" }),
  parentRevisionId: text("parent_revision_id"),
  sourceMessageId: text("source_message_id").references(() => chatMessages.id, { onDelete: "set null" }),
  kind: text("kind", { enum: stickerKinds }).notNull(),
  candidateState: text("candidate_state", { enum: candidateStates }).notNull().default("candidate"),
  documentJson: jsonb("document_json").$type<StickerDocument>().notNull(),
  playbackJson: jsonb("playback_json").$type<PlaybackBundle>(),
  masterAssetId: text("master_asset_id").references(() => assets.id, { onDelete: "set null" }),
  previewAssetId: text("preview_asset_id").references(() => assets.id, { onDelete: "set null" }),
  pngAssetId: text("png_asset_id").references(() => assets.id, { onDelete: "set null" }),
  /**
   * The sharing rendition as it was written before APNG replaced it.
   *
   * Read-only now: nothing publishes a GIF any more, but 121 revisions were published pointing at
   * one, and this column is the only thing that finds their artwork. It sits beside `apngAssetId`
   * rather than being renamed into it because a rename that guessed wrong would take every one of
   * those revisions' sharing rendition with it.
   */
  gifAssetId: text("gif_asset_id").references(() => assets.id, { onDelete: "set null" }),
  /** The sharing rendition every export written since the switch produces. */
  apngAssetId: text("apng_asset_id").references(() => assets.id, { onDelete: "set null" }),
  mp4AssetId: text("mp4_asset_id").references(() => assets.id, { onDelete: "set null" }),
  systemAssetId: text("system_asset_id").references(() => assets.id, { onDelete: "set null" }),
  /**
   * Smaller copies of the sharing rendition, so WinkySticker can choose how big a sticker arrives.
   *
   * Large has no column of its own: it *is* the sharing rendition, `apngAssetId` for an animated
   * sticker and `pngAssetId` for a static one. These two are the same artwork at 408 and 300 px,
   * rendered without the 500 KB ceiling and therefore at the document's own frame rate — unlike
   * `systemAssetId`, which is the only rendition Apple's limit governs.
   */
  attachmentMediumAssetId: text("attachment_medium_asset_id").references(() => assets.id, { onDelete: "set null" }),
  attachmentSmallAssetId: text("attachment_small_asset_id").references(() => assets.id, { onDelete: "set null" }),
  /**
   * The same artwork as the sharing rendition, in WebP, at one of `SHARING_APNG_DIMENSIONS`.
   *
   * Only WinkySticker's `.image` mode reads it, and only as a size optimisation — the APNG stays
   * the sharing rendition everywhere else. Null is the ordinary state: every revision published
   * before this column existed has none, and so does any client without a WebP encoder.
   */
  webpAssetId: text("webp_asset_id").references(() => assets.id, { onDelete: "set null" }),
  /**
   * The 512 px copies WhatsApp and Telegram accept, encoded on the phone when the sticker is added
   * to a pack. WhatsApp is always WebP; Telegram is a still PNG for a static sticker and a
   * transparent VP9 WebM for an animated one, so the sticker's own `kind` says which arrived.
   *
   * They hang off the revision rather than the sticker because they are derived artwork: a new
   * revision has different pixels, and inheriting the old encodings would send the wrong sticker.
   * Null is an ordinary state — every revision published before this column existed has none, and a
   * sticker whose artwork cannot be squeezed under a messenger's ceiling never gets one.
   */
  whatsappAssetId: text("whatsapp_asset_id").references(() => assets.id, { onDelete: "set null" }),
  telegramAssetId: text("telegram_asset_id").references(() => assets.id, { onDelete: "set null" }),
  createdAt: timestampColumn("created_at").notNull().$defaultFn(() => new Date()),
  decidedAt: timestampColumn("decided_at"),
}, (table) => [
  index("sticker_revisions_sticker_created_idx").on(table.stickerId, table.createdAt),
  index("sticker_revisions_parent_idx").on(table.parentRevisionId),
  check("sticker_revisions_kind_check", sql`${table.kind} IN (${oneOf(stickerKinds)})`),
  check("sticker_revisions_candidate_state_check", sql`${table.candidateState} IN (${oneOf(candidateStates)})`),
]);

export const chatAttachments = pgTable("chat_attachments", {
  messageId: text("message_id").notNull().references(() => chatMessages.id, { onDelete: "cascade" }),
  assetId: text("asset_id").notNull().references(() => assets.id, { onDelete: "cascade" }),
  kind: text("kind", { enum: attachmentKinds }).notNull(),
  targetLayerId: text("target_layer_id"),
  position: integer("position").notNull().default(0),
}, (table) => [
  primaryKey({ columns: [table.messageId, table.assetId] }),
  index("chat_attachments_asset_idx").on(table.assetId),
  check("chat_attachments_kind_check", sql`${table.kind} IN (${oneOf(attachmentKinds)})`),
]);

export const generationEvents = pgTable("generation_events", {
  /**
   * `generatedByDefault` rather than `generatedAlways` so the Turso import could carry the original
   * ids across; the sequence was set past the highest one afterwards.
   */
  id: integer("id").primaryKey().generatedByDefaultAsIdentity(),
  jobId: text("job_id").notNull().references(() => generationJobs.id, { onDelete: "cascade" }),
  ownerId: text("owner_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  type: text("type", { enum: eventTypes }).notNull(),
  dataJson: jsonb("data_json").$type<Record<string, unknown>>().notNull(),
  createdAt: timestampColumn("created_at").notNull().$defaultFn(() => new Date()),
}, (table) => [
  index("generation_events_job_id_idx").on(table.jobId, table.id),
  index("generation_events_owner_id_idx").on(table.ownerId, table.id),
  check("generation_events_type_check", sql`${table.type} IN (${oneOf(eventTypes)})`),
]);

/**
 * The design of a sticker, drafted and revised by the agent before anything is generated.
 *
 * Kept out of `chat_messages` so the actionable state (is it still a draft? has it been confirmed?
 * which job ran it?) is a first-class row rather than something inferred from the transcript. The
 * agent may rewrite `plan_json` any number of times while the plan is a `draft`, bumping `revision`
 * each time; `finalize_plan` freezes it and hands the decision to the user. Starting a fresh plan
 * while an earlier one is already finalized or confirmed links the new row via `supersedes_id`
 * rather than mutating the old one, so a confirmed plan always still describes what was built.
 */
export const plans = pgTable("plans", {
  id: text("id").primaryKey(),
  ownerId: text("owner_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  stickerId: text("sticker_id").notNull().references(() => stickers.id, { onDelete: "cascade" }),
  threadId: text("thread_id").notNull().references(() => chatThreads.id, { onDelete: "cascade" }),
  /** The message the plan was first shown in. Not unique: one plan can be shown many times. */
  messageId: text("message_id").notNull().references(() => chatMessages.id, { onDelete: "cascade" }),
  planJson: jsonb("plan_json").$type<PlanV1>().notNull(),
  state: text("state", { enum: planStates }).notNull().default("draft"),
  /** Bumped by every `update_plan`, so a card can say which revision it rendered. */
  revision: integer("revision").notNull().default(1),
  supersedesId: text("supersedes_id").references((): AnyPgColumn => plans.id, { onDelete: "set null" }),
  /** Saved version activated by this copy; keeps prior builds and version numbers intact. */
  restoredFromId: text("restored_from_id").references((): AnyPgColumn => plans.id, { onDelete: "set null" }),
  jobId: text("job_id").references(() => generationJobs.id, { onDelete: "set null" }),
  /** The approved resting composition used to build the sticker. */
  conceptAssetId: text("concept_asset_id").references(() => assets.id, { onDelete: "set null" }),
  /** An illustrated motion/expression guide, separate from the resting extraction reference. */
  animationPreviewAssetId: text("animation_preview_asset_id").references(() => assets.id, { onDelete: "set null" }),
  /** Why the user rejected the plan. Fed back into the next planning turn. */
  decisionReason: text("decision_reason"),
  createdAt: timestampColumn("created_at").notNull().$defaultFn(() => new Date()),
  updatedAt: timestampColumn("updated_at").notNull().$defaultFn(() => new Date()),
  decidedAt: timestampColumn("decided_at"),
}, (table) => [
  index("plans_sticker_state_idx").on(table.stickerId, table.state),
  index("plans_owner_created_idx").on(table.ownerId, table.createdAt),
  check("plans_state_check", sql`${table.state} IN (${oneOf(planStates)})`),
]);

/**
 * The creator's public identity in the marketplace.
 *
 * Kept out of `users` because OAuth owns account profile data while marketplace identity is
 * user-authored application state. `handle` is the only creator identifier that appears in URLs
 * and response bodies — the OAuth `sub` never leaves the server.
 */
export const creatorProfiles = pgTable("creator_profiles", {
  userId: text("user_id").primaryKey().references(() => users.id, { onDelete: "cascade" }),
  handle: text("handle").notNull(),
  displayName: text("display_name"),
  bio: text("bio"),
  avatarAssetId: text("avatar_asset_id").references(() => assets.id, { onDelete: "set null" }),
  /** Monetization placeholders. Nothing reads or writes these yet. */
  payoutStatus: text("payout_status", { enum: payoutStatuses }).notNull().default("none"),
  payoutProvider: text("payout_provider"),
  payoutAccountRef: text("payout_account_ref"),
  createdAt: timestampColumn("created_at").notNull().$defaultFn(() => new Date()),
  updatedAt: timestampColumn("updated_at").notNull().$defaultFn(() => new Date()),
}, (table) => [
  uniqueIndex("creator_profiles_handle_unique").on(table.handle),
  check("creator_profiles_payout_status_check", sql`${table.payoutStatus} IN (${oneOf(payoutStatuses)})`),
]);

/**
 * A published bundle of the creator's own stickers.
 *
 * `installCount` is current installs (what the UI shows); `installTotal` is lifetime and never
 * decremented. Both are trigger-maintained rather than counted per row, because browse sorts by
 * popularity and shows a count on every card.
 */
export const stickerPacks = pgTable("sticker_packs", {
  id: text("id").primaryKey(),
  creatorId: text("creator_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  /** Immutable once published, so a shared link never rots when the title changes. */
  slug: text("slug").notNull(),
  title: text("title").notNull(),
  summary: text("summary"),
  state: text("state", { enum: packStates }).notNull().default("draft"),
  coverStickerId: text("cover_sticker_id").references(() => stickers.id, { onDelete: "set null" }),
  itemCount: integer("item_count").notNull().default(0),
  installCount: integer("install_count").notNull().default(0),
  installTotal: integer("install_total").notNull().default(0),
  /** Monetization placeholders. Every pack is free today; nothing charges. */
  monetization: text("monetization", { enum: monetizations }).notNull().default("free"),
  priceCents: integer("price_cents").notNull().default(0),
  currency: text("currency").notNull().default("USD"),
  revenueShareBps: integer("revenue_share_bps").notNull().default(0),
  publishedAt: timestampColumn("published_at"),
  createdAt: timestampColumn("created_at").notNull().$defaultFn(() => new Date()),
  updatedAt: timestampColumn("updated_at").notNull().$defaultFn(() => new Date()),
}, (table) => [
  uniqueIndex("sticker_packs_slug_unique").on(table.slug),
  index("sticker_packs_creator_updated_idx").on(table.creatorId, table.updatedAt),
  index("sticker_packs_state_published_idx").on(table.state, table.publishedAt),
  index("sticker_packs_state_installs_idx").on(table.state, table.installCount),
  check("sticker_packs_state_check", sql`${table.state} IN (${oneOf(packStates)})`),
  check("sticker_packs_monetization_check", sql`${table.monetization} IN (${oneOf(monetizations)})`),
]);

export const stickerPackItems = pgTable("sticker_pack_items", {
  packId: text("pack_id").notNull().references(() => stickerPacks.id, { onDelete: "cascade" }),
  stickerId: text("sticker_id").notNull().references(() => stickers.id, { onDelete: "cascade" }),
  position: integer("position").notNull().default(0),
  addedAt: timestampColumn("added_at").notNull().$defaultFn(() => new Date()),
}, (table) => [
  primaryKey({ columns: [table.packId, table.stickerId] }),
  index("sticker_pack_items_pack_position_idx").on(table.packId, table.position, table.stickerId),
  index("sticker_pack_items_sticker_idx").on(table.stickerId),
]);

/**
 * Uninstall flips `state`; it never deletes the row. That keeps uninstall/reinstall idempotent and
 * preserves the (future) entitlement, so a user who paid and later removed a pack never pays twice.
 */
export const packInstalls = pgTable("pack_installs", {
  packId: text("pack_id").notNull().references(() => stickerPacks.id, { onDelete: "cascade" }),
  userId: text("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  state: text("state", { enum: installStates }).notNull().default("installed"),
  position: integer("position").notNull().default(0),
  /** Entitlement placeholders. Every acquisition is `free` today. */
  acquisition: text("acquisition", { enum: acquisitions }).notNull().default("free"),
  priceCentsPaid: integer("price_cents_paid").notNull().default(0),
  orderRef: text("order_ref"),
  installedAt: timestampColumn("installed_at").notNull().$defaultFn(() => new Date()),
  uninstalledAt: timestampColumn("uninstalled_at"),
}, (table) => [
  primaryKey({ columns: [table.packId, table.userId] }),
  index("pack_installs_user_state_idx").on(
    table.userId,
    table.state,
    table.position,
    table.installedAt,
    table.packId,
  ),
  index("pack_installs_pack_state_idx").on(table.packId, table.state),
  check("pack_installs_state_check", sql`${table.state} IN (${oneOf(installStates)})`),
  check("pack_installs_acquisition_check", sql`${table.acquisition} IN (${oneOf(acquisitions)})`),
]);

/**
 * Where to reach a user who is not looking at the app.
 *
 * Generation runs on the server, so the server is the only party that reliably sees a turn end: the
 * client's event stream is gone the moment iOS suspends it, which is precisely when a banner is
 * worth sending. The APNs device token is the primary key because it names an app install, not a
 * person — re-registering after a different account signs in on the same phone must move the row
 * rather than leave the old owner pushing to it.
 */
export const deviceTokens = pgTable("device_tokens", {
  token: text("token").primaryKey(),
  userId: text("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  platform: text("platform", { enum: devicePlatforms }).notNull().default("ios"),
  /** A sandbox token is rejected by the production APNs host and vice versa. */
  environment: text("environment", { enum: apnsEnvironments }).notNull().default("production"),
  bundleId: text("bundle_id"),
  appVersion: text("app_version"),
  createdAt: timestampColumn("created_at").notNull().$defaultFn(() => new Date()),
  updatedAt: timestampColumn("updated_at").notNull().$defaultFn(() => new Date()),
  lastSeenAt: timestampColumn("last_seen_at").notNull().$defaultFn(() => new Date()),
  /** Set when APNs says the token is gone. Registering the same token again clears it. */
  disabledAt: timestampColumn("disabled_at"),
  disabledReason: text("disabled_reason"),
}, (table) => [
  index("device_tokens_user_active_idx").on(table.userId, table.disabledAt),
  check("device_tokens_platform_check", sql`${table.platform} IN (${oneOf(devicePlatforms)})`),
  check("device_tokens_environment_check", sql`${table.environment} IN (${oneOf(apnsEnvironments)})`),
]);

export const idempotencyKeys = pgTable("idempotency_keys", {
  ownerId: text("owner_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  operation: text("operation").notNull(),
  key: text("key").notNull(),
  requestHash: text("request_hash").notNull(),
  responseStatus: integer("response_status"),
  responseJson: jsonb("response_json").$type<unknown>(),
  createdAt: timestampColumn("created_at").notNull().$defaultFn(() => new Date()),
  expiresAt: timestampColumn("expires_at").notNull(),
}, (table) => [
  primaryKey({ columns: [table.ownerId, table.operation, table.key] }),
  index("idempotency_keys_expiry_idx").on(table.expiresAt),
]);

export type StickerRow = typeof stickers.$inferSelect;
export type RevisionRow = typeof stickerRevisions.$inferSelect;
export type AssetRow = typeof assets.$inferSelect;
export type ChatMessageRow = typeof chatMessages.$inferSelect;
export type GenerationJobRow = typeof generationJobs.$inferSelect;
export type PlanRow = typeof plans.$inferSelect;
export type UserRow = typeof users.$inferSelect;
export type CreatorProfileRow = typeof creatorProfiles.$inferSelect;
export type StickerPackRow = typeof stickerPacks.$inferSelect;
export type StickerPackItemRow = typeof stickerPackItems.$inferSelect;
export type PackInstallRow = typeof packInstalls.$inferSelect;
export type DeviceTokenRow = typeof deviceTokens.$inferSelect;

/** Per-activity tokens are distinct from notification device tokens and expire with the activity. */
export const generationLiveActivities = pgTable("generation_live_activities", {
  activityId: text("activity_id").primaryKey(),
  ownerId: text("owner_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  jobId: text("job_id").notNull().references(() => generationJobs.id, { onDelete: "cascade" }),
  token: text("token").notNull(),
  environment: text("environment", { enum: ["sandbox", "production"] }).notNull(),
  expiresAt: timestampColumn("expires_at").notNull(),
  lastEventId: integer("last_event_id").notNull().default(0),
  lastPushTimestamp: integer("last_push_timestamp").notNull().default(0),
}, (table) => [
  index("generation_live_activities_job_idx").on(table.jobId),
  check("generation_live_activities_environment_check", sql`${table.environment} IN ('sandbox', 'production')`),
]);

/**
 * The controllable sticker a user has adopted as their pet — what the watch and widget show.
 *
 * One row per user, keyed by the user, so choosing another pet replaces the row instead of adding
 * one. The sticker need not be the user's own: a member of an installed pack is just as posable,
 * and `lib/services/pets.ts` holds the pet to the same access rule playback is read under.
 * Deleting the sticker takes the choice with it rather than leaving a pet with no artwork.
 */
export const userPets = pgTable("user_pets", {
  userId: text("user_id").primaryKey().references(() => users.id, { onDelete: "cascade" }),
  stickerId: text("sticker_id").notNull().references(() => stickers.id, { onDelete: "cascade" }),
  /**
   * The pose the pet holds and the caption under it, as the agent last read the user's sends.
   *
   * Null until the first send is read, and cleared when another pet is adopted: the values are ids
   * of *this* pet's controls, and meaningless against another sticker's.
   */
  statusJson: jsonb("status_json").$type<PetStatus>(),
  statusUpdatedAt: timestampColumn("status_updated_at"),
  statsJson: jsonb("stats_json").$type<PetStatsValues>(),
  actionsJson: jsonb("actions_json").$type<PetAction[]>(),
  itemsJson: jsonb("items_json").$type<PetAction[]>(),
  itemsArtKey: text("items_art_key"),
  itemsContextKey: text("items_context_key"),
  itemsUpdatedAt: timestampColumn("items_updated_at"),
  itemsClaimedAt: timestampColumn("items_claimed_at"),
  /** The owner's local date the shop last restocked on; it restocks once a day. */
  itemsDate: text("items_date"),
  /** Things bought from the item shop to use later, one row each, kept for this life until they expire. */
  bagJson: jsonb("bag_json").$type<PetBagUnit[]>().notNull().default([]),
  interactionId: text("interaction_id"),
  /** Who this pet is: class, personality, preferences, and the world it was adopted into. */
  identityJson: jsonb("identity_json").$type<PetIdentityV1>(),
  /** The phone's last coarse context — rounded location, steps today, time zone. */
  contextJson: jsonb("context_json").$type<PetStoredContext>(),
  /** The signals last resolved from that context, headlines included, so a send can reuse them. */
  signalsJson: jsonb("signals_json").$type<PetSignalsV1>(),
  signalsUpdatedAt: timestampColumn("signals_updated_at"),
  /**
   * Names this pet's life. A new pet gets a new one, and a life workflow that wakes to find a
   * different id knows it is no longer this pet's and ends.
   */
  lifeId: text("life_id"),
  lifeRunId: text("life_run_id"),
  lifeTickAt: timestampColumn("life_tick_at"),
  nextEventAt: timestampColumn("next_event_at"),
  lastShareAt: timestampColumn("last_share_at"),
  /**
   * The most recent send, written before the agent runs. A reading only lands if this is still the
   * send it was asked about, so a slow answer about an old sticker never overwrites a newer one.
   */
  lastSentStickerId: text("last_sent_sticker_id").references(() => stickers.id, { onDelete: "set null" }),
  lastSentAt: timestampColumn("last_sent_at"),
  /**
   * The pet growing a new mood, property or look on its own sticker, while it runs and after it
   * ends. Only one at a time: a pet that is already evolving is not offered another.
   */
  evolutionJson: jsonb("evolution_json").$type<PetEvolution>(),
  /** When the last evolution started, so a pet grows at most once per cooldown. */
  lastEvolvedAt: timestampColumn("last_evolved_at"),
  /** What the pet is ill with, and since when. Null while it is well. */
  illnessJson: jsonb("illness_json").$type<PetIllness>(),
  /** Doses of medicine the pet has, won from its daily encounters or bought. One cures an illness. */
  medicine: integer("medicine").notNull().default(0),
  /**
   * The room the pet lives in, bought from its shop: drawn behind it on the tab, and good for it
   * once a day. Null for the plain page. Kept when the owner adopts another pet, like the room is.
   */
  roomId: text("room_id").references((): AnyPgColumn => petRooms.id, { onDelete: "set null" }),
  /** The owner's local date the room last comforted the pet, so it does once a day. */
  roomEffectDate: text("room_effect_date"),
  /** When the room shop last put new rooms up, and a refresh in flight, like the items'. */
  roomsOfferedAt: timestampColumn("rooms_offered_at"),
  roomsClaimedAt: timestampColumn("rooms_claimed_at"),
  /**
   * The place the pet has gone, drawn behind it in place of its room; null while it is at home.
   * Its agent moves it on the life workflow's visits, and the owner may too, as its rules allow.
   */
  themeId: text("theme_id").references((): AnyPgColumn => petThemes.id, { onDelete: "set null" }),
  /** The minutes the pet spent at each place on the owner's local date, for places that limit them. */
  themeUsageJson: jsonb("theme_usage_json").$type<PetThemeUsage>(),
  /** When the pet's agent last went looking for new places, and a search in flight, like the rooms'. */
  themesDiscoveredAt: timestampColumn("themes_discovered_at"),
  themesClaimedAt: timestampColumn("themes_claimed_at"),
  createdAt: timestampColumn("created_at").notNull().$defaultFn(() => new Date()),
  updatedAt: timestampColumn("updated_at").notNull().$defaultFn(() => new Date()),
}, (table) => [
  index("user_pets_sticker_idx").on(table.stickerId),
]);

/**
 * What the owner's gold has been paid for, shared by every pet they ever have: adopting another
 * pet or letting one go leaves it where it is. The gold itself is a balance in RxSubscription,
 * unit `gold`, next to the owner's points — so a points pack can carry gold too. Earned by walking,
 * a daily allowance and making stickers, spent on actions, items and rooms.
 *
 * Written only alongside a pet's stats, guarded by `version` so two changes racing never pay the
 * same day or steps twice.
 */
export const userWallets = pgTable("user_wallets", {
  userId: text("user_id").primaryKey().references(() => users.id, { onDelete: "cascade" }),
  /** The steps already paid out on the phone's local date, so a walk is only paid once. */
  walkGoldJson: jsonb("walk_gold_json").$type<PetWalkGold>(),
  /** The owner's local date the daily gold was last granted on. */
  dailyGoldDate: text("daily_gold_date"),
  version: integer("version").notNull().default(0),
  createdAt: timestampColumn("created_at").notNull().$defaultFn(() => new Date()),
  updatedAt: timestampColumn("updated_at").notNull().$defaultFn(() => new Date()),
});
export type UserWalletRow = typeof userWallets.$inferSelect;

/**
 * Every move of the owner's gold, written here first and then carried to RxSubscription — the
 * outbox that keeps a gold change and the pet change it belongs to together. A row is written in
 * the same transaction as what it pays for, so a retried step never pays the same sticker twice,
 * and is carried with its own id as the idempotency key, so a retried carry never moves it twice.
 * `settledAt` is set once RxSubscription has it.
 *
 * The id names what moved the gold, like `sticker:<jobId>` or `pet:<uuid>`. A spend (negative
 * `gold`) is held in RxSubscription before its row is written, and its row settles that hold.
 */
export const userWalletGrants = pgTable("user_wallet_grants", {
  id: text("id").primaryKey(),
  userId: text("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  kind: text("kind", { enum: ["sticker", "pet", "starting"] }).notNull(),
  gold: integer("gold").notNull(),
  /** The RxSubscription hold a spend settles. */
  reservationId: text("reservation_id"),
  /** The RxSubscription environment the gold moves in, or null for the deployment's own. */
  billingEnvironment: text("billing_environment", { enum: ["xcode", "sandbox", "production"] }),
  settledAt: timestampColumn("settled_at"),
  createdAt: timestampColumn("created_at").notNull(),
}, (table) => [
  index("user_wallet_grants_user_idx").on(table.userId, table.createdAt),
  index("user_wallet_grants_unsettled_idx").on(table.userId).where(sql`${table.settledAt} IS NULL`),
  check("user_wallet_grants_kind_check", sql`${table.kind} IN ('sticker', 'pet', 'starting')`),
  check("user_wallet_grants_billing_environment_check",
    sql`${table.billingEnvironment} IN ('xcode', 'sandbox', 'production')`),
]);
export type UserWalletGrantRow = typeof userWalletGrants.$inferSelect;

/**
 * A place drawn into a room for the app to write on: a 0–1 box in the room's drawing, its outline,
 * the blank surface the server painted there, and the ink that reads on it, both `#RRGGBB`.
 */
export type PetRoomFixture = {
  x: number;
  y: number;
  width: number;
  height: number;
  shape: "round" | "rect";
  face: string;
  ink: string;
};
/**
 * Where a room or place shows the time, the weather and the pet's stats. Any is null when the drawing
 * has no place for it; `status` is absent from rooms drawn before status boards.
 */
export type PetRoomFixtures = { clock: PetRoomFixture | null; weather: PetRoomFixture | null; status?: PetRoomFixture | null };

/**
 * A room the owner's pets can live in, drawn by the pet's agent: offered in the room shop until it
 * is bought or the shop moves on, then the owner's for good, whichever pet they have.
 */
export const petRooms = pgTable("pet_rooms", {
  id: text("id").primaryKey(),
  userId: text("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  title: text("title").notNull(),
  description: text("description").notNull(),
  /** What living here does to the pet, once a day. Gold is never one of them. */
  effectsJson: jsonb("effects_json").$type<{ happiness: number; hp: number; energy: number }>().notNull(),
  price: integer("price").notNull(),
  /** Names the drawing in storage; a room is drawn once and never changes. */
  artKey: text("art_key").notNull(),
  /** Its clock face, weather board and status board. Null for rooms drawn before rooms had them. */
  fixturesJson: jsonb("fixtures_json").$type<PetRoomFixtures>(),
  state: text("state", { enum: ["offered", "owned"] }).notNull(),
  createdAt: timestampColumn("created_at").notNull(),
  purchasedAt: timestampColumn("purchased_at"),
}, (table) => [
  index("pet_rooms_user_idx").on(table.userId, table.state, table.createdAt),
  check("pet_rooms_state_check", sql`${table.state} IN ('offered', 'owned')`),
  check("pet_rooms_price_check", sql`${table.price} >= 0`),
]);
export type PetRoomRow = typeof petRooms.$inferSelect;

/**
 * A place the owner's pets can go, discovered and drawn by the pet's agent from the owner's world:
 * a café round the corner, the park in the rain, the city they flew to. A limited one — a trip, a
 * special event, an accident — has `expiresAt`, and once past it is `expired` for good.
 */
export const petThemes = pgTable("pet_themes", {
  id: text("id").primaryKey(),
  userId: text("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  title: text("title").notNull(),
  description: text("description").notNull(),
  category: text("category", { enum: PET_THEME_CATEGORIES }).notNull(),
  /** What being here does to the pet on each of its visits. Gold is never one of them. */
  effectsJson: jsonb("effects_json").$type<{ happiness: number; hp: number; energy: number }>().notNull(),
  /** When, where and in what weather the pet may be here, and for how long a day. */
  rulesJson: jsonb("rules_json").$type<PetThemeRules>().notNull(),
  /** Names the drawing in storage; a place is drawn once and never changes. */
  artKey: text("art_key").notNull(),
  /** Its clock, weather board and status board. Null for places drawn before places had them. */
  fixturesJson: jsonb("fixtures_json").$type<PetRoomFixtures>(),
  state: text("state", { enum: ["available", "expired"] }).notNull(),
  expiresAt: timestampColumn("expires_at"),
  createdAt: timestampColumn("created_at").notNull(),
}, (table) => [
  index("pet_themes_user_idx").on(table.userId, table.state, table.createdAt),
  check("pet_themes_state_check", sql`${table.state} IN ('available', 'expired')`),
  check("pet_themes_category_check", sql`${table.category} IN (${oneOf(PET_THEME_CATEGORIES)})`),
]);
export type PetThemeRow = typeof petThemes.$inferSelect;
export type PetThemeRules = {
  dailyMinutes: number | null;
  hours: { from: number; to: number } | null;
  weather: PetWeatherKind[] | null;
  place: { label: string; latitude: number; longitude: number; radiusKm: number } | null;
};
/** Minutes spent at each place on `date`, the owner's local date, counted up to `accruedAt`. */
export type PetThemeUsage = { date: string; accruedAt: string; minutes: Record<string, number> };

export type PetMusing = { text: string; afterMinutes: number };
export type PetStatus = {
  values: StickerControlValues; caption: string; animateEverySeconds?: number; musings?: PetMusing[];
  /** How the pet felt (`describeCondition`) when `values` was chosen; a pose for another feeling is re-chosen when seen. */
  feels?: string;
};
export type PetEvolution = {
  id: string;
  state: "planning" | "building" | "publishing" | "ready" | "failed";
  /** What the pet decided to grow, as the brief the planner reads. */
  brief: string;
  trigger: string;
  stickerId: string;
  startedAt: string;
  finishedAt?: string;
  planJobId?: string;
  composeJobId?: string;
  /** The pet asked for its weather to be drawn again in its new look once it has grown. */
  redrawWeather?: boolean;
  error?: string;
};
export type PetStoredContext = {
  latitude?: number;
  longitude?: number;
  stepsToday?: number;
  /** The phone's local date the steps were counted on, so yesterday's walk is not today's. */
  stepsDate?: string;
  timeZone?: string;
  /**
   * Where the owner usually is, learned from where they keep being: the first place they are seen,
   * moved once they have been somewhere else for weeks. Far from it, they are on a trip.
   */
  home?: { latitude: number; longitude: number };
  /** When the owner was first seen far from home on this trip; cleared once they are back. */
  awaySince?: string;
  updatedAt: string;
};
export type PetWalkGold = { date: string; steps: number };
export type PetIllness = { name: string; since: string };
/** One thing in the bag: the item as it was bought, and when it expires — null when it never does. */
export type PetBagUnit = { id: string; item: PetAction; boughtAt: string; expiresAt: string | null };
/**
 * Stored stats and effects. `gold` came later: diary lines from before it have none, and a pet's
 * own stats never do — gold is the owner's, in `user_wallets`.
 */
export type PetStatsValues = { happiness: number; hp: number; energy: number; gold?: number };

/**
 * The pet's diary. Every change to its stats lands here with what caused it, so "why is my pet
 * sad?" has an answer. Kept per life: a new pet starts a fresh page, and the API reads only the
 * current life's lines.
 */
export const petEvents = pgTable("pet_events", {
  id: text("id").primaryKey(),
  userId: text("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  lifeId: text("life_id").notNull(),
  stickerId: text("sticker_id"),
  kind: text("kind", { enum: ["adopted", "send", "interaction", "random", "special", "share", "photo", "content", "sticker", "evolved", "encounter", "illness", "medicine", "room", "theme", "purchase", "friend"] }).notNull(),
  title: text("title").notNull(),
  detail: text("detail").notNull(),
  effectsJson: jsonb("effects_json").$type<PetStatsValues>().notNull(),
  statsBeforeJson: jsonb("stats_before_json").$type<PetStatsValues>().notNull(),
  statsAfterJson: jsonb("stats_after_json").$type<PetStatsValues>().notNull(),
  signalsJson: jsonb("signals_json").$type<PetSignalsV1>(),
  debugJson: jsonb("debug_json").$type<Record<string, unknown>>().notNull(),
  createdAt: timestampColumn("created_at").notNull(),
}, (table) => [
  index("pet_events_life_idx").on(table.userId, table.lifeId, table.createdAt),
]);
export type PetEventRow = typeof petEvents.$inferSelect;

/**
 * Something that happens to the pet and needs its owner to decide: one a day at most, written by
 * the pet's agent when its life workflow visits. The choices carry their outcomes, which stay on
 * the server until the owner picks one — a wrong pick costs the pet, a right one rewards it.
 */
export const petEncounters = pgTable("pet_encounters", {
  id: text("id").primaryKey(),
  userId: text("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  lifeId: text("life_id").notNull(),
  /** The owner's local date it happened on: the one encounter that day. */
  date: text("date").notNull(),
  title: text("title").notNull(),
  prompt: text("prompt").notNull(),
  choicesJson: jsonb("choices_json").$type<PetEncounterChoice[]>().notNull(),
  state: text("state", { enum: ["open", "resolved"] }).notNull(),
  choiceId: text("choice_id"),
  expiresAt: timestampColumn("expires_at").notNull(),
  resolvedAt: timestampColumn("resolved_at"),
  createdAt: timestampColumn("created_at").notNull(),
}, (table) => [
  uniqueIndex("pet_encounters_day_idx").on(table.userId, table.lifeId, table.date),
  check("pet_encounters_state_check", sql`${table.state} IN ('open', 'resolved')`),
]);
export type PetEncounterChoice = {
  id: string;
  title: string;
  description: string;
  /** Whether this was the right call. Hidden from the client until it is chosen. */
  correct: boolean;
  /** What the pet says happened, shown once chosen. */
  outcome: string;
  effects: { happiness: number; hp: number; energy: number; gold: number };
  medicine: number;
  sickens: boolean;
};
export type PetEncounterRow = typeof petEncounters.$inferSelect;

/**
 * A friend the pet made on its own: a new controllable sticker its agent dreamed up from the
 * weather, where its owner is, what it remembers and how it feels, then planned, built and
 * published in the owner's library without them. Only one is being made at a time, and the owner
 * is welcomed to each ready one once, when `seenAt` is still empty.
 */
export const PET_FRIEND_STATES = ["planning", "building", "publishing", "ready", "failed"] as const;
export type PetFriendState = (typeof PET_FRIEND_STATES)[number];

export const petFriends = pgTable("pet_friends", {
  id: text("id").primaryKey(),
  userId: text("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  lifeId: text("life_id").notNull(),
  /** The friend's sticker, written once the planning turn has a sticker to plan on. */
  stickerId: text("sticker_id").references(() => stickers.id, { onDelete: "cascade" }),
  name: text("name").notNull(),
  /** What the friend looks like and how it moves, as the planner reads it. */
  brief: text("brief").notNull(),
  /** How the two met, in the pet's words. */
  story: text("story").notNull(),
  /** What the pet says when it introduces its friend. */
  greeting: text("greeting").notNull(),
  state: text("state", { enum: PET_FRIEND_STATES }).notNull(),
  planJobId: text("plan_job_id"),
  composeJobId: text("compose_job_id"),
  error: text("error"),
  seenAt: timestampColumn("seen_at"),
  createdAt: timestampColumn("created_at").notNull(),
  finishedAt: timestampColumn("finished_at"),
}, (table) => [
  index("pet_friends_user_idx").on(table.userId, table.createdAt),
  uniqueIndex("pet_friends_active_idx").on(table.userId)
    .where(sql`${table.state} IN ('planning', 'building', 'publishing')`),
  check("pet_friends_state_check", sql`${table.state} IN (${oneOf(PET_FRIEND_STATES)})`),
]);
export type PetFriendRow = typeof petFriends.$inferSelect;

/**
 * The weather drawn in a pet's own art style, for the Pet tab and the widget to stand it in.
 *
 * Keyed by the revision the pet plays rather than by owner: everyone whose pet is the same sticker
 * sees the same rain, so each look is drawn once, and a pet that grows a new revision gets its
 * weather redrawn to match. A row is claimed (`drawing`) before the model is asked, so two reads of
 * the same pet in the same weather draw it once.
 */
export const PET_WEATHER_ART_LAYERS = ["sticker", "window"] as const;
export type PetWeatherArtLayer = (typeof PET_WEATHER_ART_LAYERS)[number];

export const petWeatherArt = pgTable("pet_weather_art", {
  id: text("id").primaryKey(),
  /** The sticker the weather belongs to. A new revision keeps it; only a restyle draws it again. */
  stickerId: text("sticker_id").notNull().references(() => stickers.id, { onDelete: "cascade" }),
  /** The revision whose art style it was drawn from. */
  revisionId: text("revision_id").notNull().references(() => stickerRevisions.id, { onDelete: "cascade" }),
  kind: text("kind", { enum: PET_WEATHER_KINDS }).notNull(),
  isDay: boolean("is_day").notNull(),
  /**
   * `sticker`: one weather element shown beside the pet. `window`: a 2×2 sheet of sky pieces — sun or
   * moon, two clouds and a falling particle — that the app animates behind a room's window glass.
   */
  layer: text("layer", { enum: PET_WEATHER_ART_LAYERS }).notNull().default("sticker"),
  state: text("state", { enum: ["drawing", "ready", "failed"] }).notNull(),
  r2Key: text("r2_key"),
  claimedAt: timestampColumn("claimed_at").notNull(),
  readyAt: timestampColumn("ready_at"),
}, (table) => [
  uniqueIndex("pet_weather_art_look_idx").on(table.stickerId, table.kind, table.isDay, table.layer),
  check("pet_weather_art_layer_check", sql`${table.layer} IN (${oneOf(PET_WEATHER_ART_LAYERS)})`),
  check("pet_weather_art_kind_check", sql`${table.kind} IN (${oneOf(PET_WEATHER_KINDS)})`),
  check("pet_weather_art_state_check", sql`${table.state} IN ('drawing', 'ready', 'failed')`),
]);
export type PetWeatherArtRow = typeof petWeatherArt.$inferSelect;

/**
 * What a pet remembers. Its memory agent reads every moment with its owner — a talk, a gift, an
 * action, a move — beside the memories nearest to it, and adds, rewrites or forgets notes here, so
 * the pet keeps a small, current picture of its owner and its life rather than a log. Kept per
 * life, like the diary: a new pet remembers nothing of the last one.
 */
/** The diary lines and talks a memory was drawn from, newest last, for "why does it think that?". */
export type PetMemorySource = { kind: string; title: string; at: string };

export const petMemories = pgTable("pet_memories", {
  id: text("id").primaryKey(),
  userId: text("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  lifeId: text("life_id").notNull(),
  content: text("content").notNull(),
  category: text("category", { enum: PET_MEMORY_CATEGORIES }).notNull(),
  /** 1 a passing detail, 5 something the pet should never forget; the least important go first. */
  importance: integer("importance").notNull(),
  embedding: vector("embedding", { dimensions: PET_MEMORY_DIMENSIONS }).notNull(),
  sourcesJson: jsonb("sources_json").$type<PetMemorySource[]>().notNull(),
  createdAt: timestampColumn("created_at").notNull(),
  updatedAt: timestampColumn("updated_at").notNull(),
}, (table) => [
  index("pet_memories_life_idx").on(table.userId, table.lifeId, table.updatedAt),
  index("pet_memories_embedding_idx").using("hnsw", table.embedding.op("vector_cosine_ops")),
  check("pet_memories_category_check", sql`${table.category} IN (${oneOf(PET_MEMORY_CATEGORIES)})`),
  check("pet_memories_importance_check", sql`${table.importance} BETWEEN 1 AND 5`),
]);
export type PetMemoryRow = typeof petMemories.$inferSelect;
export type UserPetRow = typeof userPets.$inferSelect;
