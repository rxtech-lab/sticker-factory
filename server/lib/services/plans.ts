import { and, desc, eq, inArray, max, ne } from "drizzle-orm";
import {
  isActionablePlanState,
  isEditablePlanState,
  planGenerationCount,
  PlanV1Schema,
  type PlanState,
  type PlanV1,
} from "@/lib/contracts/plan";
import type { Database } from "@/lib/db/client";
import { chatMessages, chatThreads, generationEvents, generationJobs, plans, stickers } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { isActiveJobConstraint } from "@/lib/services/stickers";

export type SerializedPlan = {
  id: string;
  messageId: string;
  state: PlanState;
  revision: number;
  jobId: string | null;
  conceptAssetId: string | null;
  decisionReason: string | null;
  supersedesId: string | null;
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
    actionable: isActionablePlanState(row.state) && isCurrentRevision,
    generationCount: planGenerationCount(plan),
    plan,
  };
}

/** Every plan attached to a sticker's transcript, newest first. */
export async function listPlans(db: Database, ownerId: string, stickerId: string) {
  return db.select().from(plans).where(and(
    eq(plans.ownerId, ownerId),
    eq(plans.stickerId, stickerId),
  )).orderBy(desc(plans.createdAt));
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
  )).get();
  if (!row) throw new ApiError(404, "PLAN_NOT_FOUND", "Plan not found");
  return row;
}

/** The plan the agent is currently drafting for a sticker, if any. */
export async function currentDraftPlan(db: Database, ownerId: string, stickerId: string) {
  return db.select().from(plans).where(and(
    eq(plans.ownerId, ownerId),
    eq(plans.stickerId, stickerId),
    eq(plans.state, "draft"),
  )).orderBy(desc(plans.createdAt)).get();
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
    )).orderBy(desc(plans.createdAt)).get();

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
  )).get();
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
  const jobId = crypto.randomUUID();
  // The confirmation is its own user turn rather than a reuse of the assistant's plan message.
  // That keeps the transcript honest, and it keeps `executeAiJobStep`'s "this job already has an
  // assistant message, so it is a replay" guard from matching the plan message itself.
  const messageId = crypto.randomUUID();
  const now = new Date();
  const generations = planGenerationCount(plan);
  await db.transaction(async (tx) => {
    try {
      await tx.insert(generationJobs).values({
        id: jobId,
        ownerId,
        stickerId,
        sourceMessageId: messageId,
        kind: "compose",
        state: "queued",
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
      .where(eq(chatMessages.threadId, row.threadId)).get();
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
  )).get();
  if (!sticker || sticker.deletedAt) throw new ApiError(404, "STICKER_NOT_FOUND", "Sticker not found");
  if (sticker.status === "deleting") throw new ApiError(409, "STICKER_DELETING", "Sticker deletion is in progress");

  const jobId = crypto.randomUUID();
  const messageId = crypto.randomUUID();
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
      .where(eq(chatMessages.threadId, row.threadId)).get();
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
  return { planId, state: "cancelled" as const, messageId, jobId };
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
