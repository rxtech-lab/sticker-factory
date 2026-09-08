import { currentBillingEnvironment } from "@/lib/subscription/client";
import { and, desc, eq, inArray, isNotNull, isNull, max, ne } from "drizzle-orm";
import {
  isActionablePlanState,
  isEditablePlanState,
  planGenerationCount,
  planRequiresConcept,
  planVideoCount,
  PlanV1Schema,
  type PlanState,
  type PlanV1,
} from "@/lib/contracts/plan";
import { firstRow, type Database } from "@/lib/db/client";
import { assets, chatMessages, chatThreads, generationEvents, generationJobs, plans, stickers } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { isActiveJobConstraint } from "@/lib/services/stickers";
import { abandonHold, holdCreditsForJob } from "@/lib/subscription/credits";
import { composeCreditHold, jobCreditHold } from "@/lib/subscription/pricing";

export type SerializedPlan = {
  id: string;
  messageId: string;
  state: PlanState;
  revision: number;
  jobId: string | null;
  conceptAssetId: string | null;
  decisionReason: string | null;
  supersedesId: string | null;
  sourceVersionId: string | null;
  /** True when the user can act on this card. Older cards for the same plan render read-only. */
  actionable: boolean;
  generationCount: number;
  plan: PlanV1;
};

export function serializePlan(
  row: typeof plans.$inferSelect,
  options: { atRevision?: number | null } = {},
): SerializedPlan {
  const plan = PlanV1Schema.parse(row.planJson);
  // A card is live only if it was rendering the plan as it stands now. An older `show_plan` card
  // stays in the transcript as a record of what was proposed, but must not offer a Generate button
  // for a draft that has since been rewritten.
  const isCurrentRevision = options.atRevision == null || options.atRevision === row.revision;
  return {
    id: row.id,
    messageId: row.messageId,
    state: row.state,
    revision: row.revision,
    jobId: row.jobId,
    conceptAssetId: row.conceptAssetId,
    decisionReason: row.decisionReason,
    supersedesId: row.supersedesId,
    sourceVersionId: row.restoredFromId,
    actionable: isActionablePlanState(row.state) && isCurrentRevision,
    generationCount: planGenerationCount(plan),
    plan,
  };
}

/** Saved versions, newest first. Active restoration copies retain their source version's identity. */
export async function listPlans(db: Database, ownerId: string, stickerId: string) {
  return db.select().from(plans).where(and(
    eq(plans.ownerId, ownerId),
    eq(plans.stickerId, stickerId),
    isNull(plans.restoredFromId),
  )).orderBy(desc(plans.createdAt));
}

/** Activate a saved version in the latest card without rewriting a plan used by an earlier job. */
export async function selectPlanVersion(
  db: Database,
  ownerId: string,
  stickerId: string,
  versionId: string,
  currentPlanId: string,
  currentRevision: number,
) {
  return db.transaction(async (tx) => {
    const sticker = await tx.select().from(stickers).where(and(
      eq(stickers.id, stickerId), eq(stickers.ownerId, ownerId),
    )).for("update").then(firstRow);
    if (!sticker || sticker.deletedAt) throw new ApiError(404, "STICKER_NOT_FOUND", "Sticker not found");
    if (sticker.status === "deleting") throw new ApiError(409, "STICKER_DELETING", "Sticker deletion is in progress");
    const activeJob = await tx.select({ id: generationJobs.id }).from(generationJobs).where(and(
      eq(generationJobs.stickerId, stickerId),
      inArray(generationJobs.state, ["queued", "running", "waiting"]),
    )).limit(1).then(firstRow);
    if (activeJob) throw new ApiError(409, "AI_TURN_IN_PROGRESS", "Wait for the current turn to finish before selecting a plan");

    const selected = await loadPlan(tx, ownerId, stickerId, versionId);
    const source = selected.restoredFromId
      ? await loadPlan(tx, ownerId, stickerId, selected.restoredFromId)
      : selected;
    const current = await loadPlan(tx, ownerId, stickerId, currentPlanId);
    const card = await tx.select().from(chatMessages).where(and(
      eq(chatMessages.threadId, current.threadId),
      eq(chatMessages.kind, "plan"),
      isNotNull(chatMessages.planId),
    )).orderBy(desc(chatMessages.sequence)).limit(1).then(firstRow);
    if (!card || card.planId !== currentPlanId || current.revision !== currentRevision) {
      throw new ApiError(409, "PLAN_CHANGED", "The latest plan changed. Reload it before selecting a version");
    }
    if (source.state === "draft") throw new ApiError(409, "PLAN_NOT_READY", "This plan is still being drafted");
    if ((current.restoredFromId ?? current.id) === source.id && current.state === "finalized") {
      return { messageId: card.id, plan: serializePlan(current) };
    }
    const now = new Date();
    await tx.update(plans).set({ state: "superseded", updatedAt: now, decidedAt: now }).where(and(
      eq(plans.stickerId, stickerId),
      inArray(plans.state, ["draft", "finalized"]),
    ));
    const restored = await tx.insert(plans).values({
      id: crypto.randomUUID(), ownerId, stickerId, threadId: current.threadId,
      messageId: card.id, planJson: source.planJson, revision: source.revision,
      conceptAssetId: source.conceptAssetId, restoredFromId: source.id,
      supersedesId: current.id, state: "finalized", createdAt: now, updatedAt: now,
    }).returning().then(firstRow);
    if (!restored) throw new Error("Failed to activate selected plan");
    const claimed = await tx.update(chatMessages).set({
      planId: restored.id, planRevision: restored.revision,
    }).where(and(eq(chatMessages.id, card.id), eq(chatMessages.planId, currentPlanId)))
      .returning({ id: chatMessages.id });
    if (claimed.length === 0) throw new ApiError(409, "PLAN_CHANGED", "The latest plan changed while selecting a version");
    await tx.update(stickers).set({ updatedAt: now }).where(eq(stickers.id, stickerId));
    return { messageId: card.id, plan: serializePlan(restored) };
  });
}

export async function loadPlansByIds(db: Database, planIds: string[]) {
  if (planIds.length === 0) return [];
  return db.select().from(plans).where(inArray(plans.id, planIds));
}

async function loadPlan(db: Database, ownerId: string, stickerId: string, planId: string) {
  const row = await db.select().from(plans).where(and(
    eq(plans.id, planId),
    eq(plans.ownerId, ownerId),
    eq(plans.stickerId, stickerId),
  )).then(firstRow);
  if (!row) throw new ApiError(404, "PLAN_NOT_FOUND", "Plan not found");
  return row;
}

/**
 * Whether a sticker has ever been planned.
 *
 * Deliberately counts every plan row, cancelled and superseded ones included. It gates the rule
 * that an animated project must be designed as layers before anything is drawn, and a user who
 * turned a plan down has already answered that question — re-forcing a plan on their next prompt
 * would trap them in a loop they cannot leave.
 */
export async function stickerHasPlan(db: Database, ownerId: string, stickerId: string) {
  const row = await db.select({ id: plans.id }).from(plans).where(and(
    eq(plans.ownerId, ownerId),
    eq(plans.stickerId, stickerId),
  )).then(firstRow);
  return Boolean(row);
}

/** A plan awaiting a user decision keeps subsequent chat in the planning flow. */
export async function currentPendingPlan(db: Database, ownerId: string, stickerId: string) {
  return db.select().from(plans).where(and(
    eq(plans.ownerId, ownerId),
    eq(plans.stickerId, stickerId),
    inArray(plans.state, ["draft", "finalized"]),
  )).orderBy(desc(plans.createdAt)).limit(1).then(firstRow);
}

/** The plan the agent is currently drafting for a sticker, if any. */
export async function currentDraftPlan(db: Database, ownerId: string, stickerId: string) {
  return db.select().from(plans).where(and(
    eq(plans.ownerId, ownerId),
    eq(plans.stickerId, stickerId),
    eq(plans.state, "draft"),
  )).orderBy(desc(plans.createdAt)).then(firstRow);
}

// --- agent-facing mutations ------------------------------------------------------------------
//
// These are what the `create_plan` / `update_plan` / `finalize_plan` tools call. They are ordinary
// service functions rather than tool bodies so the workflow step owns transcript side effects and
// these stay unit-testable.

export type CreatePlanResult = { planId: string; revision: number; supersededPlanId: string | null };

/**
 * Starts a new plan, superseding whatever came before it.
 *
 * A plan that has been finalized or confirmed is never mutated in place — the user may have already
 * approved it, and a confirmed plan has to keep describing what was actually built. So a fresh
 * draft is created and linked back through `supersedesId`, which is the "returns a new plan id"
 * case. Abandoned drafts are superseded the same way so only one draft is ever live.
 */
export async function createPlan(
  db: Database,
  input: {
    ownerId: string;
    stickerId: string;
    threadId: string;
    messageId: string;
    plan: PlanV1;
    planId?: string;
  },
): Promise<CreatePlanResult> {
  const plan = PlanV1Schema.parse(input.plan);
  const planId = input.planId ?? crypto.randomUUID();
  const now = new Date();

  return db.transaction(async (tx) => {
    const previous = await tx.select().from(plans).where(and(
      eq(plans.ownerId, input.ownerId),
      eq(plans.stickerId, input.stickerId),
      inArray(plans.state, ["draft", "finalized"]),
    )).orderBy(desc(plans.createdAt)).then(firstRow);

    if (previous) {
      await tx.update(plans).set({ state: "superseded", updatedAt: now, decidedAt: now })
        .where(and(eq(plans.id, previous.id), inArray(plans.state, ["draft", "finalized"])));
    }

    await tx.insert(plans).values({
      id: planId,
      ownerId: input.ownerId,
      stickerId: input.stickerId,
      threadId: input.threadId,
      messageId: input.messageId,
      planJson: plan,
      state: "draft",
      revision: 1,
      supersedesId: previous?.id ?? null,
      createdAt: now,
      updatedAt: now,
    }).onConflictDoNothing();

    return { planId, revision: 1, supersededPlanId: previous?.id ?? null };
  });
}

/** Rewrites a draft in place and bumps its revision. */
export async function updatePlan(
  db: Database,
  input: { ownerId: string; stickerId: string; planId: string; plan: PlanV1 },
): Promise<{ planId: string; revision: number }> {
  const plan = PlanV1Schema.parse(input.plan);
  const row = await loadPlan(db, input.ownerId, input.stickerId, input.planId);
  if (!isEditablePlanState(row.state)) {
    throw new ApiError(409, "PLAN_NOT_EDITABLE", `This plan is ${row.state} and can no longer be edited`);
  }
  const revision = row.revision + 1;
  // Guarded on the revision we read so two concurrent updates cannot both land on the same number.
  const claimed = await db.update(plans)
    .set({ planJson: plan, revision, updatedAt: new Date() })
    .where(and(eq(plans.id, row.id), eq(plans.state, "draft"), eq(plans.revision, row.revision)))
    .returning({ id: plans.id });
  if (claimed.length === 0) {
    throw new ApiError(409, "PLAN_NOT_EDITABLE", "This plan changed while it was being edited");
  }
  return { planId: row.id, revision };
}

/** Freezes a draft so the user can decide on it. */
export async function finalizePlan(
  db: Database,
  input: { ownerId: string; stickerId: string; planId: string },
): Promise<{ planId: string; revision: number; plan: PlanV1 }> {
  const row = await loadPlan(db, input.ownerId, input.stickerId, input.planId);
  if (row.state === "finalized") {
    return { planId: row.id, revision: row.revision, plan: PlanV1Schema.parse(row.planJson) };
  }
  if (!isEditablePlanState(row.state)) {
    throw new ApiError(409, "PLAN_NOT_EDITABLE", `This plan is ${row.state} and can no longer be finalized`);
  }
  const claimed = await db.update(plans).set({ state: "finalized", updatedAt: new Date() })
    .where(and(eq(plans.id, row.id), eq(plans.state, "draft")))
    .returning({ id: plans.id });
  if (claimed.length === 0) {
    throw new ApiError(409, "PLAN_NOT_EDITABLE", "This plan was already decided");
  }
  return { planId: row.id, revision: row.revision, plan: PlanV1Schema.parse(row.planJson) };
}

export async function attachPlanConcept(db: Database, planId: string, conceptAssetId: string) {
  await db.update(plans).set({ conceptAssetId, updatedAt: new Date() }).where(eq(plans.id, planId));
}

// --- user-facing decisions -------------------------------------------------------------------

/**
 * Starts generating a finalized plan.
 *
 * The plan itself is already persisted, so the request body carries nothing — confirming is a
 * bare "go" signal against server state, and re-confirming is rejected rather than silently
 * starting a second identical run.
 */
export async function confirmPlan(
  db: Database,
  ownerId: string,
  stickerId: string,
  planId: string,
) {
  const sticker = await db.select().from(stickers).where(and(
    eq(stickers.id, stickerId),
    eq(stickers.ownerId, ownerId),
  )).then(firstRow);
  if (!sticker || sticker.deletedAt) throw new ApiError(404, "STICKER_NOT_FOUND", "Sticker not found");
  if (sticker.status === "deleting") throw new ApiError(409, "STICKER_DELETING", "Sticker deletion is in progress");

  const row = await loadPlan(db, ownerId, stickerId, planId);
  if (row.state === "confirmed" && row.jobId) {
    throw new ApiError(409, "PLAN_ALREADY_CONFIRMED", "This plan is already generating");
  }
  if (!isActionablePlanState(row.state)) {
    throw new ApiError(409, "PLAN_NOT_ACTIONABLE", `This plan is ${row.state}`);
  }

  const plan = PlanV1Schema.parse(row.planJson);
  if (plan.kind !== sticker.kind) {
    throw new ApiError(422, "PLAN_KIND_MISMATCH", `This plan builds a ${plan.kind} sticker but the project is ${sticker.kind}`);
  }
  if (planRequiresConcept(plan)) {
    const reference = row.conceptAssetId
      ? await db.select({ id: assets.id }).from(assets).where(and(
        eq(assets.id, row.conceptAssetId),
        eq(assets.ownerId, ownerId),
        eq(assets.stickerId, stickerId),
        eq(assets.state, "ready"),
      )).then(firstRow)
      : undefined;
    if (!reference) {
      throw new ApiError(
        409,
        "PLAN_REFERENCE_REQUIRED",
        "Generate the plan's static visual reference before confirming it",
      );
    }
  }
  const jobId = crypto.randomUUID();
  // The confirmation is its own user turn rather than a reuse of the assistant's plan message.
  // That keeps the transcript honest, and it keeps `executeAiJobStep`'s "this job already has an
  // assistant message, so it is a replay" guard from matching the plan message itself.
  const messageId = crypto.randomUUID();
  const now = new Date();
  const generations = planGenerationCount(plan);
  const videos = planVideoCount(plan);
  const creditHold = composeCreditHold(plan);
  const reservationId = await holdCreditsForJob({
    ownerId,
    amount: creditHold,
    idempotencyKey: `reserve:${jobId}`,
    description: "Sticker plan build",
    metadata: { jobId, stickerId, kind: "compose", planId, generations, videos },
  });
  try {
    await db.transaction(async (tx) => {
      try {
        await tx.insert(generationJobs).values({
          id: jobId,
          ownerId,
          stickerId,
          sourceMessageId: messageId,
          kind: "compose",
          state: "queued",
          reservationId,
          billingEnvironment: await currentBillingEnvironment(),
          reservationAmount: reservationId ? creditHold : 0,
          createdAt: now,
          updatedAt: now,
        });
      } catch (error) {
        if (isActiveJobConstraint(error)) {
          throw new ApiError(409, "AI_TURN_IN_PROGRESS", "This sticker already has an active AI turn");
        }
        throw error;
      }
      const claimed = await tx.update(plans).set({ state: "confirmed", jobId, updatedAt: now, decidedAt: now })
        .where(and(eq(plans.id, planId), eq(plans.state, "finalized")))
        .returning({ id: plans.id });
      if (claimed.length === 0) {
        throw new ApiError(409, "PLAN_NOT_ACTIONABLE", "This plan was already decided");
      }
      const sequenceRow = await tx.select({ value: max(chatMessages.sequence) }).from(chatMessages)
        .where(eq(chatMessages.threadId, row.threadId)).then(firstRow);
      await tx.insert(chatMessages).values({
        id: messageId,
        threadId: row.threadId,
        ownerId,
        role: "user",
        kind: "text",
        content: generations > 0
          ? `Build this plan: ${plan.layers.length} layers, ${generations} to generate.`
          : `Build this plan: ${plan.layers.length} layers.`,
        sequence: (sequenceRow?.value ?? 0) + 1,
        jobId,
        status: "streaming",
        createdAt: now,
    });
    await tx.update(chatThreads).set({ updatedAt: now }).where(eq(chatThreads.id, row.threadId));
    await tx.update(stickers).set({ updatedAt: now }).where(eq(stickers.id, stickerId));
    await tx.insert(generationEvents).values({
      jobId,
      ownerId,
      type: "queued",
      dataJson: { intent: "compose", messageId, planId },
      createdAt: now,
    });
    });
  } catch (error) {
    await abandonHold(reservationId, jobId, "job_not_created");
    throw error;
  }
  return { messageId, jobId };
}

/**
 * Turns down a finalized plan.
 *
 * A bare dismissal ends there. A dismissal with a reason keeps the conversation going instead: the
 * reason becomes the user's next message and starts a planning turn on the spot, because "the
 * letters are too cramped" is a request for a better plan, and making the user retype it as a chat
 * message to get one is the kind of dead end that reads as the app ignoring them. The turn is a
 * `plan` job rather than a `chat` one so those words are never re-read as a request to redraw.
 */
export async function cancelPlan(
  db: Database,
  ownerId: string,
  stickerId: string,
  planId: string,
  reason?: string,
) {
  const row = await loadPlan(db, ownerId, stickerId, planId);
  if (!isActionablePlanState(row.state)) {
    throw new ApiError(409, "PLAN_NOT_ACTIONABLE", `This plan is ${row.state}`);
  }
  const trimmed = reason?.trim();
  const now = new Date();
  // Stored rather than discarded so the next planning turn can be told what the user turned down.
  const cancel = (tx: Pick<Database, "update">) => tx.update(plans)
    .set({ state: "cancelled", decisionReason: trimmed || null, updatedAt: now, decidedAt: now })
    .where(and(eq(plans.id, planId), eq(plans.state, "finalized")))
    .returning({ id: plans.id });

  if (!trimmed) {
    await cancel(db);
    return { planId, state: "cancelled" as const };
  }

  const sticker = await db.select().from(stickers).where(and(
    eq(stickers.id, stickerId),
    eq(stickers.ownerId, ownerId),
  )).then(firstRow);
  if (!sticker || sticker.deletedAt) throw new ApiError(404, "STICKER_NOT_FOUND", "Sticker not found");
  if (sticker.status === "deleting") throw new ApiError(409, "STICKER_DELETING", "Sticker deletion is in progress");

  const jobId = crypto.randomUUID();
  const messageId = crypto.randomUUID();
  // Planning is API-priced like every other text turn. The reservation is only
  // an estimate; the exact Gateway cost is settled after the turn succeeds.
  const creditHold = jobCreditHold("plan");
  const reservationId = await holdCreditsForJob({
    ownerId,
    amount: creditHold,
    idempotencyKey: `reserve:${jobId}`,
    description: "Sticker planning turn",
    metadata: { jobId, stickerId, kind: "plan", planId },
  });
  try {
    await db.transaction(async (tx) => {
      const claimed = await cancel(tx);
      if (claimed.length === 0) {
        throw new ApiError(409, "PLAN_NOT_ACTIONABLE", "This plan was already decided");
      }
      try {
        await tx.insert(generationJobs).values({
          id: jobId,
          ownerId,
          stickerId,
          sourceMessageId: messageId,
          kind: "plan",
          state: "queued",
          reservationId,
          billingEnvironment: await currentBillingEnvironment(),
          reservationAmount: reservationId ? creditHold : 0,
          createdAt: now,
          updatedAt: now,
        });
      } catch (error) {
        if (isActiveJobConstraint(error)) {
          throw new ApiError(409, "AI_TURN_IN_PROGRESS", "This sticker already has an active AI turn");
        }
        throw error;
      }
      const sequenceRow = await tx.select({ value: max(chatMessages.sequence) }).from(chatMessages)
        .where(eq(chatMessages.threadId, row.threadId)).then(firstRow);
      await tx.insert(chatMessages).values({
        id: messageId,
        threadId: row.threadId,
        ownerId,
        role: "user",
        kind: "text",
        // The reason verbatim: it is what the user typed, and the planning turn reads it as the
        // instruction for the next draft.
        content: trimmed,
        sequence: (sequenceRow?.value ?? 0) + 1,
        jobId,
        status: "streaming",
        createdAt: now,
    });
    await tx.update(chatThreads).set({ updatedAt: now }).where(eq(chatThreads.id, row.threadId));
    await tx.update(stickers).set({ updatedAt: now }).where(eq(stickers.id, stickerId));
    await tx.insert(generationEvents).values({
      jobId,
      ownerId,
      type: "queued",
      dataJson: { intent: "plan", messageId, planId },
      createdAt: now,
    });
    });
  } catch (error) {
    await abandonHold(reservationId, jobId, "job_not_created");
    throw error;
  }
  return { planId, state: "cancelled" as const, messageId, jobId };
}

/**
 * The most recent plan on this sticker that got as far as rendering a static reference.
 *
 * Read by the planning turn so a re-plan can be *shown* what the last one settled on rather than
 * only told about it in prose. Deliberately not filtered by state: a superseded, cancelled, or
 * confirmed plan's reference is still an accurate picture of what this project looked like a turn
 * ago, and that is the only question being asked of it.
 */
export async function latestPlanConcept(db: Database, ownerId: string, stickerId: string) {
  return db.select().from(plans).where(and(
    eq(plans.ownerId, ownerId),
    eq(plans.stickerId, stickerId),
    isNotNull(plans.conceptAssetId),
  )).orderBy(desc(plans.updatedAt)).limit(1).then(firstRow);
}

/** Plans the user turned down, newest first, for feeding back into the next planning turn. */
export async function recentlyRejectedPlans(db: Database, ownerId: string, stickerId: string, limit = 3) {
  return db.select().from(plans).where(and(
    eq(plans.ownerId, ownerId),
    eq(plans.stickerId, stickerId),
    eq(plans.state, "cancelled"),
    ne(plans.decisionReason, ""),
  )).orderBy(desc(plans.decidedAt)).limit(limit);
}
