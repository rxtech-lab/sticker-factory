import { eq } from "drizzle-orm";
import { afterEach, describe, expect, it, vi } from "vitest";
import { setAiProviderForTests } from "@/lib/ai/gateway";
import type { StickerConfiguration } from "@/lib/contracts/configuration";
import { chatMessages, chatThreads, generationJobs, petWeatherArt, stickerRevisions, stickers, userPets, type UserPetRow } from "@/lib/db/schema";
import { setPetRandomForTests } from "@/lib/pets/log";
import { canEvolve, beginPetEvolutionPlan, failPetEvolution, finishPetEvolution, publishPetEvolution, setPetEvolutionStarterForTests, startPetEvolution } from "@/lib/services/pet-evolution";
import { listPetEvents } from "@/lib/services/pet-state";
import { getPet, interactWithPet, noticeNewSticker, setPet } from "@/lib/services/pets";
import { getSticker } from "@/lib/services/stickers";
import { MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";
import { unusedAiProvider } from "@/tests/helpers/workflow";

// The planning turn runs in its own workflow run; here it is only queued.
vi.mock("@/lib/services/workflows", async (original) => ({
  ...await original<typeof import("@/lib/services/workflows")>(),
  startGenerationWorkflow: vi.fn(async () => "run-test"),
}));

const configuration: StickerConfiguration = {
  controls: [
    { id: "mood", label: "Mood", type: "choice", defaultValue: "calm",
      options: [{ id: "calm", label: "Calm" }, { id: "happy", label: "Happy" }, { id: "sleepy", label: "Sleepy" }] },
  ],
  variants: [],
};

const actions = async () => [
  { title: "Juggle", description: "Juggle three berries.", effects: { happiness: 4, hp: 0, energy: -2, gold: 0 } },
];

describe("pet growth and noticing", () => {
  afterEach(() => {
    setAiProviderForTests(undefined);
    setObjectStoreForTests(undefined);
    setPetRandomForTests(undefined);
    setPetEvolutionStarterForTests(undefined);
  });

  async function setup() {
    setPetRandomForTests(() => 0.5);
    const { db, close } = await createTestDatabase();
    setObjectStoreForTests(new MemoryObjectStore());
    await seedUser(db, "owner");
    const pet = await seedPublishedSticker(db, "owner", { title: "Loaf", kind: "animated", controllable: true, configuration });
    await db.update(stickers).set({ controllable: true }).where(eq(stickers.id, pet.stickerId));
    setAiProviderForTests({ ...unusedAiProvider, generatePetActions: actions });
    await setPet(db, "owner", { stickerId: pet.stickerId });
    return { db, close, pet };
  }

  async function finishedJob(db: Awaited<ReturnType<typeof setup>>["db"], stickerId: string, origin: "user" | "pet" = "user") {
    const id = crypto.randomUUID();
    await db.insert(generationJobs).values({ id, ownerId: "owner", stickerId, kind: "image", state: "succeeded", origin });
    return id;
  }

  it("lets the pet react to a sticker its owner just made, or let it pass", async () => {
    const { db, close, pet } = await setup();
    try {
      const pizza = await seedPublishedSticker(db, "owner", { title: "Pizza Party" });
      const seen: string[] = [];
      let react = true;
      const pushes: string[] = [];
      setAiProviderForTests({ ...unusedAiProvider, generatePetActions: actions,
        noticePetSticker: async ({ made, localTime }) => {
          seen.push(made.title);
          expect(localTime).toMatch(/\d{2}:\d{2}/);
          return react
            ? { react: true, values: { mood: "happy" }, caption: " Pizza! ", effects: { happiness: 4, hp: 0, energy: 0 } }
            : { react: false };
        } });

      await noticeNewSticker(db, await finishedJob(db, pizza.stickerId), pizza.revisionId, async (_db, userId) => { pushes.push(userId); });
      const reacted = (await getPet(db, "owner")).pet!;
      expect(reacted.status).toMatchObject({ values: { mood: "happy" }, caption: "Pizza!" });
      expect(reacted.actions.map((action) => action.title)).toEqual(["Juggle"]);
      const events = await listPetEvents(db, "owner", { limit: 5 });
      expect(events.events[0]).toMatchObject({ kind: "sticker", title: "Saw “Pizza Party”", detail: "Pizza!" });
      expect(pushes).toEqual(["owner"]);

      // Let pass: nothing moves and nobody is woken.
      react = false;
      await noticeNewSticker(db, await finishedJob(db, pizza.stickerId), pizza.revisionId, async (_db, userId) => { pushes.push(userId); });
      expect((await getPet(db, "owner")).pet!.status?.caption).toBe("Pizza!");
      expect(pushes).toEqual(["owner"]);

      // The pet's own growth, and a turn on the pet's own sticker, are not shown to it.
      await noticeNewSticker(db, await finishedJob(db, pizza.stickerId, "pet"), pizza.revisionId);
      await noticeNewSticker(db, await finishedJob(db, pet.stickerId), pet.revisionId);
      // Nor is a turn that made nothing.
      await noticeNewSticker(db, await finishedJob(db, pizza.stickerId), undefined);
      expect(seen).toEqual(["Pizza Party", "Pizza Party"]);
    } finally {
      await close();
    }
  });

  it("offers growth only when the pet may grow, and starts it when the pet asks", async () => {
    const { db, close, pet } = await setup();
    try {
      const started: string[] = [];
      setPetEvolutionStarterForTests(async (_userId, evolutionId) => { started.push(evolutionId); return "run"; });
      const offered: boolean[] = [];
      setAiProviderForTests({ ...unusedAiProvider, generatePetActions: actions,
        respondToPetInteraction: async ({ action, canEvolve: may }) => {
          offered.push(!!may);
          return { values: {}, caption: action.description, evolve: { brief: "Add a proud juggling mood." } };
        } });

      const first = (await getPet(db, "owner")).pet!;
      const after = await interactWithPet(db, "owner", { actionId: first.actions[0].id }, async () => {});
      expect(started).toHaveLength(1);
      expect(after.pet?.evolution).toMatchObject({ state: "planning", finishedAt: null });
      const row = await db.select().from(userPets).where(eq(userPets.userId, "owner")).then((rows) => rows[0]);
      expect(row.evolutionJson).toMatchObject({ brief: "Add a proud juggling mood.", trigger: "action: Juggle", stickerId: pet.stickerId });

      // Within the cooldown the pet is not even offered it, and asking anyway starts nothing.
      await interactWithPet(db, "owner", { actionId: after.pet!.actions[0].id }, async () => {});
      expect(offered).toEqual([true, false]);
      expect(started).toHaveLength(1);
      expect(await startPetEvolution(db, "owner", { stickerId: pet.stickerId, brief: "Again", trigger: "test" })).toBe(false);

      // Someone else's sticker — a pack the owner installed — is not theirs to redraw.
      const sticker = await db.select().from(stickers).where(eq(stickers.id, pet.stickerId)).then((rows) => rows[0]);
      const fresh = { ...row, lastEvolvedAt: null } as UserPetRow;
      expect(canEvolve(fresh, sticker)).toBe(true);
      expect(canEvolve(fresh, { ...sticker, ownerId: "friend" })).toBe(false);
    } finally {
      await close();
    }
  });

  it("plans the growth on the owner's behalf for free, and has the pet tell them once it is done", async () => {
    const { db, close, pet } = await setup();
    try {
      await db.insert(chatThreads).values({ id: crypto.randomUUID(), stickerId: pet.stickerId, ownerId: "owner" });
      let evolutionId = "";
      setPetEvolutionStarterForTests(async (_userId, id) => { evolutionId = id; return "run"; });
      expect(await startPetEvolution(db, "owner", { stickerId: pet.stickerId, brief: "Add a sleepy yawn.", trigger: "photo" })).toBe(true);

      const jobId = await beginPetEvolutionPlan(db, "owner", evolutionId);
      const job = await db.select().from(generationJobs).where(eq(generationJobs.id, jobId!)).then((rows) => rows[0]);
      expect(job).toMatchObject({ kind: "plan", origin: "pet", reservationId: null, reservationAmount: 0, state: "queued" });
      const message = await db.select().from(chatMessages).where(eq(chatMessages.jobId, jobId!)).then((rows) => rows[0]);
      expect(message.content).toContain("Add a sleepy yawn.");
      // The item is built to be switched and to stay out of the pet's way.
      expect(message.content).toContain("its own separate accessory layer");
      expect(message.content).toContain("toggle control");
      expect(message.content).toContain("new pose clip");
      // A replayed step reuses the job it queued.
      expect(await beginPetEvolutionPlan(db, "owner", evolutionId)).toBe(jobId);

      const alerts: Array<{ title: string; body: string }> = [];
      setAiProviderForTests({ ...unusedAiProvider, generatePetActions: actions,
        narratePetEvent: async ({ event }) => {
          expect(event.title).toBe("Grew something new");
          return { values: { mood: "sleepy" }, caption: "I can yawn now!" };
        } });
      // Its weather belongs to the sticker: growing an item keeps it.
      const [{ activeRevisionId }] = await db.select({ activeRevisionId: stickers.activeRevisionId }).from(stickers)
        .where(eq(stickers.id, pet.stickerId));
      await db.insert(petWeatherArt).values({ id: crypto.randomUUID(), stickerId: pet.stickerId, revisionId: activeRevisionId!,
        kind: "sunny", isDay: true, state: "ready", r2Key: "private/pet-weather/sun.png", claimedAt: new Date(), readyAt: new Date() });
      expect(await finishPetEvolution(db, "owner", evolutionId, async (_db, _userId, alert) => { alerts.push(alert); })).toBe(true);
      expect(await db.select().from(petWeatherArt)).toHaveLength(1);
      const grown = (await getPet(db, "owner")).pet!;
      expect(grown.status).toMatchObject({ values: { mood: "sleepy" }, caption: "I can yawn now!" });
      expect(grown.evolution).toMatchObject({ state: "ready" });
      expect((await listPetEvents(db, "owner", { limit: 1 })).events[0]).toMatchObject({ kind: "evolved", detail: "I can yawn now!" });
      expect(alerts).toEqual([{ title: "Loaf grew!", body: "I can yawn now!" }]);

      // Finished is finished: a late failure or a replay changes nothing.
      await failPetEvolution(db, "owner", evolutionId, "late");
      expect(await finishPetEvolution(db, "owner", evolutionId, async () => { throw new Error("no second push"); })).toBe(false);
      expect((await getPet(db, "owner")).pet!.evolution?.state).toBe("ready");
    } finally {
      await close();
    }
  });

  it("draws its weather again after growing only when the pet asked for it", async () => {
    const { db, close, pet } = await setup();
    try {
      let evolutionId = "";
      setPetEvolutionStarterForTests(async (_userId, id) => { evolutionId = id; return "run"; });
      expect(await startPetEvolution(db, "owner", { stickerId: pet.stickerId, brief: "Repaint me in pastel watercolour.",
        redrawWeather: true, trigger: "photo" })).toBe(true);
      const [{ activeRevisionId }] = await db.select({ activeRevisionId: stickers.activeRevisionId }).from(stickers)
        .where(eq(stickers.id, pet.stickerId));
      await db.insert(petWeatherArt).values({ id: crypto.randomUUID(), stickerId: pet.stickerId, revisionId: activeRevisionId!,
        kind: "sunny", isDay: true, state: "ready", r2Key: "private/pet-weather/sun.png", claimedAt: new Date(), readyAt: new Date() });
      setAiProviderForTests({ ...unusedAiProvider, generatePetActions: actions,
        narratePetEvent: async () => ({ values: {}, caption: "Look at my new colours!" }) });
      expect(await finishPetEvolution(db, "owner", evolutionId, async () => {})).toBe(true);
      expect(await db.select().from(petWeatherArt)).toHaveLength(0);
    } finally {
      await close();
    }
  });

  it("keeps the pet's published look when the grown sticker cannot be published", async () => {
    const { db, close, pet } = await setup();
    try {
      let evolutionId = "";
      setPetEvolutionStarterForTests(async (_userId, id) => { evolutionId = id; return "run"; });
      expect(await startPetEvolution(db, "owner", { stickerId: pet.stickerId, brief: "Add a tuna treat.", trigger: "photo" })).toBe(true);
      const [sticker] = await db.select().from(stickers).where(eq(stickers.id, pet.stickerId));
      const [revision] = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, sticker.activeRevisionId!));
      // A built candidate whose artwork is gone, so the quick publish refuses it.
      const composeJobId = crypto.randomUUID();
      await db.insert(stickerRevisions).values({ ...revision, id: composeJobId, parentRevisionId: revision.id,
        candidateState: "candidate", playbackJson: null, pngAssetId: null, systemAssetId: null, apngAssetId: null,
        attachmentMediumAssetId: null, attachmentSmallAssetId: null, webpAssetId: null, decidedAt: null, createdAt: new Date() });
      const row = (await db.select().from(userPets).where(eq(userPets.userId, "owner")))[0];
      await db.update(userPets).set({ evolutionJson: { ...row.evolutionJson!, state: "building", composeJobId } })
        .where(eq(userPets.userId, "owner"));

      // The chat is told the pet is publishing it, so it does not ask the owner to.
      expect((await getSticker(db, "owner", pet.stickerId)).petEvolving).toBe(true);
      await expect(publishPetEvolution(db, "owner", evolutionId)).rejects.toThrow();
      const after = (await db.select().from(stickers).where(eq(stickers.id, pet.stickerId)))[0];
      expect(after).toMatchObject({ activeRevisionId: revision.id, status: "published" });
      expect((await getPet(db, "owner")).pet).not.toBeNull();
    } finally {
      await close();
    }
  });
});
