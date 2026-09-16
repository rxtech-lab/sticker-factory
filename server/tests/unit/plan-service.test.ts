import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { PlanEditV1Schema, PlanV1Schema, type PlanV1 } from "@/lib/contracts/plan";
import { firstRow, type Database } from "@/lib/db/client";
import { assets, chatMessages, generationJobs, plans, users } from "@/lib/db/schema";
import {
  cancelPlan,
  confirmPlan,
  createPlan,
  editPlan,
  currentDraftPlan,
  finalizePlan,
  listPlans,
  recentlyRejectedPlans,
  serializePlan,
  selectPlanVersion,
  stickerHasPlan,
  updatePlan,
} from "@/lib/services/plans";
import { createChatTurn, createSticker } from "@/lib/services/stickers";
import { listChatMessages } from "@/lib/services/sticker-chat";
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

  /** Edits arrive over the wire, so tests state them the way the app does and let zod fill the rest. */
  const edit = (value: unknown) => PlanEditV1Schema.parse(value);

  const create = (value: PlanV1, planId?: string) =>
    createPlan(db, { ownerId: "owner-a", stickerId, threadId, messageId, plan: value, planId });

  /**
   * Ends the turn the fixture opened.
   *
   * A sticker may only have one active job, and in production the turn that drafted a plan has
   * always finished by the time the user can act on the card. Anything that starts a follow-up turn
   * has to be tested from that state rather than from mid-turn.
   */
  const settleFixtureTurn = () => db.update(generationJobs)
    .set({ state: "succeeded", completedAt: new Date() })
    .where(eq(generationJobs.stickerId, stickerId));

  async function readyHistory() {
    const first = await create(plan("Original", 1));
    await finalizePlan(db, { ownerId: "owner-a", stickerId, planId: first.planId });
    const second = await create(plan("Revised", 3));
    await finalizePlan(db, { ownerId: "owner-a", stickerId, planId: second.planId });
    for (const [index, version] of [first, second].entries()) {
      await db.insert(assets).values({
        id: `reference-${index}`, ownerId: "owner-a", stickerId, kind: "reference",
        state: "ready", r2Key: `reference-${index}`, mimeType: "image/png",
      });
      await db.update(plans).set({ conceptAssetId: `reference-${index}`, animationPreviewAssetId: `reference-${index}` }).where(eq(plans.id, version.planId));
      await db.insert(chatMessages).values({
        id: `plan-card-${index}`, ownerId: "owner-a", threadId, role: "assistant", kind: "plan",
        content: "Plan", sequence: index + 2, planId: version.planId, planRevision: version.revision,
      });
    }
    await settleFixtureTurn();
    return { first, second };
  }

  it("activates the older version in the latest card and builds its own plan and reference", async () => {
    const { first, second } = await readyHistory();
    const selected = await selectPlanVersion(db, "owner-a", stickerId, first.planId, second.planId, second.revision);
    expect(selected.messageId).toBe("plan-card-1");
    expect(selected.plan).toMatchObject({ sourceVersionId: first.planId, actionable: true, conceptAssetId: "reference-0", animationPreviewAssetId: "reference-0" });
    expect(selected.plan.id).not.toBe(first.planId);
    const transcript = await listChatMessages(db, "owner-a", stickerId);
    expect(transcript.data.find((message) => message.id === "plan-card-1")?.plan).toMatchObject({
      id: selected.plan.id, sourceVersionId: first.planId, actionable: true, plan: { title: "Original" },
    });
    expect(await listPlans(db, "owner-a", stickerId)).toHaveLength(2);
    const build = await confirmPlan(db, "owner-a", stickerId, selected.plan.id);
    const built = await db.select().from(plans).where(eq(plans.jobId, build.jobId)).then(firstRow);
    expect(built).toMatchObject({ id: selected.plan.id, conceptAssetId: "reference-0", planJson: { title: "Original" } });
    expect(built?.planJson.layers).toHaveLength(1);
    await expect(confirmPlan(db, "owner-a", stickerId, selected.plan.id))
      .rejects.toMatchObject({ code: "PLAN_ALREADY_CONFIRMED" });
  });

  it("preserves a previously confirmed version and its build when restoring and rejecting it", async () => {
    const { first, second } = await readyHistory();
    await db.insert(generationJobs).values({
      id: "previous-build", ownerId: "owner-a", stickerId, kind: "compose", state: "succeeded",
    });
    await db.update(plans).set({ state: "confirmed", jobId: "previous-build" }).where(eq(plans.id, first.planId));
    const selected = await selectPlanVersion(db, "owner-a", stickerId, first.planId, second.planId, second.revision);
    await cancelPlan(db, "owner-a", stickerId, selected.plan.id);
    expect(await db.select().from(plans).where(eq(plans.id, first.planId)).then(firstRow))
      .toMatchObject({ state: "confirmed", jobId: "previous-build", conceptAssetId: "reference-0" });
    const newer = await selectPlanVersion(db, "owner-a", stickerId, second.planId, selected.plan.id, selected.plan.revision);
    expect(newer.plan).toMatchObject({ sourceVersionId: second.planId, actionable: true, plan: { title: "Revised" } });
    expect(await listPlans(db, "owner-a", stickerId)).toHaveLength(2);
  });

  it("rejects stale or unauthorized selections and makes selecting the current active version a no-op", async () => {
    const { first, second } = await readyHistory();
    const noChange = await selectPlanVersion(db, "owner-a", stickerId, second.planId, second.planId, second.revision);
    expect(noChange.plan.id).toBe(second.planId);
    await expect(selectPlanVersion(db, "owner-a", stickerId, first.planId, second.planId, second.revision + 1))
      .rejects.toMatchObject({ code: "PLAN_CHANGED" });
    await expect(selectPlanVersion(db, "owner-b", stickerId, first.planId, second.planId, second.revision))
      .rejects.toMatchObject({ code: "STICKER_NOT_FOUND" });
    const restored = await selectPlanVersion(db, "owner-a", stickerId, first.planId, second.planId, second.revision);
    await expect(selectPlanVersion(db, "owner-a", stickerId, second.planId, second.planId, second.revision))
      .rejects.toMatchObject({ code: "PLAN_CHANGED" });
    expect((await selectPlanVersion(db, "owner-a", stickerId, first.planId, restored.plan.id, restored.plan.revision)).plan.id)
      .toBe(restored.plan.id);
  });

  it("does not switch plans while a generation is active", async () => {
    const { first, second } = await readyHistory();
    await db.insert(generationJobs).values({ id: "active-build", ownerId: "owner-a", stickerId, kind: "compose", state: "queued" });
    await expect(selectPlanVersion(db, "owner-a", stickerId, first.planId, second.planId, second.revision))
      .rejects.toMatchObject({ code: "AI_TURN_IN_PROGRESS" });
    expect((await db.select().from(chatMessages).where(eq(chatMessages.id, "plan-card-1")).then(firstRow))?.planId)
      .toBe(second.planId);
  });

  it("saves a user edit as a new version and leaves the one it started from restorable", async () => {
    const { first, second } = await readyHistory();
    const edited = await editPlan(db, "owner-a", stickerId, second.planId, edit({
      layers: [
        { from: "part_0", name: "Head", source: { kind: "generate", prompt: "A rounder head" } },
        { from: "part_2" },
      ],
      timing: { durationSeconds: 3 },
    }), second.revision);

    expect(edited.messageId).toBe("plan-card-1");
    expect(edited.plan.id).not.toBe(second.planId);
    expect(edited.plan).toMatchObject({ actionable: true, sourceVersionId: null, conceptAssetId: "reference-1", animationPreviewAssetId: null });
    expect(edited.plan.plan.layers.map((layer) => layer.layerId)).toEqual(["part_0", "part_2"]);
    expect(edited.plan.plan.layers[0]).toMatchObject({ name: "Head", source: { kind: "generate", prompt: "A rounder head" } });
    // Untouched geometry survives an edit that never mentioned it.
    expect(edited.plan.plan.layers[1]).toMatchObject({ name: "Part 2", x: 5 / 6 });
    expect(edited.plan.plan.timing.durationSeconds).toBe(3);

    const history = (await listPlans(db, "owner-a", stickerId)).reverse();
    expect(history.map((row) => row.id)).toEqual([first.planId, second.planId, edited.plan.id]);
    expect(history[1].planJson.layers).toHaveLength(3);
    const back = await selectPlanVersion(db, "owner-a", stickerId, second.planId, edited.plan.id, edited.plan.revision);
    expect(back.plan.plan.layers).toHaveLength(3);
  });

  it("keeps parameters the editor cannot express and applies the ones it can", async () => {
    const animated = PlanV1Schema.parse({
      ...plan("Motion", 1),
      layers: [{
        layerId: "part_0", name: "Part 0", source: { kind: "generate", prompt: "Element 0" },
        x: 0.5, y: 0.5, scaleX: 0.4, scaleY: 0.4,
        animations: [{ type: "spin", turns: 2, direction: "ccw", delay: 0.1, duration: 0.5 }],
      }],
    });
    const created = await create(animated);
    await finalizePlan(db, { ownerId: "owner-a", stickerId, planId: created.planId });
    await db.insert(assets).values({
      id: "motion-reference", ownerId: "owner-a", stickerId, kind: "reference",
      state: "ready", r2Key: "motion-reference", mimeType: "image/png",
    });
    await db.update(plans).set({ conceptAssetId: "motion-reference" }).where(eq(plans.id, created.planId));
    await db.insert(chatMessages).values({
      id: "plan-card", ownerId: "owner-a", threadId, role: "assistant", kind: "plan",
      content: "Plan", sequence: 2, planId: created.planId, planRevision: created.revision,
    });
    await settleFixtureTurn();

    const edited = await editPlan(db, "owner-a", stickerId, created.planId, edit({
      layers: [
        { from: "part_0", animations: [{ from: 0, delay: 0.4 }, { spec: { type: "slideIn", direction: "up" } }] },
        { layerId: "sparkles", name: "Sparkles", source: { kind: "generate", prompt: "Tiny sparkles" }, x: 0.2, y: 0.2 },
      ],
    }), created.revision);

    const [kept, added] = edited.plan.plan.layers;
    // The spec the picker has no field for is carried over whole, retimed but not rewritten.
    expect(kept.animations[0]).toMatchObject({ type: "spin", turns: 2, direction: "ccw", delay: 0.4, duration: 0.5 });
    expect(kept.animations[1]).toMatchObject({ type: "slideIn", direction: "up", delay: 0, duration: 0.5, distance: 0.3 });
    expect(added).toMatchObject({ layerId: "sparkles", scaleX: 0.4, source: { kind: "generate" } });
    expect(edited.plan.generationCount).toBe(2);
  });

  it("says in the summary when an edit turns a layer into a video clip", async () => {
    const { second } = await readyHistory();
    const edited = await editPlan(db, "owner-a", stickerId, second.planId, edit({
      layers: [
        { from: "part_0", source: { kind: "video", prompt: "The whole character", motion: "slow turntable" } },
        { from: "part_1" },
        { from: "part_2" },
      ],
    }), second.revision);
    expect(edited.plan.plan.summary).toMatch(/video/i);
    expect(edited.plan.plan.layers[0].source).toMatchObject({ kind: "video", durationSeconds: 3 });
  });

  it("refuses an edit against a stale revision, a decided plan, or an unknown layer", async () => {
    const { second } = await readyHistory();
    await expect(editPlan(db, "owner-a", stickerId, second.planId, edit({ title: "Nope" }), second.revision + 1))
      .rejects.toMatchObject({ code: "PLAN_CHANGED" });
    await expect(editPlan(db, "owner-a", stickerId, second.planId, edit({ layers: [{ from: "ghost" }] }), second.revision))
      .rejects.toMatchObject({ code: "PLAN_EDIT_INVALID" });
    // An edit that changes nothing is answered with the plan as it stands, not a duplicate version.
    const unchanged = await editPlan(db, "owner-a", stickerId, second.planId, edit({}), second.revision);
    expect(unchanged.plan.id).toBe(second.planId);
    expect(await listPlans(db, "owner-a", stickerId)).toHaveLength(2);

    await cancelPlan(db, "owner-a", stickerId, second.planId);
    await expect(editPlan(db, "owner-a", stickerId, second.planId, edit({ title: "Too late" }), second.revision))
      .rejects.toMatchObject({ code: "PLAN_NOT_ACTIONABLE" });
  });

  it("creates a draft at revision 1", async () => {
    const created = await create(plan("First"));
    expect(created.revision).toBe(1);
    expect(created.supersededPlanId).toBeNull();
    const row = await db.select().from(plans).where(eq(plans.id, created.planId)).then(firstRow);
    expect(row?.state).toBe("draft");
  });

  it("lists saved plan versions with their own contents only for their owner", async () => {
    const first = await create(plan("Original"));
    await finalizePlan(db, { ownerId: "owner-a", stickerId, planId: first.planId });
    const second = await create(plan("Revised", 3));
    await finalizePlan(db, { ownerId: "owner-a", stickerId, planId: second.planId });

    const history = (await listPlans(db, "owner-a", stickerId)).reverse().map((row) => serializePlan(row));
    expect(history.map((entry) => entry.id)).toEqual([first.planId, second.planId]);
    expect(history.map((entry) => entry.plan.title)).toEqual(["Original", "Revised"]);
    expect(history.map((entry) => entry.plan.layers.length)).toEqual([2, 3]);
    expect(history.map((entry) => entry.actionable)).toEqual([false, true]);
    expect(await listPlans(db, "another-owner", stickerId)).toEqual([]);
  });

  it("bumps the revision on every update without changing the plan id", async () => {
    const created = await create(plan("First"));
    const second = await updatePlan(db, { ownerId: "owner-a", stickerId, planId: created.planId, plan: plan("Second") });
    const third = await updatePlan(db, { ownerId: "owner-a", stickerId, planId: created.planId, plan: plan("Third", 3) });
    expect([second.revision, third.revision]).toEqual([2, 3]);
    expect(third.planId).toBe(created.planId);
    const row = await db.select().from(plans).where(eq(plans.id, created.planId)).then(firstRow);
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

  it("leaves an identical replay completely alone, so its reference image stays cached", async () => {
    // The concept asset id is derived from the plan's own wording, so touching the revision here
    // would be free but touching the plan would not: a redraft that says the same thing must not
    // send the turn back to the image model for a picture it has already paid for.
    const planId = "11111111-1111-4111-8111-111111111111";
    await create(plan("First"), planId);
    const before = await db.select().from(plans).where(eq(plans.id, planId)).then(firstRow);
    const replay = await create(plan("First"), planId);
    expect(replay.revision).toBe(1);
    expect(await db.select().from(plans).where(eq(plans.id, planId)).then(firstRow)).toEqual(before);
  });

  it("leaves a replayed draft editable rather than superseding it against itself", async () => {
    // What a retried workflow step does: the plan id is derived from the job, so the second attempt
    // asks to create the row the first one left behind. Superseding it there killed the turn, and
    // the project was then left planned but with no live plan to revise.
    const planId = "11111111-1111-4111-8111-111111111111";
    const first = await create(plan("First"), planId);
    await updatePlan(db, { ownerId: "owner-a", stickerId, planId, plan: plan("Third") });
    const replay = await create(plan("Second"), planId);
    expect(replay.supersededPlanId).toBeNull();
    const row = await db.select().from(plans).where(eq(plans.id, planId)).then(firstRow);
    expect(row?.state).toBe("draft");
    // The attempt that is running now owns the draft, and its revision moves on so nothing rendered
    // for the abandoned one is reused.
    expect(PlanV1Schema.parse(row?.planJson).title).toBe("Second");
    expect(replay.revision).toBe(3);
    await expect(finalizePlan(db, { ownerId: "owner-a", stickerId, planId: first.planId }))
      .resolves.toMatchObject({ planId });
  });

  it("does not count a retired plan as a project that has been planned", async () => {
    // `mustPlanFirst` in the turn router asks this question, and answering yes on the strength of a
    // superseded row alone is what lets an animated project be drawn as one flat image. A supersede
    // always writes its replacement, so a live plan still answers yes.
    const first = await create(plan("First"));
    expect(await stickerHasPlan(db, "owner-a", stickerId)).toBe(true);
    const second = await create(plan("Second"));
    expect(second.supersededPlanId).toBe(first.planId);
    expect(await stickerHasPlan(db, "owner-a", stickerId)).toBe(true);
    await db.update(plans).set({ state: "superseded" }).where(eq(plans.id, second.planId));
    expect(await stickerHasPlan(db, "owner-a", stickerId)).toBe(false);
  });

  it("records a rejection reason and redrafts against it", async () => {
    const created = await create(plan("First"));
    await finalizePlan(db, { ownerId: "owner-a", stickerId, planId: created.planId });
    await settleFixtureTurn();
    const cancelled = await cancelPlan(db, "owner-a", stickerId, created.planId, "  The letters overlap  ");
    const rejected = await recentlyRejectedPlans(db, "owner-a", stickerId);
    expect(rejected.map((row) => row.decisionReason)).toEqual(["The letters overlap"]);

    // The reason is not just filed away: it becomes the user's next message and starts a planning
    // turn, so the agent answers a rejection with a better plan instead of nothing at all.
    expect(cancelled.jobId).toBeTruthy();
    const job = await db.select().from(generationJobs).where(eq(generationJobs.id, cancelled.jobId!)).then(firstRow);
    expect(job).toMatchObject({ kind: "plan", state: "queued", sourceMessageId: cancelled.messageId });
    const message = await db.select().from(chatMessages).where(eq(chatMessages.id, cancelled.messageId!)).then(firstRow);
    expect(message).toMatchObject({ role: "user", content: "The letters overlap", status: "streaming" });
  });

  it("dismisses without a reason and starts nothing", async () => {
    const created = await create(plan("First"));
    await finalizePlan(db, { ownerId: "owner-a", stickerId, planId: created.planId });
    await settleFixtureTurn();
    const cancelled = await cancelPlan(db, "owner-a", stickerId, created.planId);
    expect(cancelled).toEqual({ planId: created.planId, state: "cancelled" });
    expect(await db.select().from(generationJobs).where(eq(generationJobs.kind, "plan"))).toHaveLength(0);
  });

  it("refuses to redraft while another turn is still running", async () => {
    const created = await create(plan("First"));
    await finalizePlan(db, { ownerId: "owner-a", stickerId, planId: created.planId });
    // The fixture turn is deliberately left active here.
    await expect(cancelPlan(db, "owner-a", stickerId, created.planId, "Too cramped"))
      .rejects.toMatchObject({ code: "AI_TURN_IN_PROGRESS" });
    // And the plan is untouched, so the user can try again rather than losing the card.
    expect((await db.select().from(plans).where(eq(plans.id, created.planId)).then(firstRow))?.state).toBe("finalized");
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
    const row = (await db.select().from(plans).where(eq(plans.id, created.planId)).then(firstRow))!;

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
    const row = (await db.select().from(plans).where(eq(plans.id, created.planId)).then(firstRow))!;
    expect(serializePlan(row).generationCount).toBe(1);
  });

  it("refuses to confirm an animated plan before its static reference exists", async () => {
    const created = await create(plan("Needs reference"));
    await finalizePlan(db, { ownerId: "owner-a", stickerId, planId: created.planId });
    await settleFixtureTurn();

    await expect(confirmPlan(db, "owner-a", stickerId, created.planId))
      .rejects.toMatchObject({ code: "PLAN_REFERENCE_REQUIRED" });
    expect((await db.select().from(plans).where(eq(plans.id, created.planId)).then(firstRow))?.state)
      .toBe("finalized");
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
