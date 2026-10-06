import { after } from "next/server";
import { and, asc, cosineDistance, desc, eq, inArray, notInArray } from "drizzle-orm";
import { getAiProvider } from "@/lib/ai/gateway";
import type { AiPetMemory, AiPetMemoryOperation, AiPetMoment } from "@/lib/ai/gateway-contracts";
import type { PetMemoriesResponseV1, RememberPetTalkRequest } from "@/lib/contracts/api";
import { firstRow, type Database } from "@/lib/db/client";
import { petMemories, stickers, userPets, type PetMemorySource } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { describeError } from "@/lib/observability/trace";
import { petLog } from "@/lib/pets/log";

/** The most memories one life keeps; past it, the least important and longest untouched go first. */
export const PET_MEMORY_LIMIT = 200;
/** How many of its nearest memories each new moment brings before the memory agent. */
const NEAREST_PER_MOMENT = 4;
/** How many memories a pet answering a moment is reminded of. */
export const PET_RECALL_LIMIT = 5;
/** How many sources a memory keeps: enough to say why, not a second diary. */
const SOURCES_KEPT = 8;

/**
 * Diary lines the pet does not need to remember: bookkeeping that happens on its own every day, and
 * says nothing about its owner or its life with them.
 */
const ROUTINE_SOURCES = new Set(["daily-gold", "room"]);

/** Whether a diary line is worth showing the memory agent. */
export function isMemorable(change: { debug?: Record<string, unknown> }): boolean {
  const source = change.debug?.source;
  return typeof source !== "string" || !ROUTINE_SOURCES.has(source);
}

/**
 * Updates are run one at a time per pet in this process, so two moments landing together — a talk
 * and an action — see each other's memories rather than both adding the same one.
 */
const chains = new Map<string, Promise<void>>();
const pending = new Set<Promise<void>>();

/**
 * Has the pet's memory agent read `moments` once the response has gone: never slows down, and never
 * fails, what the owner is waiting on. Outside a request — a script, a test — it starts at once.
 */
export function queuePetMemory(db: Database, userId: string, lifeId: string, moments: AiPetMoment[]): void {
  if (!moments.length) return;
  const key = `${userId}:${lifeId}`;
  const run = () => {
    const task = (chains.get(key) ?? Promise.resolve())
      .then(() => rememberPetMoments(db, userId, lifeId, moments))
      .catch((error) => petLog("memory:failed", { userId, lifeId, kinds: moments.map((moment) => moment.kind),
        error: describeError(error) }));
    chains.set(key, task);
    pending.add(task);
    void task.finally(() => {
      pending.delete(task);
      if (chains.get(key) === task) chains.delete(key);
    });
    return task;
  };
  try {
    after(run);
  } catch {
    void run();
  }
}

/** Waits for every memory update queued so far, for a test to read what was remembered. */
export async function settlePetMemoriesForTests(): Promise<void> {
  while (pending.size) await Promise.all([...pending]);
}

/** The memories nearest to `embedding` by meaning, for one life. */
function nearestMemories(db: Database, userId: string, lifeId: string, embedding: number[], limit: number) {
  return db.select({ id: petMemories.id, content: petMemories.content, category: petMemories.category,
    importance: petMemories.importance, sourcesJson: petMemories.sourcesJson })
    .from(petMemories)
    .where(and(eq(petMemories.userId, userId), eq(petMemories.lifeId, lifeId)))
    .orderBy(cosineDistance(petMemories.embedding, embedding))
    .limit(limit);
}

/**
 * Shows the pet's memory agent what just happened beside the memories nearest to it, and writes
 * what it decided: new memories, rewritten ones, forgotten ones. Only memories it was shown may be
 * rewritten or forgotten. Nothing is written for a pet that has since stopped being this life.
 */
export async function rememberPetMoments(db: Database, userId: string, lifeId: string, moments: AiPetMoment[]): Promise<void> {
  const pet = await db.select({ lifeId: userPets.lifeId, identity: userPets.identityJson, title: stickers.title })
    .from(userPets)
    .innerJoin(stickers, eq(stickers.id, userPets.stickerId))
    .where(eq(userPets.userId, userId))
    .then(firstRow);
  if (pet?.lifeId !== lifeId) return;
  const ai = getAiProvider();
  const vectors = await ai.embedPetMemories(moments.map(momentText));
  const nearest = new Map<string, AiPetMemory & { sourcesJson: PetMemorySource[] }>();
  for (const vector of vectors) {
    for (const memory of await nearestMemories(db, userId, lifeId, vector, NEAREST_PER_MOMENT)) nearest.set(memory.id, memory);
  }
  const shown = [...nearest.values()];
  const decided = await ai.updatePetMemory({
    petTitle: pet.title,
    identity: pet.identity,
    moments,
    memories: shown.map(({ id, content, category, importance }) => ({ id, content, category, importance })),
  });
  // An id the agent made up, or a memory touched twice, is dropped rather than trusted.
  const touched = new Set<string>();
  const operations = decided.filter((operation) => {
    if (operation.op === "add") return true;
    if (!nearest.has(operation.id) || touched.has(operation.id)) return false;
    touched.add(operation.id);
    return true;
  });
  const written = operations.filter((operation): operation is Exclude<AiPetMemoryOperation, { op: "delete" }> => operation.op !== "delete");
  const embeddings = await ai.embedPetMemories(written.map((operation) => operation.content));
  const sources: PetMemorySource[] = moments.map((moment) => ({ kind: moment.kind, title: moment.title.slice(0, 120), at: moment.at }));
  const now = new Date();
  await db.transaction(async (tx) => {
    for (const [index, operation] of written.entries()) {
      const values = { content: operation.content, category: operation.category, importance: operation.importance,
        embedding: embeddings[index], updatedAt: now };
      if (operation.op === "add") {
        await tx.insert(petMemories).values({ id: crypto.randomUUID(), userId, lifeId, ...values, sourcesJson: sources, createdAt: now });
      } else {
        await tx.update(petMemories)
          .set({ ...values, sourcesJson: [...nearest.get(operation.id)!.sourcesJson, ...sources].slice(-SOURCES_KEPT) })
          .where(and(eq(petMemories.id, operation.id), eq(petMemories.userId, userId)));
      }
    }
    const forgotten = operations.flatMap((operation) => (operation.op === "delete" ? [operation.id] : []));
    if (forgotten.length) {
      await tx.delete(petMemories).where(and(eq(petMemories.userId, userId), inArray(petMemories.id, forgotten)));
    }
  });
  await prune(db, userId, lifeId);
  petLog("memory:updated", { userId, lifeId, kinds: moments.map((moment) => moment.kind), shown: shown.length,
    operations: operations.map((operation) => operation.op) });
}

function momentText(moment: AiPetMoment): string {
  return `${moment.title}: ${moment.detail}`;
}

/** Keeps a life to `PET_MEMORY_LIMIT` memories, letting go of the least important, oldest first. */
async function prune(db: Database, userId: string, lifeId: string): Promise<void> {
  const life = and(eq(petMemories.userId, userId), eq(petMemories.lifeId, lifeId));
  const kept = await db.select({ id: petMemories.id }).from(petMemories).where(life)
    .orderBy(desc(petMemories.importance), desc(petMemories.updatedAt), asc(petMemories.id))
    .limit(PET_MEMORY_LIMIT);
  if (kept.length < PET_MEMORY_LIMIT) return;
  await db.delete(petMemories).where(and(life, notInArray(petMemories.id, kept.map((row) => row.id))));
}

/**
 * What the pet remembers that bears on `about`, nearest first, for it to answer with. A pet that
 * cannot remember right now still answers: any failure is an empty list.
 */
export async function recallPetMemories(
  db: Database, userId: string, lifeId: string | null, about: string, limit = PET_RECALL_LIMIT,
): Promise<string[]> {
  if (!lifeId || !about.trim()) return [];
  try {
    const any = await db.select({ id: petMemories.id }).from(petMemories)
      .where(and(eq(petMemories.userId, userId), eq(petMemories.lifeId, lifeId))).limit(1);
    // Nothing to find: no point paying for an embedding.
    if (!any.length) return [];
    const [vector] = await getAiProvider().embedPetMemories([about]);
    return (await nearestMemories(db, userId, lifeId, vector, limit)).map((memory) => memory.content);
  } catch (error) {
    petLog("memory:recall-failed", { userId, lifeId, error: describeError(error) });
    return [];
  }
}

/** The current pet's memories: nearest to `query` when one is given, otherwise most important first. */
export async function listPetMemories(
  db: Database, userId: string, options: { query?: string | null; limit: number },
): Promise<PetMemoriesResponseV1> {
  const pet = await db.select({ lifeId: userPets.lifeId }).from(userPets).where(eq(userPets.userId, userId)).then(firstRow);
  if (!pet?.lifeId) return { memories: [] };
  const columns = { id: petMemories.id, content: petMemories.content, category: petMemories.category,
    importance: petMemories.importance, updatedAt: petMemories.updatedAt };
  const life = and(eq(petMemories.userId, userId), eq(petMemories.lifeId, pet.lifeId));
  const query = options.query?.trim();
  let rows;
  if (query) {
    const any = await db.select({ id: petMemories.id }).from(petMemories).where(life).limit(1);
    if (!any.length) return { memories: [] };
    const [vector] = await getAiProvider().embedPetMemories([query]);
    rows = await db.select(columns).from(petMemories).where(life)
      .orderBy(cosineDistance(petMemories.embedding, vector)).limit(options.limit);
  } else {
    rows = await db.select(columns).from(petMemories).where(life)
      .orderBy(desc(petMemories.importance), desc(petMemories.updatedAt)).limit(options.limit);
  }
  return { memories: rows.map((row) => ({ ...row, updatedAt: row.updatedAt.toISOString() })) };
}

/**
 * Something the owner said to their pet, and what it said back. The reply is thought of on the
 * phone, so the server hears of the talk only for the pet to remember it.
 */
export async function rememberPetTalk(db: Database, userId: string, input: RememberPetTalkRequest): Promise<void> {
  const pet = await db.select({ lifeId: userPets.lifeId }).from(userPets).where(eq(userPets.userId, userId)).then(firstRow);
  if (!pet?.lifeId) throw new ApiError(404, "PET_NOT_FOUND", "Choose a pet first.");
  queuePetMemory(db, userId, pet.lifeId, [{
    kind: "talk",
    title: "Owner talked to it",
    detail: input.reply ? `Owner said: “${input.words}” It answered: “${input.reply}”` : `Owner said: “${input.words}”`,
    at: new Date().toISOString(),
  }]);
}
