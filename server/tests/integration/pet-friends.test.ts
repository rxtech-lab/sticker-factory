import { eq } from "drizzle-orm";
import { afterEach, describe, expect, it, vi } from "vitest";
import { setAiProviderForTests } from "@/lib/ai/gateway";
import type { AiPetFriendContext } from "@/lib/ai/gateway-contracts";
import type { StickerConfiguration } from "@/lib/contracts/configuration";
import { chatMessages, generationJobs, petFriends, stickers, userPets } from "@/lib/db/schema";
import { setPetRandomForTests } from "@/lib/pets/log";
import { beginPetFriendPlan, failPetFriend, finishPetFriend, markPetFriendSeen, maybeMeetPetFriend, setPetFriendStarterForTests } from "@/lib/services/pet-friends";
import { listPetEvents } from "@/lib/services/pet-state";
import { getPet, setPet } from "@/lib/services/pets";
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
      options: [{ id: "calm", label: "Calm" }, { id: "happy", label: "Happy" }] },
  ],
  variants: [],
};

const actions = async () => [
  { title: "Juggle", description: "Juggle three berries.", effects: { happiness: 4, hp: 0, energy: -2, gold: 0 } },
];

const puddle = { name: "Puddle", brief: "A round raindrop sprite with a leaf umbrella.", story: "We met splashing by the window.",
  greeting: "This is Puddle! We splashed all day." };

describe("pet friends", () => {
  afterEach(() => {
    setAiProviderForTests(undefined);
    setObjectStoreForTests(undefined);
    setPetRandomForTests(undefined);
    setPetFriendStarterForTests(undefined);
    delete process.env.PET_FRIEND_CHANCE;
  });

  async function setup() {
    setPetRandomForTests(() => 0.01);
    const { db, close } = await createTestDatabase();
    setObjectStoreForTests(new MemoryObjectStore());
    await seedUser(db, "owner");
    const pet = await seedPublishedSticker(db, "owner", { title: "Loaf", kind: "animated", controllable: true, configuration });
    await db.update(stickers).set({ controllable: true }).where(eq(stickers.id, pet.stickerId));
    setAiProviderForTests({ ...unusedAiProvider, generatePetActions: actions });
    await setPet(db, "owner", { stickerId: pet.stickerId });
    await db.update(userPets).set({
      contextJson: { latitude: 51.5, longitude: -0.1, timeZone: "Europe/London", updatedAt: new Date().toISOString() },
      signalsJson: { weather: { kind: "rainy", temperatureC: 12, isDay: true }, tomorrow: null, stepsToday: null, headlines: [] },
      statusJson: { values: { mood: "calm" }, caption: "Rain again…" },
    } as Partial<typeof userPets.$inferInsert>).where(eq(userPets.userId, "owner"));
    return { db, close, pet };
  }

  it("meets a friend from the weather, place and mood, and holds to one at a time and the cooldown", async () => {
    const { db, close } = await setup();
    try {
      const seen: AiPetFriendContext[] = [];
      setAiProviderForTests({ ...unusedAiProvider, generatePetActions: actions,
        meetPetFriend: async (input) => { seen.push(input); return puddle; } });
      const started: string[] = [];
      setPetFriendStarterForTests(async (_userId, id) => { started.push(id); return "run"; });

      const friend = await maybeMeetPetFriend(db, "owner", { happening: "Rain shower: it started pouring." });
      expect(friend).toMatchObject({ name: "Puddle", state: "planning" });
      expect(started).toEqual([friend!.id]);
      expect(seen[0]).toMatchObject({ petTitle: "Loaf", mood: "Rain again…", happening: "Rain shower: it started pouring.",
        location: { latitude: 51.5, longitude: -0.1 } });
      expect(seen[0].signals?.weather?.kind).toBe("rainy");

      // One being made holds the next out, and so does the cooldown once it is done.
      expect(await maybeMeetPetFriend(db, "owner")).toBeNull();
      await db.update(petFriends).set({ state: "ready" }).where(eq(petFriends.id, friend!.id));
      expect(await maybeMeetPetFriend(db, "owner")).toBeNull();
      // A missed roll meets nobody.
      setPetRandomForTests(() => 0.99);
      expect(await maybeMeetPetFriend(db, "owner", { now: new Date(Date.now() + 72 * 3_600_000) })).toBeNull();
      expect(seen).toHaveLength(1);
    } finally {
      await close();
    }
  });

  it("plans the friend as a new controllable sticker for free, then welcomes the owner once", async () => {
    const { db, close } = await setup();
    try {
      setAiProviderForTests({ ...unusedAiProvider, generatePetActions: actions, meetPetFriend: async () => puddle });
      setPetFriendStarterForTests(async () => "run");
      const friend = (await maybeMeetPetFriend(db, "owner"))!;

      const jobId = await beginPetFriendPlan(db, "owner", friend.id);
      const [row] = await db.select().from(petFriends).where(eq(petFriends.id, friend.id));
      const [sticker] = await db.select().from(stickers).where(eq(stickers.id, row.stickerId!));
      expect(sticker).toMatchObject({ ownerId: "owner", title: "Puddle", kind: "animated", controllable: true });
      const [job] = await db.select().from(generationJobs).where(eq(generationJobs.id, jobId!));
      expect(job).toMatchObject({ kind: "plan", origin: "pet", reservationId: null, reservationAmount: 0, stickerId: sticker.id });
      const [message] = await db.select().from(chatMessages).where(eq(chatMessages.jobId, jobId!));
      expect(message.content).toContain("leaf umbrella");
      expect(message.content).toContain("controllable character");
      // A replayed step reuses the sticker and the job.
      expect(await beginPetFriendPlan(db, "owner", friend.id)).toBe(jobId);
      expect(await db.select().from(stickers).where(eq(stickers.title, "Puddle"))).toHaveLength(1);

      // Built and published elsewhere; the friend shows once it is ready.
      expect((await getPet(db, "owner")).pet!.friend).toBeNull();
      const alerts: Array<{ id: string; title: string; body: string }> = [];
      expect(await finishPetFriend(db, "owner", friend.id, async (_db, _userId, alert) => { alerts.push(alert); })).toBe(true);
      expect(alerts).toEqual([{ id: friend.id, title: "Loaf met a new friend!", body: puddle.greeting }]);
      const pet = (await getPet(db, "owner")).pet!;
      expect(pet.friend).toMatchObject({ id: friend.id, name: "Puddle", greeting: puddle.greeting, sticker: { id: sticker.id } });
      expect(pet.status?.caption).toBe(puddle.greeting);
      expect((await listPetEvents(db, "owner", { limit: 1 })).events[0]).toMatchObject({ kind: "friend", title: "Met Puddle" });

      // Finished is finished, and welcomed is welcomed.
      await failPetFriend(db, "owner", friend.id, "late");
      expect(await finishPetFriend(db, "owner", friend.id, async () => { throw new Error("no second push"); })).toBe(false);
      await markPetFriendSeen(db, "owner", friend.id);
      await markPetFriendSeen(db, "owner", friend.id);
      expect((await getPet(db, "owner")).pet!.friend).toBeNull();
      await expect(markPetFriendSeen(db, "owner", crypto.randomUUID())).rejects.toMatchObject({ code: "PET_FRIEND_NOT_FOUND" });
    } finally {
      await close();
    }
  });
});
