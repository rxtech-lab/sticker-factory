import { documentRenderableLayers } from "@/lib/contracts/sticker";
// The scaffolding every AI turn runs inside: the job row it advances, the assistant message
// it writes into, the tool-call records the client streams, and the guards that stop a turn
// from touching assets it does not own.

import { and, eq, inArray, max } from "drizzle-orm";
import { compactTranscript, type TranscriptOptions } from "@/lib/ai/compaction";
import { applyStickerOperationsV1, StickerDocumentSchema, layerImageAssetIds, layerVideoAssetIds, type StickerDocument } from "@/lib/contracts/sticker";
import { firstRow, getDatabase } from "@/lib/db/client";
import { assets, chatMessages, chatThreads, generationJobs } from "@/lib/db/schema";
import { getAiProvider } from "@/lib/ai/gateway";
import { describeError, traceEvent } from "@/lib/observability/trace";
import { appendGenerationEvent } from "@/lib/services/events";
import { serializeChatMessage } from "@/lib/services/stickers";
import { referencedAssetIds, renderSticker } from "@/lib/render/sticker-render";
import type { RenderAssets } from "@/lib/render/document-svg";
import { getObjectStore, inspectImage } from "@/lib/storage/r2";
import { derivedAssetId } from "@/lib/services/assets";

/**
 * How long a summarized name may be. Shorter than the 100 the create request allows: this one has to
 * fit a library tile and a notification title, where the create request only had to hold whatever
 * opening words the client sent.
 */
export const MAX_SUMMARIZED_TITLE_LENGTH = 48;

export async function insertAssistantMessage(
  job: typeof generationJobs.$inferSelect,
  content: string,
  kind: typeof chatMessages.$inferInsert.kind,
  revisionId?: string,
) {
  const db = await getDatabase();
  const existing = await db.select({ id: chatMessages.id }).from(chatMessages).where(and(
    eq(chatMessages.jobId, job.id),
    eq(chatMessages.role, "assistant"),
  )).then(firstRow);
  if (existing) return existing.id;
  const id = crypto.randomUUID();
  await db.transaction(async (tx) => {
    const currentJob = await tx.select({ state: generationJobs.state }).from(generationJobs)
      .where(eq(generationJobs.id, job.id)).then(firstRow);
    if (currentJob?.state !== "running") throw new Error("Generation was cancelled before the assistant response");
    const thread = await tx.select().from(chatThreads).where(eq(chatThreads.stickerId, job.stickerId)).then(firstRow);
    if (!thread) throw new Error("Chat thread not found");
    const sequenceRow = await tx.select({ value: max(chatMessages.sequence) }).from(chatMessages)
      .where(eq(chatMessages.threadId, thread.id)).then(firstRow);
    await tx.insert(chatMessages).values({
      id,
      threadId: thread.id,
      ownerId: job.ownerId,
      role: "assistant",
      kind,
      content,
      sequence: (sequenceRow?.value ?? 0) + 1,
      revisionId,
      jobId: job.id,
      status: "complete",
      createdAt: new Date(),
    });
  });
  return id;
}

export type AiTurnResult = {
  revisionId?: string;
  assistantMessageId: string;
  /**
   * The assistant turn, carried inline on the `candidate` and `completed` events so the client
   * can render it without a follow-up transcript fetch. `completeJobStep` persists this object
   * verbatim as the `completed` event payload, which is what gives the pure `reply` branch —
   * the one that emits no `candidate` at all — a live assistant message too.
   */
  assistantMessage?: ReturnType<typeof serializeChatMessage>;
};

export async function turnResult(assistantMessageId: string, revisionId?: string): Promise<AiTurnResult> {
  const row = await (await getDatabase()).select().from(chatMessages)
    .where(eq(chatMessages.id, assistantMessageId)).then(firstRow);
  // Assistant messages never carry attachments, so an empty list is exact, not a shortcut.
  return { revisionId, assistantMessageId, assistantMessage: row ? serializeChatMessage(row) : undefined };
}

export type StickerToolName =
  | "reply"
  | "generate-sticker"
  | "generate-image"
  | "edit-sticker"
  | "animate-sticker"
  | "plan-sticker"
  | "build-plan"
  | "create_plan"
  | "update_plan"
  | "show_plan"
  | "finalize_plan"
  | "create_animation"
  | "update_animation"
  | "edit_layer_animation"
  | "finalize_animation"
  | "edit_layers"
  | "edit_image_layer"
  | "add_image_layer"
  | "create_video"
  | "generate-video"
  | "finalize_edit"
  | "adjust_layout"
  | "finalize_layout"
  | "view_plan_image"
  | "view_sticker"
  | "show-sticker";

/**
 * Opens (or, on replay, re-announces) a tool-call row in the transcript.
 *
 * `label` is the display text and the replay identity. A composed turn generates several parts
 * through the same tool, so each needs a distinct label — otherwise they de-duplicate onto one
 * row and the user sees a single stuck spinner instead of per-part progress.
 */
export async function beginToolCall(
  job: typeof generationJobs.$inferSelect,
  toolName: StickerToolName,
  revisionId?: string,
  label: string = toolName,
): Promise<string> {
  const db = await getDatabase();
  const existing = await db.select().from(chatMessages).where(and(
    eq(chatMessages.jobId, job.id),
    eq(chatMessages.role, "system"),
    eq(chatMessages.kind, "status"),
    eq(chatMessages.content, label),
  )).then(firstRow);
  if (existing) {
    await appendGenerationEvent(db, job.id, job.ownerId, "progress", {
      toolCallId: existing.id,
      toolName: label,
      toolStatus: existing.status,
    });
    return existing.id;
  }

  const id = crypto.randomUUID();
  await db.transaction(async (tx) => {
    const currentJob = await tx.select({ state: generationJobs.state }).from(generationJobs)
      .where(eq(generationJobs.id, job.id)).then(firstRow);
    if (currentJob?.state !== "running") throw new Error("Generation was cancelled before the tool call");
    const thread = await tx.select().from(chatThreads).where(eq(chatThreads.stickerId, job.stickerId)).then(firstRow);
    if (!thread) throw new Error("Chat thread not found");
    const sequenceRow = await tx.select({ value: max(chatMessages.sequence) }).from(chatMessages)
      .where(eq(chatMessages.threadId, thread.id)).then(firstRow);
    await tx.insert(chatMessages).values({
      id,
      threadId: thread.id,
      ownerId: job.ownerId,
      role: "system",
      kind: "status",
      content: label,
      sequence: (sequenceRow?.value ?? 0) + 1,
      revisionId,
      jobId: job.id,
      status: "streaming",
      createdAt: new Date(),
    });
  });
  await appendGenerationEvent(db, job.id, job.ownerId, "progress", {
    toolCallId: id,
    toolName: label,
    toolStatus: "streaming",
  });
  return id;
}

/**
 * Numbers repeated calls to the same tool within one turn: `create_animation`, `create_animation #2`.
 *
 * `beginToolCall` de-duplicates on the label, so a bare name reused for a retry would find the row
 * it already marked failed, leave it failed, and show the user a permanently broken step that
 * actually succeeded.
 */
export function toolCallLabeller(): (toolName: StickerToolName) => string {
  const calls = new Map<StickerToolName, number>();
  return (toolName) => {
    const count = (calls.get(toolName) ?? 0) + 1;
    calls.set(toolName, count);
    return count === 1 ? toolName : `${toolName} #${count}`;
  };
}

function formatToolDetails(details: unknown): string | undefined {
  if (details === undefined) return undefined;
  if (details instanceof Error) return details.message.slice(0, 16000);
  const text = typeof details === "string" ? details : JSON.stringify(details, (_key, value) => {
    if (value instanceof Uint8Array) return `[Image/media: ${value.byteLength} bytes]`;
    if (value?.type === "Buffer" && Array.isArray(value.data)) return `[Image/media: ${value.data.length} bytes]`;
    return value;
  }, 2);
  if (text && text.length > 16000) {
    const truncated = text.slice(0, 16000) + "\n… (truncated)";
    // Keep the preview reference parseable even for large layout documents.
    if (details && typeof details === "object" && "previewAssetId" in details) {
      return JSON.stringify({ previewAssetId: details.previewAssetId, details: truncated });
    }
    return truncated;
  }
  return text;
}

export async function finishToolCall(
  job: typeof generationJobs.$inferSelect,
  toolCallId: string | undefined,
  status: "complete" | "failed" = "complete",
  details?: unknown,
): Promise<void> {
  if (!toolCallId) return;
  const db = await getDatabase();
  const changed = await db.update(chatMessages).set({ status }).where(and(
    eq(chatMessages.id, toolCallId),
    eq(chatMessages.jobId, job.id),
    eq(chatMessages.role, "system"),
    eq(chatMessages.status, "streaming"),
  )).returning({ id: chatMessages.id, toolName: chatMessages.content });
  const tool = changed[0];
  if (!tool) return;
  // Keep the exact review pixels out of JSON/model history, but retain an owned asset
  // so both a live event and a reopened transcript can display this call's snapshot.
  if (status === "complete" && details && typeof details === "object"
      && ("bytes" in details || "document" in details)) {
    try {
      const rendered = "bytes" in details && details.bytes instanceof Uint8Array
        ? { bytes: details.bytes }
        : "document" in details
          ? await renderWorkingDocument(StickerDocumentSchema.parse(details.document), job.ownerId)
          : undefined;
      if (!rendered) throw new Error("Tool result has no renderable image");
      const bytes = rendered.bytes;
      const inspection = await inspectImage(bytes);
      const previewAssetId = derivedAssetId(tool.id, "tool-preview");
      const r2Key = `${job.ownerId}/${job.stickerId}/tool-previews/${previewAssetId}`;
      await getObjectStore().put(r2Key, { bytes, contentType: inspection.mimeType });
      await db.insert(assets).values({
        id: previewAssetId, ownerId: job.ownerId, stickerId: job.stickerId,
        kind: "preview", state: "ready", r2Key, mimeType: inspection.mimeType,
        byteSize: inspection.byteSize, width: inspection.width, height: inspection.height,
        sha256: inspection.sha256, frameCount: inspection.frameCount, hasAlpha: inspection.hasAlpha,
        readyAt: new Date(),
      }).onConflictDoNothing();
      details = { ...details, previewAssetId };
    } catch (error) {
      // Saving a transcript preview must not turn a successful tool call into a failure.
      traceEvent("tool-preview:fail", { toolCallId, error: describeError(error) });
    }
  }
  await appendGenerationEvent(db, job.id, job.ownerId, "progress", {
    toolCallId: tool.id,
    toolName: tool.toolName,
    toolStatus: status,
    toolDetails: formatToolDetails(details),
  });
}

export async function showStickerThroughTool(
  job: typeof generationJobs.$inferSelect,
  revisionId: string,
  kind: "static" | "animated",
  instruction: string,
  history: string,
): Promise<string> {
  const toolCallId = await beginToolCall(job, "show-sticker", revisionId);
  try {
    const content = await getAiProvider().showSticker(revisionId, kind, instruction, history);
    await finishToolCall(job, toolCallId, "complete", content);
    return content;
  } catch (error) {
    await finishToolCall(job, toolCallId, "failed", error);
    throw error;
  }
}

/**
 * What the transcript records when quick mode skips the caption call.
 *
 * Written as the assistant would write it, because that is who it is attributed to when the project
 * is opened in the main app later: a plain sentence about what just happened, and nothing that
 * pretends to have looked at the result.
 */
export function quickCaption(kind: "image" | "edit" | "animation"): string {
  return kind === "edit" ? "Here's the updated sticker." : "Here's your sticker.";
}

export async function assertJobStillRunning(jobId: string): Promise<void> {
  const current = await (await getDatabase()).select({ state: generationJobs.state }).from(generationJobs)
    .where(eq(generationJobs.id, jobId)).then(firstRow);
  if (current?.state !== "running") throw new Error("Generation was cancelled");
}

/**
 * The transcript the prompts are given, compacted to a character budget.
 *
 * Thin wrapper over `compactTranscript` so the compaction rules live in one place with the tool-loop
 * ones and can be unit-tested without a database.
 */
export function boundedTranscript(
  messages: Array<typeof chatMessages.$inferSelect>,
  maxCharacters = 24_000,
  options: TranscriptOptions = {},
): string {
  return compactTranscript(messages, maxCharacters, options);
}

/**
 * Renders the working document to a PNG for the agent's `view_sticker` tool.
 *
 * Lives here rather than in the AI layer for the same reason every other side effect does: this is
 * where database and object-store access belong. The renderer itself is pure — it takes a document
 * and a bag of already-fetched bytes — so all this adds is the fetching.
 *
 * Missing artwork is deliberately not an error. A layer whose asset has gone draws as a labelled
 * placeholder, which tells the agent more than a failed tool call would: it can see the layer is
 * there, and see that its artwork is not.
 */
export async function renderWorkingDocument(document: StickerDocument, ownerId: string) {
  const db = await getDatabase();
  const objectStore = getObjectStore();
  const ids = referencedAssetIds(document);
  const loaded: RenderAssets = new Map();
  if (ids.length > 0) {
    const rows = await db.select().from(assets)
      .where(and(eq(assets.ownerId, ownerId), inArray(assets.id, ids)));
    // Three different ways a referenced asset fails to arrive, and the render swallows all of them
    // into the same purple placeholder. Separated here so a report of "my artwork is missing" can
    // be answered without guessing: no row (wrong owner, or deleted), a row that never went ready,
    // or a row whose object is gone from the store.
    const byId = new Map(rows.map((asset) => [asset.id, asset]));
    const unresolved = ids.filter((id) => !byId.has(id));
    const notReady = rows.filter((asset) => asset.state !== "ready").map((asset) => asset.id);
    if (unresolved.length > 0 || notReady.length > 0) {
      traceEvent("render:assets:incomplete", { ownerId, referenced: ids.length, unresolved, notReady });
    }
    await Promise.all(rows
      .filter((asset) => asset.state === "ready")
      .map(async (asset) => {
        try {
          const object = await objectStore.get(asset.r2Key);
          loaded.set(asset.id, { bytes: object.bytes, mimeType: asset.mimeType });
        } catch (error) {
          // Left out of the map on purpose; the renderer draws a placeholder for it.
          traceEvent("render:assets:unreadable", {
            assetId: asset.id,
            r2Key: asset.r2Key,
            error: describeError(error),
          });
        }
      }));
  }
  return renderSticker(document, loaded);
}

export async function assertDocumentAssetsOwned(document: StickerDocument, ownerId: string, stickerId: string): Promise<void> {
  const db = await getDatabase();
  const ids = documentRenderableLayers(document).flatMap((layer) => [
    ...layerImageAssetIds(layer),
    // The clip itself: `layerImageAssetIds` deliberately reports a video layer's poster instead,
    // because that is what the server draws, but the MP4 is the asset the client plays.
    ...layerVideoAssetIds(layer),
    // The poster is derived from the atlas and belongs to the same sticker, so an unowned one is
    // the same ownership hole as an unowned atlas — and it is the asset older clients are served.
    ...(layer.type === "sequence" && layer.posterAssetId ? [layer.posterAssetId] : []),
    ...(layer.type === "sprite" ? [layer.posterAssetId] : []),
  ]);
  if (ids.length === 0) return;
  const rows = await db.select().from(assets).where(and(eq(assets.ownerId, ownerId), eq(assets.stickerId, stickerId)));
  const byId = new Map(rows.filter((asset) => asset.state === "ready").map((asset) => [asset.id, asset]));
  if (ids.some((id) => !byId.has(id))) throw new Error("Sticker document contains an unowned or unavailable asset");
}

/**
 * Recognises a call that ran out of time or was cancelled, including when the AI SDK has wrapped the
 * original `TimeoutError`/`AbortError` in its own error, so the caller can treat it as final rather
 * than as something worth attempting again.
 */
export function isAbortError(error: unknown): boolean {
  let current: unknown = error;
  for (let depth = 0; current && depth < 5; depth += 1) {
    const name = (current as { name?: string }).name;
    if (name === "TimeoutError" || name === "AbortError") return true;
    current = (current as { cause?: unknown }).cause;
  }
  return false;
}

/**
 * Generates one 1024x1024 transparent PNG and stores it as a ready `master` asset.
 *
 * Shared by the single-image path and by each part of a composed sticker. The cancellation
 * checks around the R2 write and the rollback on a failed insert are load-bearing: without them
 * a cancelled or failing turn leaves an orphaned object behind.
 */
export function assertTargetedAnimationOperation(
  operation: Parameters<typeof applyStickerOperationsV1>[1][number],
  targetLayerId: string,
): void {
  if (operation.op === "setTiming") return;
  // `setLayerAnimations` belongs here for the same reason the keyframe setters do: it names a single
  // layer and touches nothing else. It is also the operation the planner is told to prefer, so
  // leaving it out rejected every targeted animation on the planner's first move.
  if (operation.op === "setLayerAnimations"
    || operation.op === "setPositionKeyframes"
    || operation.op === "setScaleKeyframes"
    || operation.op === "setRotationKeyframes"
    || operation.op === "setOpacityKeyframes"
    || operation.op === "setEffectKeyframes"
    || operation.op === "renameLayer") {
    if (operation.layerId === targetLayerId) return;
  }
  throw new Error("Animation planner attempted to modify outside the selected target layer");
}
