import { sql } from "drizzle-orm";
import {
  index,
  integer,
  primaryKey,
  real,
  sqliteTable,
  text,
  uniqueIndex,
  type AnySQLiteColumn,
} from "drizzle-orm/sqlite-core";
import type { PlanV1 } from "@/lib/contracts/plan";
import type { StickerDocument } from "@/lib/contracts/sticker";

const timestamp = (name: string) => integer(name, { mode: "timestamp_ms" });

export const users = sqliteTable("users", {
  id: text("id").primaryKey(),
  email: text("email"),
  displayName: text("display_name"),
  createdAt: timestamp("created_at").notNull().$defaultFn(() => new Date()),
  updatedAt: timestamp("updated_at").notNull().$defaultFn(() => new Date()),
});

export const stickers = sqliteTable("stickers", {
  id: text("id").primaryKey(),
  ownerId: text("owner_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  title: text("title").notNull(),
  kind: text("kind", { enum: ["static", "animated"] }).notNull(),
  status: text("status", { enum: ["draft", "published", "deleting"] }).notNull().default("draft"),
  activeRevisionId: text("active_revision_id"),
  createdAt: timestamp("created_at").notNull().$defaultFn(() => new Date()),
  updatedAt: timestamp("updated_at").notNull().$defaultFn(() => new Date()),
  deletedAt: timestamp("deleted_at"),
}, (table) => [
  index("stickers_owner_updated_idx").on(table.ownerId, table.updatedAt),
  index("stickers_owner_status_idx").on(table.ownerId, table.status),
]);

export const chatThreads = sqliteTable("chat_threads", {
  id: text("id").primaryKey(),
  stickerId: text("sticker_id").notNull().references(() => stickers.id, { onDelete: "cascade" }),
  ownerId: text("owner_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  createdAt: timestamp("created_at").notNull().$defaultFn(() => new Date()),
  updatedAt: timestamp("updated_at").notNull().$defaultFn(() => new Date()),
}, (table) => [
  uniqueIndex("chat_threads_sticker_unique").on(table.stickerId),
  index("chat_threads_owner_idx").on(table.ownerId),
]);

export const generationJobs = sqliteTable("generation_jobs", {
  id: text("id").primaryKey(),
  ownerId: text("owner_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  stickerId: text("sticker_id").notNull().references(() => stickers.id, { onDelete: "cascade" }),
  sourceMessageId: text("source_message_id"),
  kind: text("kind", { enum: ["image", "edit", "animation", "chat", "plan", "compose", "export", "cleanup"] }).notNull(),
  priorStickerStatus: text("prior_sticker_status", { enum: ["draft", "published"] }),
  state: text("state", { enum: ["queued", "running", "waiting", "succeeded", "failed", "cancelled"] }).notNull().default("queued"),
  workflowRunId: text("workflow_run_id"),
  attempts: integer("attempts").notNull().default(0),
  errorCode: text("error_code"),
  errorMessage: text("error_message"),
  createdAt: timestamp("created_at").notNull().$defaultFn(() => new Date()),
  updatedAt: timestamp("updated_at").notNull().$defaultFn(() => new Date()),
  completedAt: timestamp("completed_at"),
}, (table) => [
  index("generation_jobs_owner_created_idx").on(table.ownerId, table.createdAt),
  index("generation_jobs_sticker_state_idx").on(table.stickerId, table.state),
  uniqueIndex("generation_jobs_one_active_per_sticker")
    .on(table.stickerId)
    .where(sql`${table.state} IN ('queued', 'running', 'waiting')`),
]);

export const chatMessages = sqliteTable("chat_messages", {
  id: text("id").primaryKey(),
  threadId: text("thread_id").notNull().references(() => chatThreads.id, { onDelete: "cascade" }),
  ownerId: text("owner_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  role: text("role", { enum: ["user", "assistant", "system"] }).notNull(),
  /** `device_edit` is the on-device editor saving a revision; the transcript draws it as a marker. */
  kind: text("kind", {
    enum: ["text", "image", "image_edit", "animation", "device_edit", "plan", "export", "status"],
  }).notNull(),
  content: text("content").notNull(),
  targetLayerId: text("target_layer_id"),
  baseRevisionId: text("base_revision_id"),
  imagePlacement: text("image_placement", { enum: ["replace", "add"] }).notNull().default("replace"),
  sequence: integer("sequence").notNull(),
  revisionId: text("revision_id"),
  jobId: text("job_id").references(() => generationJobs.id, { onDelete: "set null" }),
  status: text("status", { enum: ["complete", "streaming", "failed"] }).notNull().default("complete"),
  /** For a `kind: "plan"` card: which plan it renders, and which revision it was showing. */
  planId: text("plan_id").references((): AnySQLiteColumn => plans.id, { onDelete: "set null" }),
  planRevision: integer("plan_revision"),
  createdAt: timestamp("created_at").notNull().$defaultFn(() => new Date()),
}, (table) => [
  uniqueIndex("chat_messages_thread_sequence_unique").on(table.threadId, table.sequence),
  index("chat_messages_thread_created_idx").on(table.threadId, table.createdAt),
]);

export const assets = sqliteTable("assets", {
  id: text("id").primaryKey(),
  ownerId: text("owner_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  stickerId: text("sticker_id").references(() => stickers.id, { onDelete: "cascade" }),
  /**
   * `sequence` is a frame atlas: one transparent PNG holding a grid of frames lifted from a Live
   * Photo. Unlike every other kind, its `frame_count`/`fps`/`duration_seconds` are declared by the
   * client at upload time rather than read out of the file — the file itself is a single still.
   */
  kind: text("kind", {
    enum: ["reference", "mask", "master", "preview", "gif", "mp4", "system", "chat_attachment", "sequence"],
  }).notNull(),
  state: text("state", { enum: ["pending", "ready", "failed", "deleted"] }).notNull().default("pending"),
  r2Key: text("r2_key").notNull().unique(),
  mimeType: text("mime_type").notNull(),
  byteSize: integer("byte_size"),
  width: integer("width"),
  height: integer("height"),
  frameCount: integer("frame_count"),
  durationSeconds: real("duration_seconds"),
  fps: real("fps"),
  sha256: text("sha256"),
  hasAlpha: integer("has_alpha", { mode: "boolean" }),
  originalFilename: text("original_filename"),
  createdAt: timestamp("created_at").notNull().$defaultFn(() => new Date()),
  readyAt: timestamp("ready_at"),
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
]);

export const stickerRevisions = sqliteTable("sticker_revisions", {
  id: text("id").primaryKey(),
  stickerId: text("sticker_id").notNull().references(() => stickers.id, { onDelete: "cascade" }),
  parentRevisionId: text("parent_revision_id"),
  sourceMessageId: text("source_message_id").references(() => chatMessages.id, { onDelete: "set null" }),
  kind: text("kind", { enum: ["static", "animated"] }).notNull(),
  candidateState: text("candidate_state", { enum: ["candidate", "accepted", "rejected", "superseded"] }).notNull().default("candidate"),
  documentJson: text("document_json", { mode: "json" }).$type<StickerDocument>().notNull(),
  masterAssetId: text("master_asset_id").references(() => assets.id, { onDelete: "set null" }),
  previewAssetId: text("preview_asset_id").references(() => assets.id, { onDelete: "set null" }),
  pngAssetId: text("png_asset_id").references(() => assets.id, { onDelete: "set null" }),
  gifAssetId: text("gif_asset_id").references(() => assets.id, { onDelete: "set null" }),
  mp4AssetId: text("mp4_asset_id").references(() => assets.id, { onDelete: "set null" }),
  systemAssetId: text("system_asset_id").references(() => assets.id, { onDelete: "set null" }),
  createdAt: timestamp("created_at").notNull().$defaultFn(() => new Date()),
  decidedAt: timestamp("decided_at"),
}, (table) => [
  index("sticker_revisions_sticker_created_idx").on(table.stickerId, table.createdAt),
  index("sticker_revisions_parent_idx").on(table.parentRevisionId),
]);

export const chatAttachments = sqliteTable("chat_attachments", {
  messageId: text("message_id").notNull().references(() => chatMessages.id, { onDelete: "cascade" }),
  assetId: text("asset_id").notNull().references(() => assets.id, { onDelete: "cascade" }),
  kind: text("kind", { enum: ["reference", "mask"] }).notNull(),
  targetLayerId: text("target_layer_id"),
  position: integer("position").notNull().default(0),
}, (table) => [
  primaryKey({ columns: [table.messageId, table.assetId] }),
  index("chat_attachments_asset_idx").on(table.assetId),
]);

export const generationEvents = sqliteTable("generation_events", {
  id: integer("id").primaryKey({ autoIncrement: true }),
  jobId: text("job_id").notNull().references(() => generationJobs.id, { onDelete: "cascade" }),
  ownerId: text("owner_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  type: text("type", { enum: ["queued", "started", "progress", "document", "candidate", "waiting", "completed", "failed"] }).notNull(),
  dataJson: text("data_json", { mode: "json" }).$type<Record<string, unknown>>().notNull(),
  createdAt: timestamp("created_at").notNull().$defaultFn(() => new Date()),
}, (table) => [
  index("generation_events_job_id_idx").on(table.jobId, table.id),
  index("generation_events_owner_id_idx").on(table.ownerId, table.id),
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
export const plans = sqliteTable("plans", {
  id: text("id").primaryKey(),
  ownerId: text("owner_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  stickerId: text("sticker_id").notNull().references(() => stickers.id, { onDelete: "cascade" }),
  threadId: text("thread_id").notNull().references(() => chatThreads.id, { onDelete: "cascade" }),
  /** The message the plan was first shown in. Not unique: one plan can be shown many times. */
  messageId: text("message_id").notNull().references(() => chatMessages.id, { onDelete: "cascade" }),
  planJson: text("plan_json", { mode: "json" }).$type<PlanV1>().notNull(),
  state: text("state", {
    enum: ["draft", "finalized", "confirmed", "superseded", "cancelled"],
  }).notNull().default("draft"),
  /** Bumped by every `update_plan`, so a card can say which revision it rendered. */
  revision: integer("revision").notNull().default(1),
  supersedesId: text("supersedes_id").references((): AnySQLiteColumn => plans.id, { onDelete: "set null" }),
  jobId: text("job_id").references(() => generationJobs.id, { onDelete: "set null" }),
  /** A storyboard render of the plan, shown on the plan card before anything real is made. */
  conceptAssetId: text("concept_asset_id").references(() => assets.id, { onDelete: "set null" }),
  /** Why the user rejected the plan. Fed back into the next planning turn. */
  decisionReason: text("decision_reason"),
  createdAt: timestamp("created_at").notNull().$defaultFn(() => new Date()),
  updatedAt: timestamp("updated_at").notNull().$defaultFn(() => new Date()),
  decidedAt: timestamp("decided_at"),
}, (table) => [
  index("plans_sticker_state_idx").on(table.stickerId, table.state),
  index("plans_owner_created_idx").on(table.ownerId, table.createdAt),
]);

/**
 * The creator's public identity in the marketplace.
 *
 * Kept out of `users` because OAuth owns account profile data while marketplace identity is
 * user-authored application state. `handle` is the only creator identifier that appears in URLs
 * and response bodies — the OAuth `sub` never leaves the server.
 */
export const creatorProfiles = sqliteTable("creator_profiles", {
  userId: text("user_id").primaryKey().references(() => users.id, { onDelete: "cascade" }),
  handle: text("handle").notNull(),
  displayName: text("display_name"),
  bio: text("bio"),
  avatarAssetId: text("avatar_asset_id").references(() => assets.id, { onDelete: "set null" }),
  /** Monetization placeholders. Nothing reads or writes these yet. */
  payoutStatus: text("payout_status", { enum: ["none", "pending", "active"] }).notNull().default("none"),
  payoutProvider: text("payout_provider"),
  payoutAccountRef: text("payout_account_ref"),
  createdAt: timestamp("created_at").notNull().$defaultFn(() => new Date()),
  updatedAt: timestamp("updated_at").notNull().$defaultFn(() => new Date()),
}, (table) => [
  uniqueIndex("creator_profiles_handle_unique").on(table.handle),
]);

/**
 * A published bundle of the creator's own stickers.
 *
 * `installCount` is current installs (what the UI shows); `installTotal` is lifetime and never
 * decremented. Both are trigger-maintained rather than counted per row, because browse sorts by
 * popularity and shows a count on every card.
 */
export const stickerPacks = sqliteTable("sticker_packs", {
  id: text("id").primaryKey(),
  creatorId: text("creator_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  /** Immutable once published, so a shared link never rots when the title changes. */
  slug: text("slug").notNull(),
  title: text("title").notNull(),
  summary: text("summary"),
  state: text("state", { enum: ["draft", "published", "unlisted", "removed"] }).notNull().default("draft"),
  coverStickerId: text("cover_sticker_id").references(() => stickers.id, { onDelete: "set null" }),
  itemCount: integer("item_count").notNull().default(0),
  installCount: integer("install_count").notNull().default(0),
  installTotal: integer("install_total").notNull().default(0),
  /** Monetization placeholders. Every pack is free today; nothing charges. */
  monetization: text("monetization", { enum: ["free", "paid", "subscription"] }).notNull().default("free"),
  priceCents: integer("price_cents").notNull().default(0),
  currency: text("currency").notNull().default("USD"),
  revenueShareBps: integer("revenue_share_bps").notNull().default(0),
  publishedAt: timestamp("published_at"),
  createdAt: timestamp("created_at").notNull().$defaultFn(() => new Date()),
  updatedAt: timestamp("updated_at").notNull().$defaultFn(() => new Date()),
}, (table) => [
  uniqueIndex("sticker_packs_slug_unique").on(table.slug),
  index("sticker_packs_creator_updated_idx").on(table.creatorId, table.updatedAt),
  index("sticker_packs_state_published_idx").on(table.state, table.publishedAt),
  index("sticker_packs_state_installs_idx").on(table.state, table.installCount),
]);

export const stickerPackItems = sqliteTable("sticker_pack_items", {
  packId: text("pack_id").notNull().references(() => stickerPacks.id, { onDelete: "cascade" }),
  stickerId: text("sticker_id").notNull().references(() => stickers.id, { onDelete: "cascade" }),
  position: integer("position").notNull().default(0),
  addedAt: timestamp("added_at").notNull().$defaultFn(() => new Date()),
}, (table) => [
  primaryKey({ columns: [table.packId, table.stickerId] }),
  index("sticker_pack_items_pack_position_idx").on(table.packId, table.position),
  index("sticker_pack_items_sticker_idx").on(table.stickerId),
]);

/**
 * Uninstall flips `state`; it never deletes the row. That keeps uninstall/reinstall idempotent and
 * preserves the (future) entitlement, so a user who paid and later removed a pack never pays twice.
 */
export const packInstalls = sqliteTable("pack_installs", {
  packId: text("pack_id").notNull().references(() => stickerPacks.id, { onDelete: "cascade" }),
  userId: text("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  state: text("state", { enum: ["installed", "uninstalled"] }).notNull().default("installed"),
  position: integer("position").notNull().default(0),
  /** Entitlement placeholders. Every acquisition is `free` today. */
  acquisition: text("acquisition", { enum: ["free", "purchase", "gift", "promo"] }).notNull().default("free"),
  priceCentsPaid: integer("price_cents_paid").notNull().default(0),
  orderRef: text("order_ref"),
  installedAt: timestamp("installed_at").notNull().$defaultFn(() => new Date()),
  uninstalledAt: timestamp("uninstalled_at"),
}, (table) => [
  primaryKey({ columns: [table.packId, table.userId] }),
  index("pack_installs_user_state_idx").on(table.userId, table.state, table.position),
  index("pack_installs_pack_state_idx").on(table.packId, table.state),
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
export const deviceTokens = sqliteTable("device_tokens", {
  token: text("token").primaryKey(),
  userId: text("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  platform: text("platform", { enum: ["ios"] }).notNull().default("ios"),
  /** A sandbox token is rejected by the production APNs host and vice versa. */
  environment: text("environment", { enum: ["sandbox", "production"] }).notNull().default("production"),
  bundleId: text("bundle_id"),
  appVersion: text("app_version"),
  createdAt: timestamp("created_at").notNull().$defaultFn(() => new Date()),
  updatedAt: timestamp("updated_at").notNull().$defaultFn(() => new Date()),
  lastSeenAt: timestamp("last_seen_at").notNull().$defaultFn(() => new Date()),
  /** Set when APNs says the token is gone. Registering the same token again clears it. */
  disabledAt: timestamp("disabled_at"),
  disabledReason: text("disabled_reason"),
}, (table) => [
  index("device_tokens_user_active_idx").on(table.userId, table.disabledAt),
]);

export const idempotencyKeys = sqliteTable("idempotency_keys", {
  ownerId: text("owner_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  operation: text("operation").notNull(),
  key: text("key").notNull(),
  requestHash: text("request_hash").notNull(),
  responseStatus: integer("response_status"),
  responseJson: text("response_json", { mode: "json" }).$type<unknown>(),
  createdAt: timestamp("created_at").notNull().$defaultFn(() => new Date()),
  expiresAt: timestamp("expires_at").notNull(),
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
