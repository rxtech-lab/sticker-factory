import { and, asc, desc, eq, max } from "drizzle-orm";
import { FatalError } from "workflow";
import {
  compilePlanAnimations,
  planLayerAnchor,
  PlanV1Schema,
  type PlanV1,
} from "@/lib/contracts/plan";
import {
  applyStickerOperationsV1,
  CURRENT_DOCUMENT_VERSION,
  StickerDocumentSchema,
  type StickerDocument,
  type StickerLayerV1,
  type StickerOperationV1,
} from "@/lib/contracts/sticker";
import { getDatabase } from "@/lib/db/client";
import {
  assets,
  chatAttachments,
  chatMessages,
  chatThreads,
  generationEvents,
  generationJobs,
  plans,
  stickerRevisions,
  stickers,
} from "@/lib/db/schema";
import {
  AnimationTurnAbort,
  getAiProvider,
  validatePlannedAnimationOperation,
  type AnimationDraftingSession,
  type PlanDraftingSession,
} from "@/lib/ai/gateway";
import { derivedAssetId } from "@/lib/services/assets";
import { appendGenerationEvent } from "@/lib/services/events";
import {
  attachPlanConcept,
  createPlan,
  finalizePlan,
  recentlyRejectedPlans,
  updatePlan,
} from "@/lib/services/plans";
import {
  acceptRevision,
  assertValidAnimationBase,
  bindExports,
  createCandidateRevision,
  isValidAnimationBase,
  rejectRevision,
  revertRevision,
  serializeChatMessage,
} from "@/lib/services/stickers";
import { getObjectStore, inspectImage, objectKey } from "@/lib/storage/r2";
import type { PublishExportsRequest } from "@/lib/contracts/api";

export async function beginJobStep(jobId: string): Promise<void> {
  "use step";
  const db = getDatabase();
  const job = await db.select().from(generationJobs).where(eq(generationJobs.id, jobId)).get();
  if (!job) throw new Error("Generation job not found");
  if (job.state === "running") return;
  if (job.state !== "queued") throw new Error(`Job cannot start from state ${job.state}`);
  await db.transaction(async (tx) => {
    const now = new Date();
    const changed = await tx.update(generationJobs).set({ state: "running", attempts: job.attempts + 1, updatedAt: now })
      .where(and(eq(generationJobs.id, jobId), eq(generationJobs.state, "queued"))).returning({ id: generationJobs.id });
    if (changed.length === 0) throw new Error("Job was cancelled before it started");
    await tx.insert(generationEvents).values({
      jobId,
      ownerId: job.ownerId,
      type: "started",
      dataJson: { attempt: job.attempts + 1 },
      createdAt: now,
    });
  });
}

async function insertAssistantMessage(
  job: typeof generationJobs.$inferSelect,
  content: string,
  kind: typeof chatMessages.$inferInsert.kind,
  revisionId?: string,
) {
  const db = getDatabase();
  const existing = await db.select({ id: chatMessages.id }).from(chatMessages).where(and(
    eq(chatMessages.jobId, job.id),
    eq(chatMessages.role, "assistant"),
  )).get();
  if (existing) return existing.id;
  const id = crypto.randomUUID();
  await db.transaction(async (tx) => {
    const currentJob = await tx.select({ state: generationJobs.state }).from(generationJobs)
      .where(eq(generationJobs.id, job.id)).get();
    if (currentJob?.state !== "running") throw new Error("Generation was cancelled before the assistant response");
    const thread = await tx.select().from(chatThreads).where(eq(chatThreads.stickerId, job.stickerId)).get();
    if (!thread) throw new Error("Chat thread not found");
    const sequenceRow = await tx.select({ value: max(chatMessages.sequence) }).from(chatMessages)
      .where(eq(chatMessages.threadId, thread.id)).get();
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

async function turnResult(assistantMessageId: string, revisionId?: string): Promise<AiTurnResult> {
  const row = await getDatabase().select().from(chatMessages)
    .where(eq(chatMessages.id, assistantMessageId)).get();
  // Assistant messages never carry attachments, so an empty list is exact, not a shortcut.
  return { revisionId, assistantMessageId, assistantMessage: row ? serializeChatMessage(row) : undefined };
}

type StickerToolName =
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
  | "finalize_animation"
  | "show-sticker";

/**
 * Opens (or, on replay, re-announces) a tool-call row in the transcript.
 *
 * `label` is the display text and the replay identity. A composed turn generates several parts
 * through the same tool, so each needs a distinct label — otherwise they de-duplicate onto one
 * row and the user sees a single stuck spinner instead of per-part progress.
 */
async function beginToolCall(
  job: typeof generationJobs.$inferSelect,
  toolName: StickerToolName,
  revisionId?: string,
  label: string = toolName,
): Promise<string> {
  const db = getDatabase();
  const existing = await db.select().from(chatMessages).where(and(
    eq(chatMessages.jobId, job.id),
    eq(chatMessages.role, "system"),
    eq(chatMessages.kind, "status"),
    eq(chatMessages.content, label),
  )).get();
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
      .where(eq(generationJobs.id, job.id)).get();
    if (currentJob?.state !== "running") throw new Error("Generation was cancelled before the tool call");
    const thread = await tx.select().from(chatThreads).where(eq(chatThreads.stickerId, job.stickerId)).get();
    if (!thread) throw new Error("Chat thread not found");
    const sequenceRow = await tx.select({ value: max(chatMessages.sequence) }).from(chatMessages)
      .where(eq(chatMessages.threadId, thread.id)).get();
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

async function finishToolCall(
  job: typeof generationJobs.$inferSelect,
  toolCallId: string | undefined,
  status: "complete" | "failed" = "complete",
): Promise<void> {
  if (!toolCallId) return;
  const db = getDatabase();
  const changed = await db.update(chatMessages).set({ status }).where(and(
    eq(chatMessages.id, toolCallId),
    eq(chatMessages.jobId, job.id),
    eq(chatMessages.role, "system"),
    eq(chatMessages.status, "streaming"),
  )).returning({ id: chatMessages.id, toolName: chatMessages.content });
  const tool = changed[0];
  if (!tool) return;
  await appendGenerationEvent(db, job.id, job.ownerId, "progress", {
    toolCallId: tool.id,
    toolName: tool.toolName,
    toolStatus: status,
  });
}

async function showStickerThroughTool(
  job: typeof generationJobs.$inferSelect,
  revisionId: string,
  kind: "static" | "animated",
  instruction: string,
  history: string,
): Promise<string> {
  const toolCallId = await beginToolCall(job, "show-sticker", revisionId);
  try {
    const content = await getAiProvider().showSticker(revisionId, kind, instruction, history);
    await finishToolCall(job, toolCallId);
    return content;
  } catch (error) {
    await finishToolCall(job, toolCallId, "failed");
    throw error;
  }
}

async function assertJobStillRunning(jobId: string): Promise<void> {
  const current = await getDatabase().select({ state: generationJobs.state }).from(generationJobs)
    .where(eq(generationJobs.id, jobId)).get();
  if (current?.state !== "running") throw new Error("Generation was cancelled");
}

function boundedTranscript(messages: Array<typeof chatMessages.$inferSelect>, maxCharacters = 24_000): string {
  const selected: string[] = [];
  let length = 0;
  for (const message of [...messages].reverse()) {
    const line = `${message.role}: ${message.content}`;
    if (selected.length > 0 && length + line.length > maxCharacters) break;
    selected.push(line.slice(0, maxCharacters));
    length += line.length;
  }
  return selected.reverse().join("\n");
}

async function assertDocumentAssetsOwned(document: StickerDocument, ownerId: string, stickerId: string): Promise<void> {
  const db = getDatabase();
  const ids = document.layers.flatMap((layer) => layer.type === "image"
    ? [layer.assetId, ...(layer.maskAssetId ? [layer.maskAssetId] : [])]
    : []);
  if (ids.length === 0) return;
  const rows = await db.select().from(assets).where(and(eq(assets.ownerId, ownerId), eq(assets.stickerId, stickerId)));
  const byId = new Map(rows.filter((asset) => asset.state === "ready").map((asset) => [asset.id, asset]));
  if (ids.some((id) => !byId.has(id))) throw new Error("Sticker document contains an unowned or unavailable asset");
}

/**
 * Generates one 1024x1024 transparent PNG and stores it as a ready `master` asset.
 *
 * Shared by the single-image path and by each part of a composed sticker. The cancellation
 * checks around the R2 write and the rollback on a failed insert are load-bearing: without them
 * a cancelled or failing turn leaves an orphaned object behind.
 */
async function generateAndStoreAsset(
  job: typeof generationJobs.$inferSelect,
  stickerId: string,
  params: {
    assetId: string;
    prompt: string;
    references: Array<{ bytes: Uint8Array; mimeType: string }>;
    mask?: { bytes: Uint8Array; mimeType: string };
    conversationContext?: string;
    mode: "generate" | "conversation_edit";
    /**
     * A storyboard of a plan rather than a sticker. Concept boards are deliberately opaque, so they
     * skip the transparency gate and land as a `preview` asset instead of a `master`.
     */
    concept?: boolean;
  },
): Promise<void> {
  const db = getDatabase();
  const objectStore = getObjectStore();
  const provider = getAiProvider();
  const generated = params.concept
    ? await provider.generateConceptImage(params.prompt)
    : await provider.generateStickerImage({
      prompt: params.prompt,
      references: params.references,
      mask: params.mask,
      conversationContext: params.conversationContext,
      mode: params.mode,
    });
  const currentJob = await db.select({ state: generationJobs.state }).from(generationJobs).where(eq(generationJobs.id, job.id)).get();
  const currentSticker = await db.select({ status: stickers.status }).from(stickers).where(eq(stickers.id, stickerId)).get();
  if (currentJob?.state !== "running" || !currentSticker || currentSticker.status === "deleting") {
    throw new Error("Generation was cancelled before storage");
  }
  const inspection = await inspectImage(generated.bytes);
  if (inspection.width !== 1024 || inspection.height !== 1024) {
    throw new Error("Generated candidate failed normalized size validation");
  }
  if (!params.concept && !inspection.hasTransparentPixels) {
    throw new Error("Generated candidate failed normalized transparency validation");
  }
  const r2Key = objectKey(job.ownerId, params.assetId, "image/png");
  await objectStore.put(r2Key, {
    bytes: generated.bytes,
    contentType: "image/png",
    metadata: { sha256: inspection.sha256, source: "vercel-ai-gateway" },
  });
  const afterPutJob = await db.select({ state: generationJobs.state }).from(generationJobs).where(eq(generationJobs.id, job.id)).get();
  if (afterPutJob?.state !== "running") {
    await objectStore.delete(r2Key);
    throw new Error("Generation was cancelled during storage");
  }
  try {
    await db.insert(assets).values({
      id: params.assetId,
      ownerId: job.ownerId,
      stickerId,
      kind: params.concept ? "preview" : "master",
      state: "ready",
      r2Key,
      mimeType: "image/png",
      byteSize: inspection.byteSize,
      width: inspection.width,
      height: inspection.height,
      sha256: inspection.sha256,
      hasAlpha: inspection.hasTransparentPixels,
      createdAt: new Date(),
      readyAt: new Date(),
    }).onConflictDoUpdate({
      target: assets.id,
      set: {
        state: "ready",
        byteSize: inspection.byteSize,
        width: inspection.width,
        height: inspection.height,
        sha256: inspection.sha256,
        hasAlpha: inspection.hasTransparentPixels,
        readyAt: new Date(),
      },
    });
  } catch (error) {
    await objectStore.delete(r2Key);
    throw error;
  }
}

/** Wraps layers in the canonical canvas and per-kind default timing. */
function documentWithLayers(kind: "static" | "animated", layers: unknown[]): StickerDocument {
  const base = {
    version: CURRENT_DOCUMENT_VERSION,
    canvas: { width: 1024, height: 1024, coordinateSpace: "normalized" as const, transparent: true },
    mp4Background: { type: "solid" as const, color: "#FFFFFF" },
    layers,
  };
  return kind === "static"
    ? StickerDocumentSchema.parse({ ...base, kind, durationSeconds: 0, fps: 0, loop: "once" })
    : StickerDocumentSchema.parse({ ...base, kind, durationSeconds: 2, fps: 30, loop: "loop" });
}

function emptyDocument(kind: "static" | "animated", assetId: string): StickerDocument {
  return documentWithLayers(kind, [{
    id: "hero",
    name: "Hero",
    hidden: false,
    type: "image" as const,
    assetId,
    contentMode: "fit" as const,
    animation: { position: [], scale: [], rotation: [], opacity: [], effects: [], trim: [] },
  }]);
}

/**
 * The generate-backed layers of a plan, paired with the deterministic asset id each one will use.
 *
 * Indexes are assigned over generate layers only, so inserting a text layer ahead of an image layer
 * does not shift every asset id and orphan the objects a replay already wrote to R2.
 */
function generatedLayers(plan: PlanV1, jobId: string) {
  let index = 0;
  return plan.layers.flatMap((layer) => (layer.source.kind === "generate"
    ? [{ layer, prompt: layer.source.prompt, assetId: derivedAssetId(jobId, index++) }]
    : []));
}

/**
 * Turns a confirmed plan into a multi-layer document.
 *
 * Layout is expressed through each layer's `anchor`, which the compiler turns into a single
 * keyframe at t=0 on whichever channels differ from the renderer's defaults: the interpolator
 * returns a constant when a channel has one keyframe, and static documents are only allowed
 * keyframes at t=0, so this is the one encoding that works for both kinds.
 */
function documentFromPlan(plan: PlanV1, jobId: string): StickerDocument {
  const compiled = compilePlanAnimations(plan);
  const assetIds = new Map(generatedLayers(plan, jobId).map((item) => [item.layer.layerId, item.assetId]));

  const layers = plan.layers.map((layer, index): StickerLayerV1 => {
    const base = {
      id: layer.layerId,
      name: layer.name,
      hidden: false,
      anchor: planLayerAnchor(layer),
      animations: layer.animations,
      animation: compiled[index],
      blendMode: "normal" as const,
    };
    const source = layer.source;
    // The plan vocabulary stays deliberately narrow — a planner picks a colour, not a gradient —
    // so each planned colour becomes a solid paint here. Richer paints exist for the editor to
    // author; widening the plan would only give the model more ways to be wrong.
    const solid = (color: string) => ({ type: "solid" as const, color });
    switch (source.kind) {
    case "generate":
      return { ...base, type: "image", assetId: assetIds.get(layer.layerId)!, contentMode: "fit" };
    case "text":
      return {
        ...base,
        type: "text",
        text: source.text,
        font: source.font,
        weight: source.weight,
        paint: solid(source.color),
        alignment: source.alignment,
      };
    case "shape":
      return {
        ...base,
        type: "shape",
        shape: source.shape === "star" ? { kind: "star", points: 5, innerRatio: 0.42 } : { kind: source.shape },
        fill: solid(source.fill),
        // A zero width is v1's way of saying "no stroke", and the plan schema kept that shape.
        stroke: source.stroke && source.strokeWidth > 0
          ? { paint: solid(source.stroke), width: source.strokeWidth, lineCap: "round", lineJoin: "round", dash: [] }
          : undefined,
        cornerRadius: source.cornerRadius,
      };
    case "particle":
      return {
        ...base,
        type: "particle",
        preset: source.preset,
        count: source.count,
        paint: solid(source.color),
        seed: source.seed,
      };
    }
  });

  const canvas = { width: 1024, height: 1024, coordinateSpace: "normalized", transparent: true } as const;
  return plan.kind === "static"
    ? StickerDocumentSchema.parse({
      version: CURRENT_DOCUMENT_VERSION, canvas, layers, kind: "static", durationSeconds: 0, fps: 0, loop: "once",
    })
    : StickerDocumentSchema.parse({
      version: CURRENT_DOCUMENT_VERSION,
      canvas,
      layers,
      kind: "animated",
      durationSeconds: plan.timing.durationSeconds,
      fps: plan.timing.fps,
      loop: plan.timing.loop,
    });
}

/**
 * Posts, or updates in place, the single plan card a drafting turn produces.
 *
 * One card per turn rather than one per `show_plan` call: `insertAssistantMessage` treats "this job
 * already has an assistant message" as the replay signal, and three stacked cards for one turn
 * would be noise anyway. Re-showing a revised draft rewrites the same card.
 */
async function upsertPlanCard(
  job: typeof generationJobs.$inferSelect,
  planId: string,
  revision: number,
  summary: string,
): Promise<string> {
  const db = getDatabase();
  const existing = await db.select({ id: chatMessages.id }).from(chatMessages).where(and(
    eq(chatMessages.jobId, job.id),
    eq(chatMessages.role, "assistant"),
  )).get();
  if (existing) {
    await db.update(chatMessages).set({ content: summary, kind: "plan", planId, planRevision: revision })
      .where(eq(chatMessages.id, existing.id));
    return existing.id;
  }
  const id = await insertAssistantMessage(job, summary, "plan");
  await db.update(chatMessages).set({ planId, planRevision: revision }).where(eq(chatMessages.id, id));
  return id;
}

/** Best-effort storyboard for a plan. A failure must never sink the drafting turn. */
async function renderPlanConcept(
  job: typeof generationJobs.$inferSelect,
  stickerId: string,
  planId: string,
  plan: PlanV1,
): Promise<void> {
  if (!plan.conceptPrompt) return;
  const db = getDatabase();
  const row = await db.select({ conceptAssetId: plans.conceptAssetId }).from(plans)
    .where(eq(plans.id, planId)).get();
  if (row?.conceptAssetId) return;
  try {
    const assetId = derivedAssetId(planId, "concept");
    await generateAndStoreAsset(job, stickerId, {
      assetId,
      prompt: plan.conceptPrompt,
      references: [],
      mode: "generate",
      concept: true,
    });
    await attachPlanConcept(db, planId, assetId);
  } catch {
    // The plan is fully usable without a picture, so a failed storyboard is silent.
  }
}

/**
 * Runs the agent's plan-drafting loop and ends the turn with a card for the user to decide on.
 *
 * Nothing is generated here. The model creates a draft, revises it as many times as it needs, and
 * finalizes it; only a user confirmation starts a `compose` job that spends money on images.
 */
async function executePlanTurn(
  job: typeof generationJobs.$inferSelect,
  sticker: typeof stickers.$inferSelect,
  threadId: string,
  instruction: string,
  history: string,
  activeDocument: StickerDocument | undefined,
  toolCallId: string | undefined,
): Promise<AiTurnResult> {
  const db = getDatabase();
  const rejected = await recentlyRejectedPlans(db, job.ownerId, sticker.id);
  // The message the plan is anchored to must exist before the row that references it, and the
  // drafting turn has not written its assistant message yet. The tool-call row for `plan-sticker`
  // is a real message on this thread, so it anchors the plan until the card replaces it.
  const anchorMessageId = toolCallId ?? job.sourceMessageId!;

  let updates = 0;
  let latest: { planId: string; revision: number; plan: PlanV1 } | undefined;

  const session: PlanDraftingSession = {
    createPlan: async (plan) => {
      const call = await beginToolCall(job, "create_plan");
      try {
        const created = await createPlan(db, {
          ownerId: job.ownerId,
          stickerId: sticker.id,
          threadId,
          messageId: anchorMessageId,
          plan,
          // Deterministic so a workflow replay reuses the same plan row instead of stacking a
          // second draft that supersedes the first.
          planId: derivedAssetId(job.id, "plan"),
        });
        latest = { planId: created.planId, revision: created.revision, plan };
        await finishToolCall(job, call);
        return { planId: created.planId, revision: created.revision };
      } catch (error) {
        await finishToolCall(job, call, "failed");
        throw error;
      }
    },
    updatePlan: async (planId, plan) => {
      updates += 1;
      // Distinct labels, or the repeated calls de-duplicate onto one row and the user sees a single
      // stuck spinner instead of each revision.
      const call = await beginToolCall(job, "update_plan", undefined, `update_plan #${updates}`);
      try {
        const updated = await updatePlan(db, { ownerId: job.ownerId, stickerId: sticker.id, planId, plan });
        latest = { planId: updated.planId, revision: updated.revision, plan };
        await finishToolCall(job, call);
        return updated;
      } catch (error) {
        await finishToolCall(job, call, "failed");
        throw error;
      }
    },
    showPlan: async (planId) => {
      const call = await beginToolCall(job, "show_plan");
      try {
        if (!latest) throw new Error("There is no plan to show yet");
        await renderPlanConcept(job, sticker.id, planId, latest.plan);
        await upsertPlanCard(job, planId, latest.revision, latest.plan.summary);
        await finishToolCall(job, call);
        return { planId, revision: latest.revision };
      } catch (error) {
        await finishToolCall(job, call, "failed");
        throw error;
      }
    },
    finalizePlan: async (planId) => {
      const call = await beginToolCall(job, "finalize_plan");
      try {
        const finalized = await finalizePlan(db, { ownerId: job.ownerId, stickerId: sticker.id, planId });
        latest = { planId: finalized.planId, revision: finalized.revision, plan: finalized.plan };
        await finishToolCall(job, call);
        return { planId: finalized.planId, revision: finalized.revision };
      } catch (error) {
        await finishToolCall(job, call, "failed");
        throw error;
      }
    },
  };

  const result = await getAiProvider().planSticker({
    instruction,
    history,
    stickerKind: sticker.kind,
    document: activeDocument,
    rejectedReasons: rejected.map((row) => row.decisionReason).filter((reason): reason is string => Boolean(reason)),
  }, session);

  if (!latest) throw new Error("The planner finished without drafting a plan");

  // The loop can also stop on its step cap. A draft the user can look at and reject beats a dead
  // turn, so finalize whatever the model got to rather than failing.
  if (!result?.finalized) {
    const finalized = await finalizePlan(db, {
      ownerId: job.ownerId,
      stickerId: sticker.id,
      planId: latest.planId,
    });
    latest = { planId: finalized.planId, revision: finalized.revision, plan: finalized.plan };
  }

  await finishToolCall(job, toolCallId);
  const assistantMessageId = await upsertPlanCard(job, latest.planId, latest.revision, latest.plan.summary);
  return turnResult(assistantMessageId);
}

/**
 * Runs the agent's animation-drafting loop and ends the turn with a candidate for the user to keep.
 *
 * The model applies operations, reads back what they compiled to, and revises until it is happy.
 * Nothing is persisted until it finishes: the working document lives in this function, so a
 * rejected timing costs one tool call rather than a whole re-planning run.
 */
async function executeAnimationTurn(
  job: typeof generationJobs.$inferSelect,
  sticker: typeof stickers.$inferSelect,
  sourceMessage: typeof chatMessages.$inferSelect,
  base: StickerDocument,
  activeRevision: typeof stickerRevisions.$inferSelect,
  instruction: string,
  history: string,
  targetLayerId: string | undefined,
  toolCallId: string | undefined,
): Promise<AiTurnResult> {
  const db = getDatabase();
  await appendGenerationEvent(db, job.id, job.ownerId, "progress", { stage: "planning_animation", progress: 0.35 });

  // Deterministic, so a workflow replay hands the model the same id it used before. Opaque to the
  // model, which only ever echoes it back.
  const animationId = derivedAssetId(job.id, "animation");
  let working: StickerDocument | undefined;
  let revision = 0;
  let snapshot = 0;
  // One transcript row per call, retries included. `beginToolCall` de-duplicates on the label, so a
  // bare `create_animation` reused for a retry would find the row it already marked failed, leave it
  // failed, and show the user a permanently broken step that actually succeeded.
  const calls = new Map<StickerToolName, number>();
  const nextLabel = (toolName: StickerToolName) => {
    const count = (calls.get(toolName) ?? 0) + 1;
    calls.set(toolName, count);
    return count === 1 ? toolName : `${toolName} #${count}`;
  };
  // Everything the model did not author. Telling it to fix a cancelled job or a vanished asset with
  // `update_animation` would only spend the loop's step budget, so these stop the loop instead.
  const abort = (error: unknown): never => { throw new AnimationTurnAbort(error); };
  // `beginToolCall` refuses to open a row on a job that is no longer running, and it says so with an
  // ordinary Error. Left unclassified that reads as a repairable complaint, so a cancelled turn
  // would be answered with advice the model would keep trying to act on.
  const openCall = async (toolName: StickerToolName): Promise<string> => {
    try {
      return await beginToolCall(job, toolName, undefined, nextLabel(toolName));
    } catch (error) {
      return abort(error);
    }
  };

  const land = async (operations: StickerOperationV1[]) => {
    await assertJobStillRunning(job.id).catch(abort);
    // Repairable: everything below is the model's own work, so it throws straight through to the
    // tool body and comes back as text it can act on.
    for (const operation of operations) {
      validatePlannedAnimationOperation(operation);
      if (targetLayerId) assertTargetedAnimationOperation(operation, targetLayerId);
    }
    // Applied to the base, never to the previous attempt: an update restates the whole animation, so
    // a repair cannot inherit half of the timing that was rejected.
    const document = applyStickerOperationsV1(base, operations);
    await assertDocumentAssetsOwned(document, job.ownerId, sticker.id).catch(abort);
    working = document;
    revision += 1;
    snapshot += 1;
    await appendGenerationEvent(db, job.id, job.ownerId, "document", { snapshot, document }).catch(abort);
    return { animationId, revision, document };
  };

  const session: AnimationDraftingSession = {
    createAnimation: async (operations) => {
      const call = await openCall("create_animation");
      try {
        if (working) throw new Error(`An animation already exists (${animationId}); use update_animation to change it`);
        const state = await land(operations);
        await finishToolCall(job, call);
        return state;
      } catch (error) {
        await finishToolCall(job, call, "failed");
        throw error;
      }
    },
    updateAnimation: async (_animationId, operations) => {
      const call = await openCall("update_animation");
      try {
        if (!working) throw new Error("There is no animation to update yet; call create_animation first");
        const state = await land(operations);
        await finishToolCall(job, call);
        return state;
      } catch (error) {
        await finishToolCall(job, call, "failed");
        throw error;
      }
    },
    finalizeAnimation: async () => {
      const call = await openCall("finalize_animation");
      try {
        if (!working) throw new Error("There is no animation to finalize yet; call create_animation first");
        await finishToolCall(job, call);
        return { animationId, revision, document: working };
      } catch (error) {
        await finishToolCall(job, call, "failed");
        throw error;
      }
    },
  };

  const result = await getAiProvider().animateSticker(
    { document: base, instruction, history, targetLayerId },
    session,
  );

  // Nothing landed at all: there is no motion to show and no reason to think a replay would find
  // any, so end the turn rather than publishing the base document back as a candidate.
  if (!working) throw new FatalError("The animation planner produced no usable motion");
  // Before the warning below, so a turn the user stopped is not also reported as a model that ran
  // out of steps.
  await assertJobStillRunning(job.id);
  // The loop can also stop on its step cap, or because finalize_animation itself threw. A candidate
  // the user can look at and reject beats a dead turn, so ship whatever motion actually landed.
  if (!result?.finalized) {
    console.warn("Finalizing an unfinished animation loop", { jobId: job.id, stickerId: sticker.id, revision });
  }
  const document = working;

  const revisionId = await createCandidateRevision(db, {
    ownerId: job.ownerId,
    stickerId: sticker.id,
    sourceMessageId: sourceMessage.id,
    document,
    id: job.id,
    parentRevisionId: activeRevision.id,
    // Animation adds no new artwork, so the base revision's images carry over untouched.
    masterAssetId: activeRevision.masterAssetId ?? undefined,
    previewAssetId: activeRevision.previewAssetId ?? undefined,
  });
  await finishToolCall(job, toolCallId);
  const content = await showStickerThroughTool(job, revisionId, document.kind, instruction, history);
  const assistantMessageId = await insertAssistantMessage(job, content, "animation", revisionId);
  const turn = await turnResult(assistantMessageId, revisionId);
  await appendGenerationEvent(db, job.id, job.ownerId, "document", { snapshot: snapshot + 1, revisionId, document });
  await appendGenerationEvent(db, job.id, job.ownerId, "candidate", {
    revisionId,
    assistantMessageId,
    assistantMessage: turn.assistantMessage,
  });
  return turn;
}

/**
 * Builds a confirmed plan: one image per generate layer, then the document the plan describes.
 *
 * Motion is no longer a second AI pass. The plan already carries structured animation specs that
 * the user approved, so the document is assembled deterministically — which also means a plan whose
 * motion cannot compile fails here *before* any image is paid for, rather than after.
 *
 * `assertValidAnimationBase` is deliberately not called. That guard stops a client branching
 * animation off a revision it does not own or that was never accepted; this document was built in
 * this step from assets created in this step, so there is no such question. The invariants it
 * stands in for still hold: `confirmPlan` rejects a plan whose kind does not match the project, a
 * static document cannot hold a non-zero keyframe by schema, and `assertDocumentAssetsOwned` runs
 * over the finished document.
 */
async function executePlanBuildTurn(
  job: typeof generationJobs.$inferSelect,
  sticker: typeof stickers.$inferSelect,
  sourceMessage: typeof chatMessages.$inferSelect,
  history: string,
  activeRevision: typeof stickerRevisions.$inferSelect | undefined,
): Promise<AiTurnResult> {
  const db = getDatabase();
  const planRow = await db.select().from(plans).where(and(
    eq(plans.jobId, job.id),
    eq(plans.ownerId, job.ownerId),
  )).get();
  if (!planRow) throw new Error("Plan not found for this job");
  const plan = PlanV1Schema.parse(planRow.planJson);
  const generated = generatedLayers(plan, job.id);

  const primaryToolCallId = await beginToolCall(job, "build-plan");
  await appendGenerationEvent(db, job.id, job.ownerId, "progress", {
    stage: "composing",
    progress: 0.05,
    partCount: generated.length,
    layerCount: plan.layers.length,
  });

  for (const [index, item] of generated.entries()) {
    await assertJobStillRunning(job.id);
    const label = `compose-part:${index} ${item.layer.name}`;
    const partToolCallId = await beginToolCall(job, "build-plan", undefined, label);
    try {
      await generateAndStoreAsset(job, sticker.id, {
        assetId: item.assetId,
        prompt: item.prompt,
        references: [],
        conversationContext: history,
        mode: "generate",
      });
    } catch (error) {
      await finishToolCall(job, partToolCallId, "failed");
      throw error;
    }
    await finishToolCall(job, partToolCallId);
    await appendGenerationEvent(db, job.id, job.ownerId, "progress", {
      stage: "composing_part",
      progress: 0.05 + 0.7 * ((index + 1) / Math.max(generated.length, 1)),
      partIndex: index,
      partName: item.layer.name,
      partCount: generated.length,
    });
  }

  const document = documentFromPlan(plan, job.id);
  await assertDocumentAssetsOwned(document, job.ownerId, sticker.id);
  let snapshot = 0;
  await appendGenerationEvent(db, job.id, job.ownerId, "document", { snapshot, document });

  await assertJobStillRunning(job.id);
  const revisionId = await createCandidateRevision(db, {
    ownerId: job.ownerId,
    stickerId: sticker.id,
    sourceMessageId: sourceMessage.id,
    document,
    id: job.id,
    parentRevisionId: activeRevision?.id,
    // No single layer is "the" master; the first generated one keeps the library thumbnail from
    // being blank until published exports supply a real preview. A plan made only of text, shape,
    // or particle layers has no image asset at all, which is why these are optional.
    masterAssetId: generated[0]?.assetId,
    previewAssetId: generated[0]?.assetId,
  });
  await finishToolCall(job, primaryToolCallId);
  const content = await showStickerThroughTool(job, revisionId, document.kind, plan.title, history);
  const assistantMessageId = await insertAssistantMessage(job, content, "image", revisionId);
  const result = await turnResult(assistantMessageId, revisionId);
  snapshot += 1;
  await appendGenerationEvent(db, job.id, job.ownerId, "document", { snapshot, revisionId, document });
  await appendGenerationEvent(db, job.id, job.ownerId, "candidate", {
    revisionId,
    assistantMessageId,
    assetIds: generated.map((item) => item.assetId),
    assistantMessage: result.assistantMessage,
  });
  return result;
}

export async function executeAiJobStep(jobId: string): Promise<AiTurnResult> {
  "use step";
  const db = getDatabase();
  const job = await db.select().from(generationJobs).where(eq(generationJobs.id, jobId)).get();
  if (!job || !job.sourceMessageId) throw new Error("Generation job or source message not found");
  if (job.state !== "running") throw new Error(`Generation job is not running (${job.state})`);
  const [sticker, sourceMessage] = await Promise.all([
    db.select().from(stickers).where(and(eq(stickers.id, job.stickerId), eq(stickers.ownerId, job.ownerId))).get(),
    db.select().from(chatMessages).where(eq(chatMessages.id, job.sourceMessageId)).get(),
  ]);
  if (!sticker || !sourceMessage) throw new Error("Sticker generation context not found");
  if (sticker.status === "deleting") throw new Error("Sticker deletion is in progress");
  const existingAssistant = await db.select({ id: chatMessages.id, revisionId: chatMessages.revisionId }).from(chatMessages).where(and(
    eq(chatMessages.jobId, job.id),
    eq(chatMessages.role, "assistant"),
  )).get();
  if (existingAssistant) return turnResult(existingAssistant.id, existingAssistant.revisionId ?? undefined);
  const thread = await db.select().from(chatThreads).where(eq(chatThreads.stickerId, sticker.id)).get();
  if (!thread) throw new Error("Chat thread not found");
  const transcript = (await db.select().from(chatMessages).where(eq(chatMessages.threadId, thread.id))
    .orderBy(desc(chatMessages.sequence)).limit(60)).reverse();
  const history = boundedTranscript(transcript);
  const attachments = await db.select({
    attachment: chatAttachments,
    asset: assets,
  }).from(chatAttachments)
    .innerJoin(assets, eq(chatAttachments.assetId, assets.id))
    .where(eq(chatAttachments.messageId, sourceMessage.id))
    .orderBy(asc(chatAttachments.position));

  const baseRevisionId = sourceMessage.baseRevisionId ?? sticker.activeRevisionId;
  const activeRevision = baseRevisionId
    ? await db.select().from(stickerRevisions).where(and(eq(stickerRevisions.id, baseRevisionId), eq(stickerRevisions.stickerId, sticker.id))).get()
    : undefined;
  const activeDocument = activeRevision ? StickerDocumentSchema.parse(activeRevision.documentJson) : undefined;
  if (activeDocument) await assertDocumentAssetsOwned(activeDocument, job.ownerId, sticker.id);
  const existingRevision = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, job.id)).get();
  if (existingRevision) {
    const existingDocument = StickerDocumentSchema.parse(existingRevision.documentJson);
    const kind = existingDocument.kind === "animated" && sourceMessage.kind === "animation"
      ? "animation"
      : sourceMessage.kind === "image"
        ? "image"
        : "image_edit";
    const primaryToolCallId = await beginToolCall(
      job,
      kind === "animation" ? "animate-sticker" : kind === "image" ? "generate-sticker" : "edit-sticker",
      existingRevision.id,
    );
    await finishToolCall(job, primaryToolCallId);
    const content = await showStickerThroughTool(job, existingRevision.id, existingDocument.kind, sourceMessage.content, history);
    const assistantMessageId = await insertAssistantMessage(job, content, kind, existingRevision.id);
    return turnResult(assistantMessageId, existingRevision.id);
  }

  if (job.kind === "compose") {
    return executePlanBuildTurn(job, sticker, sourceMessage, history, activeRevision);
  }

  if (job.kind !== "image" && job.kind !== "edit" && job.kind !== "animation" && job.kind !== "chat") {
    throw new Error(`Unsupported AI job kind: ${job.kind}`);
  }
  let effectiveKind: "image" | "edit" | "animation" = job.kind === "chat" ? "edit" : job.kind;
  let instruction = sourceMessage.content;
  let targetLayerId = sourceMessage.targetLayerId ?? undefined;
  let imagePlacement = sourceMessage.imagePlacement;
  let primaryToolCallId: string | undefined;

  if (job.kind === "chat") {
    const action = await getAiProvider().routeChatTurn({
      instruction: sourceMessage.content,
      history,
      stickerKind: sticker.kind,
      document: activeDocument,
      attachmentCount: attachments.filter((row) => row.attachment.kind === "reference").length,
    });
    // Motion is keyframed onto a live revision of this sticker — the one the user kept, or a
    // candidate descended from it. The router reads their words, not the revision's state, so it
    // cannot know whether the base still qualifies, and by the time it has chosen the turn is
    // already in the transcript. Say what is missing instead of failing the job on a rule the user
    // was never shown.
    if (action.type === "animate" && !await isValidAnimationBase(db, sticker, activeRevision)) {
      console.warn("Declined a routed animate turn", {
        jobId: job.id,
        stickerId: sticker.id,
        sourceMessageId: sourceMessage.id,
        sourceMessageBaseRevisionId: sourceMessage.baseRevisionId,
        stickerActiveRevisionId: sticker.activeRevisionId,
        resolvedBaseRevisionId: baseRevisionId,
        targetLayerId: action.targetLayerId,
      });
      const declinedCallId = await beginToolCall(job, "reply");
      await finishToolCall(job, declinedCallId);
      return turnResult(await insertAssistantMessage(
        job,
        activeDocument
          ? "That version isn’t the one I’m working from any more. Ask me again and I’ll animate the"
            + " sticker that’s on screen now."
          : "There’s no sticker to animate yet. Tell me what you want it to look like and I’ll draw"
            + " it first.",
        "text",
      ));
    }
    const toolName: StickerToolName = action.type === "generate"
      ? "generate-sticker"
      : action.type === "generate_image"
        ? "generate-image"
        : action.type === "edit"
          ? "edit-sticker"
          : action.type === "animate"
            ? "animate-sticker"
            : action.type === "plan"
              ? "plan-sticker"
              : action.type === "show"
                ? "show-sticker"
                : "reply";
    primaryToolCallId = await beginToolCall(job, toolName, action.type === "show" ? activeRevision?.id : undefined);
    if (action.type === "plan") {
      return executePlanTurn(job, sticker, thread.id, action.instruction, history, activeDocument, primaryToolCallId);
    }
    if (action.type === "reply") {
      await finishToolCall(job, primaryToolCallId);
      return turnResult(await insertAssistantMessage(job, action.message, "text"));
    }
    if (action.type === "show") {
      await finishToolCall(job, primaryToolCallId);
      if (!activeRevision || !activeDocument) {
        return turnResult(await insertAssistantMessage(job, "There is no sticker revision to show yet.", "text"));
      }
      const kind = activeDocument.kind === "animated" ? "animation" : "image";
      return turnResult(
        await insertAssistantMessage(job, action.caption, kind, activeRevision.id),
        activeRevision.id,
      );
    }
    // `generate-image` only means "another layer" when there is a document to add one to. On an
    // empty canvas it is an ordinary generation, and calling it an edit would label the transcript
    // turn `image_edit` and send the empty-document branch down the replace path for no reason.
    const addsLayer = action.type === "generate_image" && Boolean(activeDocument);
    effectiveKind = action.type === "animate"
      ? "animation"
      : action.type === "generate" || (action.type === "generate_image" && !addsLayer)
        ? "image"
        : "edit";
    instruction = action.instruction;
    targetLayerId = action.type === "edit" || action.type === "animate" ? action.targetLayerId : undefined;
    imagePlacement = action.type === "edit" ? action.imagePlacement : addsLayer ? "add" : "replace";
    await db.update(chatMessages).set({
      kind: effectiveKind === "animation" ? "animation" : effectiveKind === "edit" ? "image_edit" : "image",
      // Explicitly null: an undefined column is one drizzle leaves alone, which would strand the
      // target a superseded routing of this same message wrote on the row.
      targetLayerId: targetLayerId ?? null,
      imagePlacement,
    }).where(eq(chatMessages.id, sourceMessage.id));
  } else if (job.kind === "image" && sticker.kind === "animated" && !activeDocument) {
    // Project creation does not go through the chat router, so without this the very first
    // prompt could only ever become one flat image — and a single flat image cannot be
    // keyframed into a per-element effect like a typewriter reveal later. Consult the router
    // here, but honour only a `plan` answer: anything else falls through to a plain
    // generate, so routing can upgrade creation and never derail it.
    const action = await getAiProvider().routeChatTurn({
      instruction,
      history,
      stickerKind: sticker.kind,
      document: undefined,
      attachmentCount: attachments.filter((row) => row.attachment.kind === "reference").length,
    }).catch(() => undefined);
    if (action?.type === "plan") {
      return executePlanTurn(
        job,
        sticker,
        thread.id,
        action.instruction,
        history,
        undefined,
        await beginToolCall(job, "plan-sticker"),
      );
    }
    primaryToolCallId = await beginToolCall(job, "generate-sticker");
  } else {
    primaryToolCallId = await beginToolCall(
      job,
      job.kind === "animation" ? "animate-sticker" : job.kind === "image" ? "generate-sticker" : "edit-sticker",
    );
  }

  if (effectiveKind === "animation") {
    if (!activeDocument || activeDocument.kind !== "animated" || !activeRevision) {
      throw new FatalError("There is no animated sticker to add motion to");
    }
    await assertValidAnimationBase(db, sticker, activeRevision);
    if (targetLayerId && !activeDocument.layers.some((layer) => layer.id === targetLayerId)) {
      throw new FatalError("The requested animation layer does not exist");
    }
    return executeAnimationTurn(
      job,
      sticker,
      sourceMessage,
      activeDocument,
      activeRevision,
      instruction,
      history,
      targetLayerId,
      primaryToolCallId,
    );
  }

  await appendGenerationEvent(db, job.id, job.ownerId, "progress", { stage: "preparing_context", progress: 0.15 });

  const objectStore = getObjectStore();
  const maskRow = attachments.find((row) => row.attachment.kind === "mask");
  const referenceRows = attachments.filter((row) => row.attachment.kind === "reference");
  targetLayerId = maskRow?.attachment.targetLayerId ?? targetLayerId;
  // Reached only when the id came from the request, which the chat endpoint has already validated
  // against this same base revision, or from a provider that did not reconcile its own routing. Both
  // are deterministic, so retrying replays the identical failure: fail the turn once instead.
  if (targetLayerId && !activeDocument?.layers.some((layer) => layer.type === "image" && layer.id === targetLayerId)) {
    throw new FatalError("The requested image layer does not exist");
  }
  const targetLayer = activeDocument?.layers.find((layer) => layer.type === "image" && (!targetLayerId || layer.id === targetLayerId));
  const targetAsset = targetLayer?.type === "image"
    ? await db.select().from(assets).where(and(eq(assets.id, targetLayer.assetId), eq(assets.ownerId, job.ownerId))).get()
    : undefined;

  const replacesExistingImage = effectiveKind === "edit" && imagePlacement !== "add";
  const imageRows = [
    ...(replacesExistingImage && targetAsset ? [targetAsset] : []),
    ...referenceRows.map((row) => row.asset),
  ];
  const references = await Promise.all(imageRows.map(async (asset) => {
    const object = await objectStore.get(asset.r2Key);
    return { bytes: object.bytes, mimeType: asset.mimeType };
  }));
  const mask = maskRow
    ? await objectStore.get(maskRow.asset.r2Key).then((object) => ({ bytes: object.bytes, mimeType: maskRow.asset.mimeType }))
    : undefined;

  await appendGenerationEvent(db, job.id, job.ownerId, "progress", { stage: "generating_image", progress: 0.4 });
  const assetId = job.id;
  await generateAndStoreAsset(job, sticker.id, {
    assetId,
    prompt: instruction,
    references,
    mask,
    conversationContext: history,
    mode: replacesExistingImage ? "conversation_edit" : "generate",
  });

  let document: StickerDocument;
  if (!activeDocument) {
    document = emptyDocument(sticker.kind, assetId);
  } else if (imagePlacement === "add") {
    if (activeDocument.layers.length >= 8) throw new Error("StickerDocument already has the maximum 8 layers");
    const layer = emptyDocument(activeDocument.kind, assetId).layers[0];
    layer.id = `image_${assetId.replaceAll("-", "").slice(0, 12)}`;
    layer.name = "Generated layer";
    document = applyStickerOperationsV1(activeDocument, [{ op: "addLayer", layer }]);
  } else {
    const imageLayer = targetLayer ?? activeDocument.layers.find((layer) => layer.type === "image");
    if (imageLayer?.type === "image") {
      document = applyStickerOperationsV1(activeDocument, [{ op: "replaceAsset", layerId: imageLayer.id, assetId }]);
    } else {
      document = applyStickerOperationsV1(activeDocument, [{
        op: "addLayer",
        layer: emptyDocument(activeDocument.kind, assetId).layers[0],
      }]);
    }
  }
  await assertJobStillRunning(job.id);
  const revisionId = await createCandidateRevision(db, {
    ownerId: job.ownerId,
    stickerId: sticker.id,
    sourceMessageId: sourceMessage.id,
    document,
    id: job.id,
    parentRevisionId: activeRevision?.id,
    masterAssetId: assetId,
    previewAssetId: assetId,
  });
  await finishToolCall(job, primaryToolCallId);
  const content = await showStickerThroughTool(job, revisionId, document.kind, instruction, history);
  const assistantMessageId = await insertAssistantMessage(job, content, effectiveKind === "edit" ? "image_edit" : "image", revisionId);
  const result = await turnResult(assistantMessageId, revisionId);
  await appendGenerationEvent(db, job.id, job.ownerId, "progress", { stage: "validating_candidate", progress: 0.85 });
  await appendGenerationEvent(db, job.id, job.ownerId, "document", { revisionId, document });
  await appendGenerationEvent(db, job.id, job.ownerId, "candidate", {
    revisionId,
    assistantMessageId,
    assetId,
    assistantMessage: result.assistantMessage,
  });
  return result;
}

export async function publishExportsStep(jobId: string, request: PublishExportsRequest) {
  "use step";
  const db = getDatabase();
  const job = await db.select().from(generationJobs).where(eq(generationJobs.id, jobId)).get();
  if (!job || job.kind !== "export") throw new Error("Export job not found");
  await appendGenerationEvent(db, job.id, job.ownerId, "progress", { stage: "verifying_exports", progress: 0.5 });
  return bindExports(db, job.ownerId, job.stickerId, request, job.id);
}

export async function completeJobStep(jobId: string, result: Record<string, unknown>): Promise<void> {
  "use step";
  const db = getDatabase();
  const job = await db.select().from(generationJobs).where(eq(generationJobs.id, jobId)).get();
  if (!job) return;
  if (job.state === "succeeded") return;
  await db.transaction(async (tx) => {
    const now = new Date();
    const changed = await tx.update(generationJobs).set({ state: "succeeded", updatedAt: now, completedAt: now })
      .where(and(eq(generationJobs.id, jobId), eq(generationJobs.state, "running"))).returning({ id: generationJobs.id });
    if (changed.length === 0) throw new Error("Job is no longer running");
    if (job.sourceMessageId) {
      await tx.update(chatMessages).set({ status: "complete" }).where(and(
        eq(chatMessages.id, job.sourceMessageId),
        eq(chatMessages.jobId, job.id),
      ));
    }
    await tx.insert(generationEvents).values({ jobId, ownerId: job.ownerId, type: "completed", dataJson: result, createdAt: now });
  });
}

export async function failJobStep(jobId: string, message: string): Promise<void> {
  "use step";
  const db = getDatabase();
  const job = await db.select().from(generationJobs).where(eq(generationJobs.id, jobId)).get();
  if (!job) return;
  if (job.state === "failed") return;
  const safeMessage = message.slice(0, 500);
  await db.transaction(async (tx) => {
    const now = new Date();
    const changed = await tx.update(generationJobs).set({
      state: "failed",
      errorCode: "GENERATION_FAILED",
      errorMessage: safeMessage,
      updatedAt: now,
      completedAt: now,
    }).where(and(eq(generationJobs.id, jobId), eq(generationJobs.state, "running"))).returning({ id: generationJobs.id });
    if (changed.length === 0) return;
    if (job.sourceMessageId) {
      await tx.update(chatMessages).set({ status: "failed" }).where(and(
        eq(chatMessages.id, job.sourceMessageId),
        eq(chatMessages.jobId, job.id),
      ));
    }
    await tx.update(chatMessages).set({ status: "failed" }).where(and(
      eq(chatMessages.jobId, job.id),
      eq(chatMessages.role, "system"),
      eq(chatMessages.kind, "status"),
      eq(chatMessages.status, "streaming"),
    ));
    await tx.insert(generationEvents).values({
      jobId,
      ownerId: job.ownerId,
      type: "failed",
      dataJson: { code: "GENERATION_FAILED", message: "Generation failed. You can retry this request." },
      createdAt: now,
    });
  });
}

export async function purgeStickerStep(jobId: string): Promise<string[]> {
  "use step";
  const db = getDatabase();
  const job = await db.select().from(generationJobs).where(eq(generationJobs.id, jobId)).get();
  if (!job || job.kind !== "cleanup") throw new Error("Cleanup job not found");
  const objectStore = getObjectStore();
  const rows = await db.select().from(assets).where(and(eq(assets.stickerId, job.stickerId), eq(assets.ownerId, job.ownerId)));
  for (const asset of rows) await objectStore.delete(asset.r2Key);
  return rows.map((asset) => asset.r2Key);
}

export async function sweepStickerObjectsStep(objectKeys: string[]): Promise<void> {
  "use step";
  const objectStore = getObjectStore();
  for (const key of objectKeys) await objectStore.delete(key);
}

export async function finalizeStickerPurgeStep(jobId: string): Promise<void> {
  "use step";
  const db = getDatabase();
  const job = await db.select().from(generationJobs).where(eq(generationJobs.id, jobId)).get();
  if (!job || job.kind !== "cleanup") throw new Error("Cleanup job not found");
  await db.delete(stickers).where(and(
    eq(stickers.id, job.stickerId),
    eq(stickers.ownerId, job.ownerId),
    eq(stickers.status, "deleting"),
  ));
}

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

export type RevisionDecisionInput = {
  ownerId: string;
  stickerId: string;
  revisionId: string;
  decision: "accept" | "reject" | "revert";
  decisionId: string;
};

export async function decideRevisionStep(input: RevisionDecisionInput) {
  "use step";
  const db = getDatabase();
  if (input.decision === "accept") return acceptRevision(db, input.ownerId, input.stickerId, input.revisionId);
  if (input.decision === "reject") return rejectRevision(db, input.ownerId, input.stickerId, input.revisionId);
  return revertRevision(db, input.ownerId, input.stickerId, input.revisionId, input.decisionId);
}
