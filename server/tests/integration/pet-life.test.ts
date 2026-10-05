import { eq } from "drizzle-orm";
import { afterEach, describe, expect, it } from "vitest";
import { setAiProviderForTests } from "@/lib/ai/gateway";
import type { StickerConfiguration } from "@/lib/contracts/configuration";
import { PetEventsResponseV1Schema, PetResponseV1Schema, SharePetResponseV1Schema } from "@/lib/contracts/api";
import { petEvents, userPets } from "@/lib/db/schema";
import { setPetRandomForTests } from "@/lib/pets/log";
import { setWeatherFetcherForTests } from "@/lib/pets/signals";
import { planPetVisit, retirePetLife, visitPet } from "@/lib/services/pet-life";
import { revivePetLives, setPetLifeStarterForTests } from "@/lib/services/pet-life-runner";
import { listPetEvents } from "@/lib/services/pet-state";
import { clearPet, getPet, interactWithPet, readPetSend, recordPetSend, setPet, sharePet, updatePetContext } from "@/lib/services/pets";
import { MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";
import { unusedAiProvider } from "@/tests/helpers/workflow";

const configuration: StickerConfiguration = {
  controls: [
    { id: "mood", label: "Mood", type: "choice", defaultValue: "calm",
      options: [{ id: "calm", label: "Calm" }, { id: "happy", label: "Happy" }, { id: "sleepy", label: "Sleepy" }] },
  ],
  variants: [],
};

const context = { latitude: 37.774929, longitude: -122.419416, stepsToday: 12_000, timeZone: "UTC" };
const noNotify = async () => {};

describe("pet life", () => {
  let started: Array<{ userId: string; lifeId: string; token: string }> = [];

  afterEach(() => {
    setObjectStoreForTests(undefined);
    setAiProviderForTests(undefined);
    setPetRandomForTests(undefined);
    setWeatherFetcherForTests(undefined);
    setPetLifeStarterForTests(undefined);
  });

  async function setup(options: { persona?: boolean } = {}) {
    started = [];
    setPetRandomForTests(() => 0.5);
    setWeatherFetcherForTests(async () => ({ kind: "rainy", temperatureC: 11.5, isDay: true }));
    setPetLifeStarterForTests(async (userId, lifeId, token) => {
      started.push({ userId, lifeId, token });
      return `run-${started.length}`;
    });
    setAiProviderForTests({
      ...unusedAiProvider,
      generatePetActions: async () => [{ title: "Splash", description: "Splash in puddles together.", effects: { happiness: 6, hp: 0, energy: -10, gold: 0 } }],
      generatePetPersona: options.persona === false
        ? async () => { throw new Error("model down"); }
        : async () => ({ class: "athlete", personality: "Restless runner", likes: ["puddles"], dislikes: ["naps"], favoriteWeather: "rainy" }),
      searchPetHeadlines: async () => ["Local park opens a new splash pad"],
      respondToPetInteraction: async ({ action }) => ({ values: {}, caption: action.description }),
      choosePetStatus: async () => ({ values: { mood: "happy" }, caption: "Wheee", effects: { happiness: 20, hp: 0, energy: 0 } }),
      narratePetEvent: async ({ event }) => ({ values: { mood: "sleepy" }, caption: `About ${event.title}` }),
    });
    const { db, close } = await createTestDatabase();
    setObjectStoreForTests(new MemoryObjectStore());
    await seedUser(db, "owner");
    const pet = await seedPublishedSticker(db, "owner", { title: "Loaf", kind: "animated", controllable: true, configuration });
    const other = await seedPublishedSticker(db, "owner", { title: "Rainy day" });
    return { db, close, pet, other };
  }

  it("is born with a class-derived identity, the world of its adoption day, and a running life", async () => {
    const { db, close, pet } = await setup();
    try {
      const adopted = PetResponseV1Schema.parse(await setPet(db, "owner", { stickerId: pet.stickerId, context })).pet!;
      expect(adopted.identity).toMatchObject({
        class: "athlete", personality: "Restless runner", favoriteWeather: "rainy", maxHp: 125, energyMultiplier: 1.5,
        birth: { weather: { kind: "rainy" }, stepsToday: 12_000, headlines: ["Local park opens a new splash pad"] },
      });
      expect(adopted.stats).toEqual({ happiness: 80, hp: 125, energy: 80, gold: 20 });
      const row = (await db.select().from(userPets).where(eq(userPets.userId, "owner")))[0];
      // Stored rounded: weather needs a kilometre, not a doorstep.
      expect(row.contextJson).toMatchObject({ latitude: 37.77, longitude: -122.42, stepsToday: 12_000 });
      expect(started).toEqual([{ userId: "owner", lifeId: row.lifeId, token: row.lifeRunId }]);

      const diary = PetEventsResponseV1Schema.parse(await listPetEvents(db, "owner", { limit: 10 }));
      expect(diary.events).toMatchObject([{ kind: "adopted", title: "Adopted Loaf", debug: { identitySource: "model" } }]);
    } finally {
      await close();
    }
  });

  it("becomes a balanced explorer when no identity can be written", async () => {
    const { db, close, pet } = await setup({ persona: false });
    try {
      const adopted = (await setPet(db, "owner", { stickerId: pet.stickerId })).pet!;
      expect(adopted.identity).toMatchObject({ class: "explorer", maxHp: 100, energyMultiplier: 1 });
    } finally {
      await close();
    }
  });

  it("feels the world in a send: weather, steps, a bounded mood, and sometimes a random event", async () => {
    const { db, close, pet, other } = await setup();
    try {
      await setPet(db, "owner", { stickerId: pet.stickerId, context });
      // First roll decides the event (below the 30% chance), second picks which one.
      const rolls = [0.1, 0.0];
      setPetRandomForTests(() => rolls.shift() ?? 0.5);
      const tasks: Array<() => Promise<void>> = [];
      expect(await recordPetSend(db, "owner", { stickerId: other.stickerId, context: { stepsToday: 12_500 } }, (task) => tasks.push(task)))
        .toEqual({ accepted: true });
      await Promise.all(tasks.map((task) => task()));

      const { events } = await listPetEvents(db, "owner", { limit: 10 });
      expect(events.map((event) => event.kind)).toEqual(["send", "random", "special", "adopted"]);
      const [send, random, walk] = events;
      // Today's 12,500 steps are paid first, at one gold per 250.
      expect(walk).toMatchObject({ title: "Walk reward", effects: { happiness: 0, hp: 0, energy: 0, gold: 50 } });
      expect(walk.statsAfter.gold).toBe(70);
      // Send: +2/0/-1 base, rainy favourite +4, athlete's big walk +4/+3/-2, model mood clamped to +8.
      // Energy costs are scaled by the athlete's 1.5: (-1 - 2) × 1.5 = -4.5 → -4.
      expect(send.effects).toEqual({ happiness: 18, hp: 3, energy: -4, gold: 0 });
      expect(send.debug).toMatchObject({ moodEffects: { happiness: 8 }, worldReasons: expect.arrayContaining([expect.stringContaining("rainy")]) });
      expect(send.signals).toMatchObject({ stepsToday: 12_500, weather: { kind: "rainy" } });
      expect(random.statsAfter).toEqual(send.statsBefore);
      expect((await getPet(db, "owner")).pet).toMatchObject({ status: { values: { mood: "happy" }, caption: "Wheee" } });
    } finally {
      await close();
    }
  });

  it("scales an action's energy cost by the pet's multiplier and rewards its likes", async () => {
    const { db, close, pet } = await setup();
    try {
      const adopted = (await setPet(db, "owner", { stickerId: pet.stickerId })).pet!;
      const played = (await interactWithPet(db, "owner", { actionId: adopted.actions[0].id }, noNotify)).pet!;
      // "Splash in puddles" touches a like (+4); -10 energy × 1.5.
      expect(played.stats).toEqual({ happiness: 90, hp: 125, energy: 65, gold: 20 });
      const { events } = await listPetEvents(db, "owner", { limit: 1 });
      expect(events[0]).toMatchObject({ kind: "interaction", debug: { preference: ["+puddles"] } });
    } finally {
      await close();
    }
  });

  it("counts showing the pet off once per window", async () => {
    const { db, close, pet } = await setup();
    try {
      expect(await sharePet(db, "owner")).toEqual({ accepted: false, pet: null });
      await setPet(db, "owner", { stickerId: pet.stickerId });
      const first = SharePetResponseV1Schema.parse(await sharePet(db, "owner"));
      expect(first).toMatchObject({ accepted: true, pet: { stats: { happiness: 86, energy: 76 } } });
      expect(await sharePet(db, "owner")).toMatchObject({ accepted: false, pet: { stats: { happiness: 86 } } });
    } finally {
      await close();
    }
  });

  it("visits on a schedule, rolls a special event, and ends once the pet is replaced", async () => {
    const { db, close, pet } = await setup();
    try {
      await setPet(db, "owner", { stickerId: pet.stickerId, context });
      const { lifeId, token } = started[0];
      const now = new Date();
      const delay = await planPetVisit(db, "owner", lifeId, token, now);
      expect(delay).toBe(Math.round(67.5 * 60_000));
      const before = (await getPet(db, "owner")).pet!.actions;
      expect((await getPet(db, "owner")).pet?.nextEventAt).toBe(new Date(now.getTime() + delay!).toISOString());

      const notified: string[] = [];
      expect(await visitPet(db, "owner", lifeId, token, async (_db, userId) => { notified.push(userId); })).toBe(true);
      expect(notified).toEqual(["owner"]);
      const [visit] = (await listPetEvents(db, "owner", { limit: 1 })).events;
      expect(visit).toMatchObject({ debug: { source: "life-workflow", narrated: true, drift: { happiness: -3, energy: 6 } } });
      expect(["special", "random"]).toContain(visit.kind);
      expect((await getPet(db, "owner")).pet?.status).toMatchObject({ values: { mood: "sleepy" }, caption: `About ${visit.title}` });
      // The new mood brings a new set of actions.
      const after = (await getPet(db, "owner")).pet!.actions;
      expect(after).toHaveLength(1);
      expect(after[0].id).not.toBe(before[0].id);

      // Another run took over the token: this one stops at its next step.
      await revivePetLives(db, new Date(Date.now() + 365 * 24 * 60 * 60 * 1000));
      expect(started).toHaveLength(2);
      expect(await planPetVisit(db, "owner", lifeId, token)).toBeNull();
      expect(await visitPet(db, "owner", lifeId, token, noNotify)).toBe(false);

      // The new run retires after its week, and the cron brings it back.
      await retirePetLife(db, "owner", lifeId, started[1].token);
      await revivePetLives(db);
      expect(started).toHaveLength(3);

      await clearPet(db, "owner");
      expect(await visitPet(db, "owner", lifeId, started[2].token, noNotify)).toBe(false);
    } finally {
      await close();
    }
  });

  it("pages the current life's diary and starts a fresh one for a new pet", async () => {
    const { db, close, pet } = await setup();
    try {
      // Every interaction hands back a fresh set of actions; the next one is picked from those.
      let current = (await setPet(db, "owner", { stickerId: pet.stickerId })).pet!;
      for (let index = 0; index < 4; index += 1) {
        current = (await interactWithPet(db, "owner", { actionId: current.actions[0].id }, noNotify)).pet!;
      }
      const first = await listPetEvents(db, "owner", { limit: 3 });
      expect(first.events).toHaveLength(3);
      const second = await listPetEvents(db, "owner", { limit: 3, cursor: first.nextCursor });
      expect(second.events.map((event) => event.kind)).toEqual(["interaction", "adopted"]);
      expect(second.nextCursor).toBeNull();

      const next = await seedPublishedSticker(db, "owner", { title: "Bun", kind: "animated", controllable: true, configuration });
      await setPet(db, "owner", { stickerId: next.stickerId });
      expect((await listPetEvents(db, "owner", { limit: 10 })).events.map((event) => event.title)).toEqual(["Adopted Bun"]);
      expect(await db.select().from(petEvents)).toHaveLength(6);
    } finally {
      await close();
    }
  });

  it("stores context for the next visit, and gives an older pet an identity on first read", async () => {
    const { db, close, pet } = await setup();
    try {
      expect(await updatePetContext(db, "owner", context)).toEqual({ stored: false });
      await setPet(db, "owner", { stickerId: pet.stickerId });
      // An older pet: no identity, no life.
      await db.update(userPets).set({ identityJson: null, lifeId: null, lifeRunId: null }).where(eq(userPets.userId, "owner"));
      const tasks: Array<() => Promise<void>> = [];
      expect(await updatePetContext(db, "owner", { stepsToday: 321, timeZone: "UTC" }, (task) => tasks.push(task))).toEqual({ stored: true });
      await Promise.all(tasks.map((task) => task()));
      expect((await db.select().from(userPets))[0].signalsJson).toMatchObject({ stepsToday: 321 });
      const read = (await getPet(db, "owner")).pet!;
      expect(read.identity?.class).toBe("athlete");
      expect(started).toHaveLength(2);
      const row = (await db.select().from(userPets).where(eq(userPets.userId, "owner")))[0];
      expect(row.contextJson).toMatchObject({ stepsToday: 321 });
      expect(row.lifeId).toBeTruthy();
    } finally {
      await close();
    }
  });

  it("never lets a reading that failed move the stats", async () => {
    const { db, close, pet, other } = await setup();
    try {
      await setPet(db, "owner", { stickerId: pet.stickerId });
      setAiProviderForTests({ ...unusedAiProvider, choosePetStatus: async () => { throw new Error("model down"); } });
      const tasks: Array<() => Promise<void>> = [];
      await recordPetSend(db, "owner", { stickerId: other.stickerId }, (task) => tasks.push(task));
      await Promise.all(tasks.map((task) => task()));
      const sentAt = (await db.select().from(userPets))[0].lastSentAt!;
      await readPetSend(db, "owner", sentAt, noNotify);
      expect((await listPetEvents(db, "owner", { limit: 10 })).events.map((event) => event.kind)).toEqual(["adopted"]);
    } finally {
      await close();
    }
  });
});
