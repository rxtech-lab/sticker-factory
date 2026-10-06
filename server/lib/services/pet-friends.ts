// The pet making friends on its own: now and then, on a visit from its life workflow, it meets
// someone new — a creature that grows out of the weather, where its owner is, what it remembers and
// how it feels — and that friend becomes a new controllable sticker in the owner's library.
//
// The pet's agent writes who the friend is; then, like growing, it all happens without the owner in
// the loop: a new sticker is planned, the plan confirmed, built and published, and the pet tells its
// owner it met a new friend. The app welcomes each ready friend once, full screen. Each stage is a
// durable step of `workflows/pet-friend`; the logic and the tests live here.
//
// Friends are free to the owner (the jobs carry no credit hold and spend no daily allowance), so they
// are rare: a small chance on a visit, held to one per cooldown, and one being made at a time.

import { and, desc, eq, inArray, isNull, notInArray } from "drizzle-orm";
import { start } from "workflow/api";
import { getAiProvider } from "@/lib/ai/gateway";
import { firstRow, type Database } from "@/lib/db/client";
import { chatMessages, generationJobs, petFriends, plans, stickers, type PetFriendRow, type PetFriendState } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { notifyPetFriend } from "@/lib/notifications/pet";
import { describeError } from "@/lib/observability/trace";
import { petLog, petRandom } from "@/lib/pets/log";
import { personalizeEffects } from "@/lib/pets/stats";
import { petFriendWorkflow } from "@/workflows/pet-friend";
import { ownerMoment } from "./pet-actions";
import { recallPetMemories } from "./pet-memory";
import { commitPetChange, currentStats, petRow } from "./pet-state";
import { confirmPlan } from "./plans";
import { quickPublishSticker } from "./quick-publish";
import { createChatTurn } from "./sticker-chat";
import { createSticker } from "./stickers";
import { acceptRevision } from "./sticker-revisions";
import { selectStickerSummaries, serializeStickerSummary } from "./sticker-summaries";
import { startGenerationWorkflow } from "./workflows";

/** What a new friend does to the pet: joy, and the effort of an afternoon's play. */
const FRIEND_EFFECTS = { happiness: 8, hp: 0, energy: -3 };

/** How many earlier friends the agent is shown, so each new one is someone new. */
const PREVIOUS_FRIENDS = 10;

const ACTIVE_STATES: PetFriendState[] = ["planning", "building", "publishing"];

function friendsEnabled(): boolean {
  return process.env.PET_FRIENDS_ENABLED !== "false";
}

/** The chance a visit brings a friend, 0–1. `PET_FRIEND_CHANCE=1` makes every visit one, for debugging. */
function friendChance(): number {
  const chance = Number(process.env.PET_FRIEND_CHANCE ?? 0.05);
  return Number.isFinite(chance) ? Math.min(1, Math.max(0, chance)) : 0.05;
}

function cooldownMs(): number {
  const hours = Number(process.env.PET_FRIEND_COOLDOWN_HOURS ?? 48);
  return (Number.isFinite(hours) && hours >= 0 ? hours : 48) * 60 * 60 * 1000;
}

type FriendStarter = (userId: string, friendId: string) => Promise<string>;
let starterForTests: FriendStarter | undefined;

/** Tests run no workflow runtime; they install a starter to see what would have been started. */
export function setPetFriendStarterForTests(starter: FriendStarter | undefined): void {
  starterForTests = starter;
}

/**
 * Maybe the pet meets someone on this visit: a roll of the dice, then the cooldown, then its agent
 * decides who. Returns the friend it started making, or null. Never throws: a visit without a friend
 * is an ordinary visit.
 */
export async function maybeMeetPetFriend(
  db: Database,
  userId: string,
  options: { now?: Date; happening?: string; force?: boolean } = {},
): Promise<PetFriendRow | null> {
  const now = options.now ?? new Date();
  try {
    if (!friendsEnabled()) return null;
    if (!options.force && petRandom() >= friendChance()) return null;
    const pet = await petRow(db, userId);
    if (!pet?.lifeId) return null;
    const earlier = await db.select({ name: petFriends.name, state: petFriends.state, createdAt: petFriends.createdAt })
      .from(petFriends).where(eq(petFriends.userId, userId))
      .orderBy(desc(petFriends.createdAt)).limit(PREVIOUS_FRIENDS);
    if (earlier.some((friend) => ACTIVE_STATES.includes(friend.state))) return null;
    if (!options.force && earlier[0] && now.getTime() - earlier[0].createdAt.getTime() < cooldownMs()) return null;

    const petTitle = (await db.select({ title: stickers.title }).from(stickers)
      .where(eq(stickers.id, pet.stickerId)).then(firstRow))?.title ?? "Pet";
    const mood = pet.statusJson?.caption ?? null;
    const written = await getAiProvider().meetPetFriend({
      petTitle,
      identity: pet.identityJson,
      signals: pet.signalsJson,
      stats: currentStats(pet),
      mood,
      happening: options.happening ?? null,
      previous: earlier.filter((friend) => friend.state === "ready").map((friend) => friend.name),
      ...ownerMoment(pet.contextJson, now),
      memories: await recallPetMemories(db, userId, pet.lifeId,
        [options.happening, mood, "friends, places and things we love"].filter(Boolean).join(". ")),
    });
    // The active index holds a second friend out while one is being made, whatever raced here.
    const [inserted] = await db.insert(petFriends).values({
      id: crypto.randomUUID(),
      userId,
      lifeId: pet.lifeId,
      name: written.name.slice(0, 40),
      brief: written.brief.slice(0, 600),
      story: written.story.slice(0, 160),
      greeting: written.greeting.slice(0, 80),
      state: "planning",
      createdAt: now,
    }).onConflictDoNothing().returning();
    if (!inserted) return null;
    let runId: string;
    if (starterForTests) runId = await starterForTests(userId, inserted.id);
    else if (process.env.NODE_ENV === "test") runId = "test-skipped";
    else runId = (await start(petFriendWorkflow, [userId, inserted.id])).runId;
    petLog("friend:started", { userId, friendId: inserted.id, name: inserted.name, runId });
    return inserted;
  } catch (error) {
    petLog("friend:start-failed", { userId, error: describeError(error) });
    return null;
  }
}

/** The friend's row, only while it is still being made; otherwise the run has nothing to do. */
async function friendInProgress(db: Database, userId: string, friendId: string): Promise<PetFriendRow | undefined> {
  return db.select().from(petFriends)
    .where(and(eq(petFriends.id, friendId), eq(petFriends.userId, userId), inArray(petFriends.state, ACTIVE_STATES)))
    .then(firstRow);
}

async function updateFriend(db: Database, friendId: string, patch: Partial<PetFriendRow>): Promise<void> {
  await db.update(petFriends).set(patch).where(eq(petFriends.id, friendId));
}

/**
 * The brief as the planner reads it: who the friend is, and that it must be a character the owner
 * can pose — moods and poses on controls — like the pet itself.
 */
export function friendPlanningInstruction(friend: Pick<PetFriendRow, "name" | "brief">): string {
  return [
    `My pet just made a new friend called ${friend.name}. Draw them as their own sticker: ${friend.brief}`,
    "Make it one controllable character on a transparent background, cute and cartoonish, fully on the canvas,",
    "with a mood control (at least happy, shy and sleepy) and a pose control (at least waving hello, idle and",
    "playing), each pose with a gentle loop of its own. No text, no scenery, no other characters.",
  ].join(" ");
}

/**
 * Stage one: a new controllable sticker for the friend, and a planning turn on it. Returns the
 * planning job. A replayed step finds the sticker and the job its first attempt made.
 */
export async function beginPetFriendPlan(db: Database, userId: string, friendId: string): Promise<string | null> {
  const friend = await friendInProgress(db, userId, friendId);
  if (!friend) return null;
  if (friend.planJobId) return friend.planJobId;
  let stickerId = friend.stickerId;
  if (!stickerId) {
    ({ stickerId } = await createSticker(db, userId, {
      title: friend.name,
      kind: "animated",
      prompt: friendPlanningInstruction(friend),
      referenceAssetIds: [],
      controllable: true,
      posePreset: "medium",
      motion: false,
    }));
    await updateFriend(db, friendId, { stickerId });
  }
  let jobId: string;
  try {
    ({ jobId } = await createChatTurn(db, userId, stickerId, {
      text: friendPlanningInstruction(friend),
      intent: "generate",
      attachments: [],
      imagePlacement: "replace",
    }, false, true, "pet"));
  } catch (error) {
    // The first attempt queued the job and died before saying so. Anything else is a real refusal.
    if (!(error instanceof ApiError && error.code === "AI_TURN_IN_PROGRESS")) throw error;
    const running = await db.select({ id: generationJobs.id }).from(generationJobs)
      .where(and(eq(generationJobs.stickerId, stickerId), eq(generationJobs.origin, "pet"),
        eq(generationJobs.kind, "plan"), inArray(generationJobs.state, ["queued", "running", "waiting"])))
      .orderBy(desc(generationJobs.createdAt)).limit(1).then(firstRow);
    if (!running) throw error;
    jobId = running.id;
  }
  await updateFriend(db, friendId, { planJobId: jobId });
  if (!(await db.select({ runId: generationJobs.workflowRunId }).from(generationJobs)
    .where(eq(generationJobs.id, jobId)).then(firstRow))?.runId) {
    await startGenerationWorkflow(db, jobId);
  }
  return jobId;
}

/** A job's state, for the workflow to wait on. */
export async function petFriendJobState(db: Database, jobId: string): Promise<string | null> {
  return (await db.select({ state: generationJobs.state }).from(generationJobs)
    .where(eq(generationJobs.id, jobId)).then(firstRow))?.state ?? null;
}

/** Stage two: confirm the plan the planning turn finalized, and start building it. */
export async function confirmPetFriendPlan(db: Database, userId: string, friendId: string): Promise<string | null> {
  const friend = await friendInProgress(db, userId, friendId);
  if (!friend?.planJobId || !friend.stickerId) return null;
  if (friend.composeJobId) return friend.composeJobId;
  const card = await db.select({ planId: chatMessages.planId }).from(chatMessages)
    .where(and(eq(chatMessages.jobId, friend.planJobId), eq(chatMessages.role, "assistant"), eq(chatMessages.kind, "plan")))
    .limit(1).then(firstRow);
  if (!card?.planId) throw new Error("The friend's planning turn left no plan");
  const plan = await db.select().from(plans).where(eq(plans.id, card.planId)).then(firstRow);
  let jobId: string;
  if (plan?.state === "confirmed" && plan.jobId) {
    jobId = plan.jobId;
  } else {
    ({ jobId } = await confirmPlan(db, userId, friend.stickerId, card.planId, 6, "pet"));
  }
  await updateFriend(db, friendId, { composeJobId: jobId, state: "building" });
  if (!(await db.select({ runId: generationJobs.workflowRunId }).from(generationJobs)
    .where(eq(generationJobs.id, jobId)).then(firstRow))?.runId) {
    await startGenerationWorkflow(db, jobId);
  }
  return jobId;
}

/** Stage three: accept the built revision and publish it, so the friend can be sent and posed. */
export async function publishPetFriend(db: Database, userId: string, friendId: string): Promise<boolean> {
  const friend = await friendInProgress(db, userId, friendId);
  if (!friend?.composeJobId || !friend.stickerId) return false;
  await updateFriend(db, friendId, { state: "publishing" });
  await acceptRevision(db, userId, friend.stickerId, friend.composeJobId);
  await quickPublishSticker(db, userId, friend.stickerId);
  return true;
}

/**
 * Stage four: the friend is ready. The pet introduces them — its line becomes its caption and a
 * diary entry — and the owner gets a banner that opens the welcome. A pet released or replaced
 * while its friend was made leaves the friend in the library without a word.
 */
export async function finishPetFriend(
  db: Database,
  userId: string,
  friendId: string,
  notify: (db: Database, userId: string, friend: { id: string; title: string; body: string }) => Promise<void> = notifyPetFriend,
): Promise<boolean> {
  const friend = await friendInProgress(db, userId, friendId);
  if (!friend) return false;
  const now = new Date();
  const [finished] = await db.update(petFriends).set({ state: "ready", finishedAt: now })
    .where(and(eq(petFriends.id, friendId), inArray(petFriends.state, ACTIVE_STATES)))
    .returning();
  if (!finished) return false;
  const pet = await petRow(db, userId);
  if (pet?.lifeId !== friend.lifeId) {
    petLog("friend:finished", { userId, friendId, introduced: false });
    return true;
  }
  const petTitle = (await db.select({ title: stickers.title }).from(stickers)
    .where(eq(stickers.id, pet.stickerId)).then(firstRow))?.title ?? "Your pet";
  const committed = await commitPetChange(db, userId, {
    lifeId: friend.lifeId,
    set: pet.statusJson ? { statusJson: { ...pet.statusJson, caption: friend.greeting, musings: undefined }, statusUpdatedAt: now } : {},
    changes: [{
      kind: "friend",
      title: `Met ${friend.name}`,
      detail: `${friend.story} “${friend.greeting}”`,
      effects: personalizeEffects(FRIEND_EFFECTS, pet.identityJson),
      debug: { source: "friend", friendId, stickerId: friend.stickerId, planJobId: friend.planJobId, composeJobId: friend.composeJobId },
    }],
  });
  petLog("friend:finished", { userId, friendId, introduced: !!committed });
  await notify(db, userId, { id: friendId, title: `${petTitle} met a new friend!`, body: friend.greeting });
  return true;
}

/** Ends a friend that could not be made. Its half-made sticker stays a draft in the library. */
export async function failPetFriend(db: Database, userId: string, friendId: string, message: string): Promise<void> {
  const failed = await db.update(petFriends).set({ state: "failed", finishedAt: new Date(), error: message.slice(0, 300) })
    .where(and(eq(petFriends.id, friendId), eq(petFriends.userId, userId), inArray(petFriends.state, ACTIVE_STATES)))
    .returning({ id: petFriends.id });
  if (failed.length) petLog("friend:failed", { userId, friendId, error: message.slice(0, 300) });
}

/**
 * The newest friend of this life the owner has not been welcomed to yet, as the app shows it: who
 * they are, how they met, the pet's line, and the sticker to draw. Null when there is none, or its
 * sticker has since been deleted.
 */
export async function serializeNewPetFriend(db: Database, userId: string, lifeId: string | null) {
  if (!lifeId) return null;
  const friend = await db.select().from(petFriends)
    .where(and(eq(petFriends.userId, userId), eq(petFriends.lifeId, lifeId), eq(petFriends.state, "ready"), isNull(petFriends.seenAt)))
    .orderBy(desc(petFriends.finishedAt)).limit(1).then(firstRow);
  if (!friend?.stickerId) return null;
  const summary = await selectStickerSummaries(db)
    .where(and(eq(stickers.id, friend.stickerId), notInArray(stickers.status, ["deleting"]))).then(firstRow);
  if (!summary) return null;
  return {
    id: friend.id,
    name: friend.name,
    story: friend.story,
    greeting: friend.greeting,
    sticker: serializeStickerSummary(summary),
    metAt: (friend.finishedAt ?? friend.createdAt).toISOString(),
  };
}

/** The owner has been welcomed to `friendId`; it is not shown again. Seeing it twice is not an error. */
export async function markPetFriendSeen(db: Database, userId: string, friendId: string, now = new Date()): Promise<void> {
  const friend = await db.select({ id: petFriends.id, seenAt: petFriends.seenAt }).from(petFriends)
    .where(and(eq(petFriends.id, friendId), eq(petFriends.userId, userId), eq(petFriends.state, "ready"))).then(firstRow);
  if (!friend) throw new ApiError(404, "PET_FRIEND_NOT_FOUND", "This friend could not be found.");
  if (friend.seenAt) return;
  await db.update(petFriends).set({ seenAt: now }).where(and(eq(petFriends.id, friendId), isNull(petFriends.seenAt)));
}
