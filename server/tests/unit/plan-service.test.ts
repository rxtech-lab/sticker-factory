import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { PlanV1Schema, type PlanV1 } from "@/lib/contracts/plan";
import type { Database } from "@/lib/db/client";
import { plans, users } from "@/lib/db/schema";
import {
  cancelPlan,
  confirmPlan,
  createPlan,
  currentDraftPlan,
  finalizePlan,
  recentlyRejectedPlans,
  serializePlan,
  updatePlan,
} from "@/lib/services/plans";
import { createChatTurn, createSticker } from "@/lib/services/stickers";
import { createTestDatabase } from "@/tests/helpers/database";

function plan(title: string, layerCount = 2): PlanV1 {
  return PlanV1Schema.parse({
    version: 1,
    title,
    summary: `${title} summary.`,
    kind: "animated",
    timing: { durationSeconds: 2, fps: 30, loop: "loop" },
    layers: Array.from({ length: layerCount }, (_, index) => ({
      layerId: `part_${index}`,
      name: `Part ${index}`,
      source: { kind: "generate", prompt: `Element ${index}` },
      x: (index + 0.5) / layerCount,
      y: 0.5,
      scaleX: 0.4,
      scaleY: 0.4,
    })),
  });
}

describe("plan service", () => {
  let db: Database;
  let close: () => Promise<void>;
  let stickerId: string;
  let threadId: string;
  let messageId: string;

  beforeEach(async () => {
    ({ db, close } = await createTestDatabase());
    await db.insert(users).values({ id: "owner-a", createdAt: new Date(), updatedAt: new Date() });
    const sticker = await createSticker(db, "owner-a", {
      title: "HI", kind: "animated", prompt: "HI", referenceAssetIds: [],
    });
    stickerId = sticker.stickerId;
    threadId = sticker.threadId;
    // A plan is anchored to a real message, so the turn that asked for it stands in here.
    const turn = await createChatTurn(db, "owner-a", stickerId, {
      text: "Plan it", intent: "chat", attachments: [], imagePlacement: "replace",
    });
    messageId = turn.messageId;
  });

  afterEach(async () => { await close(); });

  const create = (value: PlanV1, planId?: string) =>
    createPlan(db, { ownerId: "owner-a", stickerId, threadId, messageId, plan: value, planId });

  it("creates a draft at revision 1", async () => {
    const created = await create(plan("First"));
    expect(created.revision).toBe(1);
    expect(created.supersededPlanId).toBeNull();
    const row = await db.select().from(plans).where(eq(plans.id, created.planId)).get();
    expect(row?.state).toBe("draft");
  });

  it("bumps the revision on every update without changing the plan id", async () => {
    const created = await create(plan("First"));
    const second = await updatePlan(db, { ownerId: "owner-a", stickerId, planId: created.planId, plan: plan("Second") });
    const third = await updatePlan(db, { ownerId: "owner-a", stickerId, planId: created.planId, plan: plan("Third", 3) });
    expect([second.revision, third.revision]).toEqual([2, 3]);
    expect(third.planId).toBe(created.planId);
    const row = await db.select().from(plans).where(eq(plans.id, created.planId)).get();
    expect(row?.planJson.title).toBe("Third");
    expect(row?.planJson.layers).toHaveLength(3);
  });

  it("refuses to edit a plan once it is finalized", async () => {
    const created = await create(plan("First"));
    await finalizePlan(db, { ownerId: "owner-a", stickerId, planId: created.planId });
    await expect(updatePlan(db, { ownerId: "owner-a", stickerId, planId: created.planId, plan: plan("Nope") }))
      .rejects.toMatchObject({ code: "PLAN_NOT_EDITABLE" });
  });

  it("treats finalizing twice as a no-op rather than an error", async () => {
    const created = await create(plan("First"));
    const first = await finalizePlan(db, { ownerId: "owner-a", stickerId, planId: created.planId });
    const again = await finalizePlan(db, { ownerId: "owner-a", stickerId, planId: created.planId });
    expect(again.planId).toBe(first.planId);
    expect(again.revision).toBe(first.revision);
  });

  it("returns a NEW plan id when one already exists, superseding the old one", async () => {
    const first = await create(plan("First"));
    await finalizePlan(db, { ownerId: "owner-a", stickerId, planId: first.planId });

    const second = await create(plan("Second"));
    expect(second.planId).not.toBe(first.planId);
    expect(second.supersededPlanId).toBe(first.planId);
    expect(second.revision).toBe(1);

    const rows = await db.select().from(plans).where(eq(plans.stickerId, stickerId));
    expect(rows).toHaveLength(2);
    expect(rows.find((row) => row.id === first.planId)?.state).toBe("superseded");
    expect(rows.find((row) => row.id === second.planId)?.state).toBe("draft");
    expect(rows.find((row) => row.id === second.planId)?.supersedesId).toBe(first.planId);
  });

  it("supersedes an abandoned draft too, so only one draft is ever live", async () => {
    const first = await create(plan("First"));
    const second = await create(plan("Second"));
    expect(second.supersededPlanId).toBe(first.planId);
    const draft = await currentDraftPlan(db, "owner-a", stickerId);
    expect(draft?.id).toBe(second.planId);
  });

  it("is idempotent when the same derived plan id is replayed", async () => {
    // A workflow step retry must reuse the row rather than stack a second draft.
    const planId = "11111111-1111-4111-8111-111111111111";
    const first = await create(plan("First"), planId);
    const replay = await create(plan("First"), planId);
    expect(replay.planId).toBe(first.planId);
    expect(await db.select().from(plans).where(eq(plans.stickerId, stickerId))).toHaveLength(1);
  });

  it("records a rejection reason and feeds it back", async () => {
    const created = await create(plan("First"));
    await finalizePlan(db, { ownerId: "owner-a", stickerId, planId: created.planId });
    await cancelPlan(db, "owner-a", stickerId, created.planId, "  The letters overlap  ");
    const rejected = await recentlyRejectedPlans(db, "owner-a", stickerId);
    expect(rejected.map((row) => row.decisionReason)).toEqual(["The letters overlap"]);
  });

  it("cannot cancel a plan that is still a draft", async () => {
    const created = await create(plan("First"));
    await expect(cancelPlan(db, "owner-a", stickerId, created.planId))
      .rejects.toMatchObject({ code: "PLAN_NOT_ACTIONABLE" });
  });

  it("marks a card stale once the draft moves past the revision it rendered", async () => {
    const created = await create(plan("First"));
    await updatePlan(db, { ownerId: "owner-a", stickerId, planId: created.planId, plan: plan("Second") });
    await finalizePlan(db, { ownerId: "owner-a", stickerId, planId: created.planId });
    const row = (await db.select().from(plans).where(eq(plans.id, created.planId)).get())!;

    expect(serializePlan(row, { atRevision: 2 }).actionable).toBe(true);
    // A card posted when the draft was at revision 1 must not offer a live Generate button.
    expect(serializePlan(row, { atRevision: 1 }).actionable).toBe(false);
  });

  it("reports how many image generations a plan will cost", async () => {
    const mixed = PlanV1Schema.parse({
      ...plan("Mixed"),
      layers: [
        { layerId: "a", name: "A", source: { kind: "generate", prompt: "A cat" }, x: 0.3, y: 0.5, scaleX: 0.4, scaleY: 0.4 },
        { layerId: "b", name: "B", source: { kind: "text", text: "HI", color: "#FF00AA" }, x: 0.7, y: 0.5, scaleX: 0.4, scaleY: 0.4 },
      ],
    });
    const created = await create(mixed);
    const row = (await db.select().from(plans).where(eq(plans.id, created.planId)).get())!;
    expect(serializePlan(row).generationCount).toBe(1);
  });

  it("rejects confirming a plan whose kind does not match the project", async () => {
    const staticSticker = await createSticker(db, "owner-a", {
      title: "Flat", kind: "static", prompt: "Flat", referenceAssetIds: [],
    });
    const turn = await createChatTurn(db, "owner-a", staticSticker.stickerId, {
      text: "Plan it", intent: "chat", attachments: [], imagePlacement: "replace",
    });
    const created = await createPlan(db, {
      ownerId: "owner-a",
      stickerId: staticSticker.stickerId,
      threadId: staticSticker.threadId,
      messageId: turn.messageId,
      // An animated plan on a static project: the schema allows the plan, the confirm must not.
      plan: plan("Animated"),
    });
    await finalizePlan(db, { ownerId: "owner-a", stickerId: staticSticker.stickerId, planId: created.planId });
    await expect(confirmPlan(db, "owner-a", staticSticker.stickerId, created.planId))
      .rejects.toMatchObject({ code: "PLAN_KIND_MISMATCH" });
  });
});
