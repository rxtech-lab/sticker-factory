import { eq } from "drizzle-orm";
import { afterEach, describe, expect, it, vi } from "vitest";
import { setAiProviderForTests } from "@/lib/ai/gateway";
import type { AiPetEncounter } from "@/lib/ai/gateway-contracts";
import { PetResponseV1Schema, ResolvePetEncounterResponseV1Schema } from "@/lib/contracts/api";
import { petEncounters, userPets } from "@/lib/db/schema";
import { encounterHour } from "@/lib/pets/encounters";
import { ILLNESS_RECOVERY_HOURS } from "@/lib/pets/illness";
import { setPetRandomForTests } from "@/lib/pets/log";
import { setWeatherFetcherForTests } from "@/lib/pets/signals";
import { givePetMedicine, maybeStartEncounter, resolvePetEncounter } from "@/lib/services/pet-encounters";
import { visitPet } from "@/lib/services/pet-life";
import { setPetLifeStarterForTests } from "@/lib/services/pet-life-runner";
import { listPetEvents } from "@/lib/services/pet-state";
import { getPet, setPet } from "@/lib/services/pets";
import { MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";
import { unusedAiProvider } from "@/tests/helpers/workflow";

const context = { latitude: 37.774929, longitude: -122.419416, stepsToday: 0, timeZone: "UTC" };
const noNotify = async () => {};

const written: AiPetEncounter = {
  title: "Mystery berries",
  prompt: "I found some berries by the fence. Can I eat them?",
  choices: [
    { title: "Ask the gardener", description: "Check first.", correct: true, outcome: "She gave me a remedy too!",
      effects: { happiness: 4, hp: 0, energy: 10, gold: 12 }, medicine: 1, sickens: false },
    // Backwards on purpose: a wrong choice the agent made rewarding is turned into a cost.
    { title: "Eat them all", description: "Yum?", correct: false, outcome: "Ugh, my tummy…",
      effects: { happiness: 6, hp: 8, energy: 0, gold: 0 }, medicine: 1, sickens: true },
    { title: "Ignore them", description: "Walk on by.", correct: false, outcome: "I keep thinking about them.",
      effects: { happiness: -4, hp: 0, energy: 0, gold: 0 }, medicine: 0, sickens: false },
  ],
};

describe("pet encounters", () => {
  afterEach(() => {
    vi.useRealTimers();
    setObjectStoreForTests(undefined);
    setAiProviderForTests(undefined);
    setPetRandomForTests(undefined);
    setWeatherFetcherForTests(undefined);
    setPetLifeStarterForTests(undefined);
  });

  async function setup() {
    setPetRandomForTests(() => 0.5);
    setWeatherFetcherForTests(async () => ({ kind: "sunny", temperatureC: 20, isDay: true }));
    setPetLifeStarterForTests(async () => "run");
    let encounters = 0;
    setAiProviderForTests({
      ...unusedAiProvider,
      generatePetActions: async () => [{ title: "Wave", description: "Wave hello.", effects: { happiness: 2, hp: 0, energy: -3, gold: 0 } }],
      generatePetPersona: async () => ({ class: "explorer", personality: "Curious", likes: ["berries"], dislikes: ["thunder"], favoriteWeather: "sunny" }),
      searchPetHeadlines: async () => [],
      narratePetEvent: async ({ event }) => ({ values: {}, caption: `About ${event.title}` }),
      generatePetItems: async () => { throw new Error("no items in this test"); },
      generatePetEncounter: async () => {
        encounters += 1;
        return written;
      },
    });
    const { db, close } = await createTestDatabase();
    setObjectStoreForTests(new MemoryObjectStore());
    await seedUser(db, "owner");
    const pet = await seedPublishedSticker(db, "owner", { title: "Loaf", kind: "animated", controllable: true });
    await setPet(db, "owner", { stickerId: pet.stickerId, context });
    const row = (await db.select().from(userPets).where(eq(userPets.userId, "owner")))[0];
    return { db, close, lifeId: row.lifeId!, encounters: () => encounters };
  }

  it("writes one encounter a day once its hour has come, notifies, and hides the outcomes", async () => {
    // Reads use the system clock; keep them on the same day as the encounter fixture.
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-10-05T21:00:00.000Z"));
    const { db, close, lifeId, encounters } = await setup();
    try {
      const hour = encounterHour("owner", lifeId, "2026-10-05");
      // Before the day's hour, which is never earlier than 9.
      expect(hour).toBeGreaterThanOrEqual(9);
      const before = new Date("2026-10-05T08:00:00.000Z");
      expect(await maybeStartEncounter(db, "owner", before, noNotify)).toBeNull();
      expect(encounters()).toBe(0);

      const notified: string[] = [];
      const evening = new Date("2026-10-05T21:00:00.000Z");
      const started = await maybeStartEncounter(db, "owner", evening, async (_db, _user, encounter) => { notified.push(encounter.title); });
      expect(started?.title).toBe("Mystery berries");
      expect(notified).toEqual(["Mystery berries"]);
      // Already had today's; a later visit the same day writes nothing.
      expect(await maybeStartEncounter(db, "owner", new Date("2026-10-05T21:30:00.000Z"), noNotify)).toBeNull();
      expect(encounters()).toBe(1);

      const wrong = started!.choicesJson.find((choice) => choice.title === "Eat them all")!;
      expect(wrong.effects).toEqual({ happiness: -6, hp: -8, energy: 0, gold: 0 });
      expect(wrong.medicine).toBe(0);

      const pet = PetResponseV1Schema.parse(await getPet(db, "owner")).pet!;
      expect(pet.encounter?.choices.map((choice) => choice.title).sort()).toEqual(["Ask the gardener", "Eat them all", "Ignore them"]);
      expect(JSON.stringify(pet.encounter)).not.toContain("correct");
      expect(pet.illness).toBeNull();
      expect(pet.medicine).toBe(0);
    } finally {
      await close();
    }
  });

  it("rewards a right choice with gold, energy and medicine, once", async () => {
    const { db, close } = await setup();
    try {
      const now = new Date("2026-10-05T21:00:00.000Z");
      const encounter = (await maybeStartEncounter(db, "owner", now, noNotify))!;
      const right = encounter.choicesJson.find((choice) => choice.correct)!;
      const before = PetResponseV1Schema.parse(await getPet(db, "owner")).pet!.stats;
      const outcome = await resolvePetEncounter(db, "owner", { encounterId: encounter.id, choiceId: right.id }, now, noNotify);
      expect(outcome).toMatchObject({ correct: true, medicine: 1, sickened: false, text: "She gave me a remedy too!" });
      const pet = PetResponseV1Schema.parse(await getPet(db, "owner")).pet!;
      expect(ResolvePetEncounterResponseV1Schema.parse({ outcome, pet })).toBeTruthy();
      expect(pet.stats.gold).toBe(before.gold + 12);
      expect(pet.stats.energy).toBe(Math.min(100, before.energy + 10));
      expect(pet.medicine).toBe(1);
      expect(pet.encounter).toBeNull();
      await expect(resolvePetEncounter(db, "owner", { encounterId: encounter.id, choiceId: right.id }, now, noNotify))
        .rejects.toMatchObject({ status: 409 });
    } finally {
      await close();
    }
  });

  it("makes the pet ill on a wrong choice, and medicine cures it", async () => {
    const { db, close } = await setup();
    try {
      const now = new Date("2026-10-05T21:00:00.000Z");
      const encounter = (await maybeStartEncounter(db, "owner", now, noNotify))!;
      const wrong = encounter.choicesJson.find((choice) => choice.title === "Eat them all")!;
      const before = PetResponseV1Schema.parse(await getPet(db, "owner")).pet!.stats;
      const outcome = await resolvePetEncounter(db, "owner", { encounterId: encounter.id, choiceId: wrong.id }, now, noNotify);
      expect(outcome).toMatchObject({ correct: false, sickened: true, medicine: 0 });
      let pet = PetResponseV1Schema.parse(await getPet(db, "owner")).pet!;
      expect(pet.stats.happiness).toBe(before.happiness - 6);
      expect(pet.stats.hp).toBe(before.hp - 8);
      expect(pet.illness?.name).toBeTruthy();

      await expect(givePetMedicine(db, "owner", noNotify)).rejects.toMatchObject({ status: 422, code: "PET_NO_MEDICINE" });
      await db.update(userPets).set({ medicine: 2 }).where(eq(userPets.userId, "owner"));
      await givePetMedicine(db, "owner", noNotify);
      pet = PetResponseV1Schema.parse(await getPet(db, "owner")).pet!;
      expect(pet.illness).toBeNull();
      expect(pet.medicine).toBe(1);
      await expect(givePetMedicine(db, "owner", noNotify)).rejects.toMatchObject({ status: 422, code: "PET_NOT_ILL" });
      const kinds = (await listPetEvents(db, "owner", { limit: 10 })).events.map((event) => event.kind);
      expect(kinds).toEqual(expect.arrayContaining(["encounter", "illness", "medicine"]));
    } finally {
      await close();
    }
  });

  it("refuses an expired encounter", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-10-05T21:00:00.000Z"));
    const { db, close } = await setup();
    try {
      const encounter = (await maybeStartEncounter(db, "owner", new Date("2026-10-05T21:00:00.000Z"), noNotify))!;
      const later = new Date("2026-10-06T10:00:00.000Z");
      expect(PetResponseV1Schema.parse(await getPet(db, "owner")).pet!.encounter).toBeTruthy();
      vi.setSystemTime(later);
      expect(PetResponseV1Schema.parse(await getPet(db, "owner")).pet!.encounter).toBeNull();
      await expect(resolvePetEncounter(db, "owner", { encounterId: encounter.id, choiceId: encounter.choicesJson[0].id }, later, noNotify))
        .rejects.toMatchObject({ status: 410 });
      const stored = (await db.select().from(petEncounters).where(eq(petEncounters.id, encounter.id)))[0];
      expect(stored.state).toBe("open");
    } finally {
      await close();
    }
  });

  it("drains an ill pet on each visit until it gets over it on its own", async () => {
    const { db, close } = await setup();
    try {
      const row = (await db.select().from(userPets).where(eq(userPets.userId, "owner")))[0];
      const since = new Date("2026-10-05T04:00:00.000Z");
      await db.update(userPets).set({ illnessJson: { name: "a fever", since: since.toISOString() } }).where(eq(userPets.userId, "owner"));
      // Early morning, so no encounter is due and only the visit itself moves the stats.
      await visitPet(db, "owner", row.lifeId!, row.lifeRunId!, noNotify, new Date("2026-10-05T05:00:00.000Z"));
      let events = (await listPetEvents(db, "owner", { limit: 5 })).events;
      expect(events[0].detail).toContain("Still ill with a fever");
      expect(events[0].debug.illness).toBe("a fever");

      const recovered = new Date(since.getTime() + ILLNESS_RECOVERY_HOURS * 3_600_000 + 60_000);
      await visitPet(db, "owner", row.lifeId!, row.lifeRunId!, noNotify, recovered);
      events = (await listPetEvents(db, "owner", { limit: 5 })).events;
      expect(events.map((event) => event.title)).toContain("Got better");
      expect(PetResponseV1Schema.parse(await getPet(db, "owner")).pet!.illness).toBeNull();
    } finally {
      await close();
    }
  });
});
