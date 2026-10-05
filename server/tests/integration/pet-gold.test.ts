import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { setAiProviderForTests } from "@/lib/ai/gateway";
import { generationJobs, userWalletGrants } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { setPetRandomForTests } from "@/lib/pets/log";
import { STARTING_GOLD } from "@/lib/pets/stats";
import { grantStickerGold, STICKER_GOLD } from "@/lib/services/pet-wallet";
import { getPet, interactWithPet, setPet } from "@/lib/services/pets";
import { MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";

/**
 * Just enough of RxSubscription's balance API to hold one user's gold: keyed credits and debits,
 * and holds that settle or release. `down` makes every call fail, as an outage would.
 */
class FakeRxSubscription {
  amount = 0;
  reserved = 0;
  down = false;
  keys = new Set<string>();
  holds = new Map<string, { amount: number; open: boolean }>();
  log: string[] = [];

  async handle(url: URL, init: RequestInit | undefined): Promise<Response> {
    if (this.down) return Response.json({ error: "unavailable" }, { status: 503 });
    const body = init?.body ? JSON.parse(String(init.body)) as Record<string, unknown> : {};
    const path = url.pathname.replace("/api/v1/", "");
    const method = init?.method ?? "GET";
    if (method === "GET" && path === "balances") {
      return Response.json({ balances: [{ unit: "gold", name: "Gold", amount: this.amount, available: this.amount - this.reserved, precision: 0 }] });
    }
    const key = String(body.idempotencyKey);
    const duplicate = this.keys.has(key);
    this.keys.add(key);
    if (path === "balances") {
      if (!duplicate) {
        this.amount += body.operation === "credit" ? Number(body.amount) : -Number(body.amount);
        this.log.push(`${body.operation} ${body.amount}`);
      }
      return Response.json({ entryId: key, duplicate, balanceAfter: this.amount });
    }
    if (path === "balances/reserve") {
      const amount = Number(body.amount);
      if (!duplicate) {
        if (this.amount - this.reserved < amount) {
          this.keys.delete(key);
          return Response.json({ error: "insufficient_balance", available: this.amount - this.reserved, required: amount }, { status: 402 });
        }
        this.reserved += amount;
        this.holds.set(key, { amount, open: true });
        this.log.push(`hold ${amount}`);
      }
      return Response.json({ reservationId: key, amount, available: this.amount - this.reserved, status: "open", duplicate });
    }
    const [, reservationId, operation] = path.match(/^balances\/reservations\/(.+)\/(settle|release)$/) ?? [];
    const hold = this.holds.get(decodeURIComponent(reservationId ?? ""));
    if (hold && !duplicate && hold.open) {
      hold.open = false;
      this.reserved -= hold.amount;
      if (operation === "settle") this.amount -= Number(body.amount);
      this.log.push(`${operation} ${operation === "settle" ? body.amount : hold.amount}`);
    }
    return Response.json({ reservationId, status: "closed", duplicate });
  }
}

describe("pet gold in RxSubscription", () => {
  let billing: FakeRxSubscription;

  beforeEach(() => {
    billing = new FakeRxSubscription();
    vi.stubEnv("RX_SUBSCRIPTION_URL", "https://billing.example.test");
    vi.stubEnv("RX_SUBSCRIPTION_API_KEY", "rxs_sandbox_test");
    vi.stubGlobal("fetch", (input: URL | string, init?: RequestInit) => billing.handle(new URL(String(input)), init));
  });

  afterEach(() => {
    vi.unstubAllEnvs();
    vi.unstubAllGlobals();
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

  it("keeps the starting purse and every spend in RxSubscription, once each", async () => {
    const { db, close, loaf } = await setup();
    try {
      const pet = (await setPet(db, "owner", { stickerId: loaf.stickerId })).pet!;
      expect(pet.stats.gold).toBe(STARTING_GOLD);
      expect(billing.log).toEqual([`credit ${STARTING_GOLD}`]);

      const dance = pet.actions.find((action) => action.effects.gold < 0)!;
      await interactWithPet(db, "owner", { actionId: dance.id }, async () => {});
      expect(billing.log).toEqual([`credit ${STARTING_GOLD}`, `hold ${-dance.effects.gold}`, `settle ${-dance.effects.gold}`]);
      expect(billing.amount).toBe(STARTING_GOLD + dance.effects.gold);
      expect(billing.reserved).toBe(0);
      expect((await getPet(db, "owner")).pet?.stats.gold).toBe(STARTING_GOLD + dance.effects.gold);
    } finally {
      await close();
    }
  });

  it("spends gold a points pack brought, and refuses what the owner cannot afford", async () => {
    const { db, close, loaf } = await setup();
    try {
      const pet = (await setPet(db, "owner", { stickerId: loaf.stickerId })).pet!;
      const dance = pet.actions.find((action) => action.effects.gold < 0)!;
      billing.amount = 0;
      await expect(interactWithPet(db, "owner", { actionId: dance.id }, async () => {}))
        .rejects.toMatchObject({ code: "PET_NOT_ENOUGH_GOLD" } satisfies Partial<ApiError>);
      expect(billing.reserved).toBe(0);

      // A points pack credits gold straight into RxSubscription; the pet sees it on the next read.
      billing.amount = 500;
      expect((await getPet(db, "owner")).pet?.stats.gold).toBe(500);
      await interactWithPet(db, "owner", { actionId: dance.id }, async () => {});
      expect(billing.amount).toBe(500 + dance.effects.gold);
    } finally {
      await close();
    }
  });

  it("carries gold earned during an outage when the service is back, without paying it twice", async () => {
    const { db, close, loaf } = await setup();
    try {
      await setPet(db, "owner", { stickerId: loaf.stickerId });
      const pizza = await seedPublishedSticker(db, "owner", { title: "Pizza Party" });
      const jobId = crypto.randomUUID();
      await db.insert(generationJobs).values({ id: jobId, ownerId: "owner", stickerId: pizza.stickerId, kind: "image", state: "succeeded", origin: "user" });

      billing.down = true;
      await grantStickerGold(db, jobId, pizza.revisionId, async () => {});
      const queued = await db.select().from(userWalletGrants).where(eq(userWalletGrants.id, `sticker:${jobId}`));
      expect(queued).toMatchObject([{ gold: STICKER_GOLD, settledAt: null }]);

      billing.down = false;
      expect((await getPet(db, "owner")).pet?.stats.gold).toBe(STARTING_GOLD + STICKER_GOLD);
      await grantStickerGold(db, jobId, pizza.revisionId, async () => {});
      expect((await getPet(db, "owner")).pet?.stats.gold).toBe(STARTING_GOLD + STICKER_GOLD);
      expect(billing.log).toEqual([`credit ${STARTING_GOLD}`, `credit ${STICKER_GOLD}`]);
    } finally {
      await close();
    }
  });
});
