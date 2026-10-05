import { eq } from "drizzle-orm";
import { afterEach, describe, expect, it } from "vitest";
import { generationJobs, userWallets } from "@/lib/db/schema";
import { setAiProviderForTests } from "@/lib/ai/gateway";
import { setPetRandomForTests } from "@/lib/pets/log";
import { DAILY_GOLD } from "@/lib/pets/daily-gold";
import { STARTING_GOLD } from "@/lib/pets/stats";
import { listPetEvents } from "@/lib/services/pet-state";
import { grantStickerGold, STICKER_GOLD } from "@/lib/services/pet-wallet";
import { clearPet, getPet, interactWithPet, setPet } from "@/lib/services/pets";
import { MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";

describe("pet wallet", () => {
  afterEach(() => {
    setObjectStoreForTests(undefined);
    setPetRandomForTests(undefined);
    setAiProviderForTests(undefined);
  });

  async function setup() {
    setPetRandomForTests(() => 0.5);
    const { db, close } = await createTestDatabase();
    setObjectStoreForTests(new MemoryObjectStore());
    await seedUser(db, "owner");
    const loaf = await seedPublishedSticker(db, "owner", { title: "Loaf", kind: "animated", controllable: true });
    return { db, close, loaf };
  }

  async function finishedJob(db: Awaited<ReturnType<typeof setup>>["db"], stickerId: string, origin: "user" | "pet" = "user") {
    const id = crypto.randomUUID();
    await db.insert(generationJobs).values({ id, ownerId: "owner", stickerId, kind: "image", state: "succeeded", origin });
    return id;
  }

  it("keeps the owner's gold across pets, even after letting one go", async () => {
    const { db, close, loaf } = await setup();
    try {
      const first = (await setPet(db, "owner", { stickerId: loaf.stickerId })).pet!;
      const dance = first.actions.find((action) => action.effects.gold < 0)!;
      await interactWithPet(db, "owner", { actionId: dance.id }, async () => {});
      const spent = STARTING_GOLD + dance.effects.gold;
      expect((await getPet(db, "owner")).pet?.stats.gold).toBe(spent);

      await clearPet(db, "owner");
      const bun = await seedPublishedSticker(db, "owner", { title: "Bun", kind: "animated", controllable: true });
      const second = (await setPet(db, "owner", { stickerId: bun.stickerId })).pet!;
      expect(second.stats.gold).toBe(spent);
    } finally {
      await close();
    }
  });

  it("grants the daily gold once per local day, starting the day after the first purse", async () => {
    const { db, close, loaf } = await setup();
    try {
      await setPet(db, "owner", { stickerId: loaf.stickerId });
      expect((await getPet(db, "owner")).pet?.stats.gold).toBe(STARTING_GOLD);

      await db.update(userWallets).set({ dailyGoldDate: "2000-01-01" }).where(eq(userWallets.userId, "owner"));
      expect((await getPet(db, "owner")).pet?.stats.gold).toBe(STARTING_GOLD + DAILY_GOLD);
      expect((await getPet(db, "owner")).pet?.stats.gold).toBe(STARTING_GOLD + DAILY_GOLD);
      const { events } = await listPetEvents(db, "owner", { limit: 5 });
      expect(events.filter((event) => event.title === "Daily gold")).toHaveLength(1);
      expect(events[0]).toMatchObject({ kind: "special", effects: { gold: DAILY_GOLD },
        statsBefore: { gold: STARTING_GOLD }, statsAfter: { gold: STARTING_GOLD + DAILY_GOLD } });
    } finally {
      await close();
    }
  });

  it("pays for each sticker the owner makes once, with or without a pet", async () => {
    const { db, close, loaf } = await setup();
    try {
      const pizza = await seedPublishedSticker(db, "owner", { title: "Pizza Party" });
      const pushes: string[] = [];
      const notify = async (_db: typeof db, userId: string) => { pushes.push(userId); };

      // No pet yet: the gold waits in the wallet for the first one.
      await grantStickerGold(db, await finishedJob(db, pizza.stickerId), pizza.revisionId, notify);
      expect(pushes).toEqual([]);
      expect((await setPet(db, "owner", { stickerId: loaf.stickerId })).pet?.stats.gold).toBe(STARTING_GOLD + STICKER_GOLD);

      const job = await finishedJob(db, pizza.stickerId);
      await grantStickerGold(db, job, pizza.revisionId, notify);
      await grantStickerGold(db, job, pizza.revisionId, notify);
      // A turn that made nothing, and the pet's own growth, pay nothing.
      await grantStickerGold(db, await finishedJob(db, pizza.stickerId), undefined, notify);
      await grantStickerGold(db, await finishedJob(db, pizza.stickerId, "pet"), pizza.revisionId, notify);

      expect((await getPet(db, "owner")).pet?.stats.gold).toBe(STARTING_GOLD + 2 * STICKER_GOLD);
      expect(pushes).toEqual(["owner"]);
      const { events } = await listPetEvents(db, "owner", { limit: 5 });
      expect(events[0]).toMatchObject({ kind: "special", title: "Sticker reward", effects: { gold: STICKER_GOLD },
        statsAfter: { gold: STARTING_GOLD + 2 * STICKER_GOLD } });
    } finally {
      await close();
    }
  });
});
