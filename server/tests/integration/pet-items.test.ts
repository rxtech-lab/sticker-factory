import sharp from "sharp";
import { afterEach, describe, expect, it, vi } from "vitest";
import { setAiProviderForTests } from "@/lib/ai/gateway";
import type { AiPetItem, AiPetItemsContext } from "@/lib/ai/gateway-contracts";
import { PET_MEDICINE_PRICE, PET_STOCK_MAX, PetResponseV1Schema } from "@/lib/contracts/api";
import type { Database } from "@/lib/db/client";
import { ApiError } from "@/lib/http/errors";
import { setPetRandomForTests } from "@/lib/pets/log";
import { givePetMedicine } from "@/lib/services/pet-encounters";
import { getPetItemArt, getPetItemArtById, refreshPetItems } from "@/lib/services/pet-items";
import { buyPetItem, buyPetMedicine } from "@/lib/services/pet-shop";
import { getPet, interactWithPet, setPet } from "@/lib/services/pets";
import { MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { setGoldForTests } from "@/tests/helpers/gold";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";
import { unusedAiProvider } from "@/tests/helpers/workflow";

const HOUR = 60 * 60 * 1000;
const COLORS = { red: [255, 0, 0], green: [0, 128, 0], blue: [0, 0, 255], yellow: [255, 255, 0], purple: [128, 0, 128], cyan: [0, 255, 255] } as const;
type Color = keyof typeof COLORS;

afterEach(() => {
  vi.useRealTimers();
  setAiProviderForTests(undefined);
  setObjectStoreForTests(undefined);
  setPetRandomForTests(undefined);
});

async function sheetOf(colors: Color[]): Promise<Uint8Array> {
  const columns = colors.length === 1 ? 1 : 2;
  const rows = Math.ceil(colors.length / columns);
  const cells = colors.map((color, index) =>
    `<rect x="${(index % columns) * 512}" y="${Math.floor(index / columns) * 512}" width="512" height="512" fill="rgb(${COLORS[color].join(",")})"/>`);
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${columns * 512}" height="${rows * 512}">${cells.join("")}</svg>`;
  return new Uint8Array(await sharp(Buffer.from(svg)).png().toBuffer());
}

async function centerColor(bytes: Uint8Array | null): Promise<number[]> {
  return [...await sharp(bytes!).extract({ left: 32, top: 32, width: 1, height: 1 }).raw().toBuffer()].slice(0, 3);
}

function item(title: string, kind: AiPetItem["kind"], gold: number, shelfHours: number, keepsHours: number | null): AiPetItem {
  return { title, description: `Use ${title} with the pet.`, kind, effects: { happiness: 3, hp: 0, energy: -3, gold }, shelfHours, keepsHours };
}

async function expectApiError(promise: Promise<unknown>, code: string) {
  const error = await promise.catch((caught: unknown) => caught);
  expect(error).toBeInstanceOf(ApiError);
  expect((error as ApiError).code).toBe(code);
}

/** An owner with a pet and a shop the agent stocks from `batches` in turn, drawn in `colors`. */
async function setup(batches: AiPetItem[][], colors: Color[][]) {
  setPetRandomForTests(() => 0.5);
  const { db, close } = await createTestDatabase();
  setObjectStoreForTests(new MemoryObjectStore());
  await seedUser(db, "owner");
  const sticker = await seedPublishedSticker(db, "owner", { title: "Loaf", kind: "animated", controllable: true });
  const requests: (Pick<AiPetItemsContext, "minCount" | "maxCount"> & { keeping: string[] })[] = [];
  const drawings: { columns: number; rows: number; count: number }[] = [];
  setAiProviderForTests({
    ...unusedAiProvider,
    generatePetActions: async () => [{ title: "Wave", description: "Wave hello", effects: { happiness: 2, hp: 0, energy: -3, gold: 0 } }],
    generatePetItems: async ({ minCount, maxCount, keeping }) => {
      requests.push({ minCount, maxCount, keeping: keeping.map((kept) => kept.title) });
      return batches[requests.length - 1];
    },
    generateStickerImage: async ({ sheet }) => {
      drawings.push({ columns: sheet!.columns, rows: sheet!.rows, count: sheet!.count });
      return { bytes: await sheetOf(colors[drawings.length - 1]), mimeType: "image/png" };
    },
    respondToPetInteraction: async ({ action }) => ({ values: {}, caption: action.description }),
  });
  await setPet(db, "owner", { stickerId: sticker.stickerId });
  return { db, close, requests, drawings };
}

async function shelf(db: Database) {
  return PetResponseV1Schema.parse(await getPet(db, "owner")).pet!.items!;
}

describe("item shop", () => {
  it("stocks the shelf, lets each item leave at its own time, and restocks a few each day", async () => {
    const t0 = new Date("2026-10-05T08:00:00.000Z");
    vi.useFakeTimers({ toFake: ["Date"], now: t0 });
    const { db, close, requests, drawings } = await setup([
      [item("Strawberry", "food", -4, 12, 8), item("Kite", "toy", -6, 30, 48), item("Ball", "toy", 0, 72, null), item("Zoo Pass", "ticket", -12, 168, 120)],
      [item("Pie", "food", -5, 40, 24), item("Bubbles", "toy", 0, 20, 12)],
    ], [["red", "green", "blue", "yellow"], ["purple", "cyan"]]);
    try {
      await refreshPetItems(db, "owner");
      const first = await shelf(db);
      expect(requests[0]).toEqual({ minCount: 3, maxCount: 4, keeping: [] });
      expect(drawings[0]).toEqual({ columns: 2, rows: 2, count: 4 });
      expect(first.actions.map((shelved) => [shelved.title, shelved.leavesAt, shelved.keepsHours, shelved.kind])).toEqual([
        ["Strawberry", new Date(t0.getTime() + 12 * HOUR).toISOString(), 8, "food"],
        ["Kite", new Date(t0.getTime() + 30 * HOUR).toISOString(), 48, "toy"],
        ["Ball", new Date(t0.getTime() + 72 * HOUR).toISOString(), null, "toy"],
        ["Zoo Pass", new Date(t0.getTime() + 168 * HOUR).toISOString(), 120, "ticket"],
      ]);
      // The agent forgot the restorer; the last of the tied items becomes it, priced to match.
      expect(first.actions.filter((shelved) => shelved.effects.energy > 20).map((shelved) => shelved.title)).toEqual(["Zoo Pass"]);
      for (const [index, color] of (["red", "green", "blue", "yellow"] as const).entries()) {
        expect(await centerColor((await getPetItemArtById(db, "owner", first.actions[index].id, 64)).bytes)).toEqual([...COLORS[color]]);
        expect(await centerColor((await getPetItemArt(db, "owner", index, 64, null, first.artKey)).bytes)).toEqual([...COLORS[color]]);
      }

      // Later that day the strawberry has left the shelf, its picture with it; nothing new comes until tomorrow.
      vi.setSystemTime(new Date(t0.getTime() + 13 * HOUR));
      expect((await shelf(db)).actions.map((shelved) => shelved.title)).toEqual(["Kite", "Ball", "Zoo Pass"]);
      expect((await shelf(db)).artKey).not.toBe(first.artKey);
      await expectApiError(getPetItemArt(db, "owner", 0, 64, null, first.artKey), "PET_ITEMS_CHANGED");
      await refreshPetItems(db, "owner");
      expect(requests).toHaveLength(1);
      await expectApiError(getPetItemArtById(db, "owner", first.actions[0].id, 64), "PET_ITEM_NOT_FOUND");

      // The next morning the agent adds as many as it likes, up to three, beside what is left.
      vi.setSystemTime(new Date("2026-10-06T08:00:00.000Z"));
      await refreshPetItems(db, "owner");
      const second = await shelf(db);
      expect(requests[1]).toEqual({ minCount: 1, maxCount: 3, keeping: ["Kite", "Ball", "Zoo Pass"] });
      expect(drawings[1]).toEqual({ columns: 2, rows: 1, count: 2 });
      expect(second.actions.map((shelved) => shelved.title)).toEqual(["Kite", "Ball", "Zoo Pass", "Pie", "Bubbles"]);
      expect(second.actions.slice(0, 3)).toEqual(first.actions.slice(1));
      expect(await centerColor((await getPetItemArtById(db, "owner", second.actions[3].id, 64)).bytes)).toEqual([...COLORS.purple]);
      expect(await centerColor((await getPetItemArtById(db, "owner", second.actions[4].id, 64)).bytes)).toEqual([...COLORS.cyan]);
      // The shop kept its restorer, so the new items are everyday ones.
      expect(second.actions.filter((shelved) => shelved.effects.energy > 20)).toHaveLength(1);
    } finally {
      await close();
    }
  });

  it("sells medicine to a well pet and keeps it until it is needed", async () => {
    const { db, close } = await setup([[item("Ball", "toy", 0, 72, null), item("Pie", "food", -5, 40, 24), item("Kite", "toy", -6, 30, 48)]],
      [["red", "green", "blue"]]);
    try {
      await setGoldForTests(db, "owner", PET_MEDICINE_PRICE - 1);
      await expectApiError(buyPetMedicine(db, "owner", async () => {}), "PET_NOT_ENOUGH_GOLD");
      await setGoldForTests(db, "owner", 1000);
      await buyPetMedicine(db, "owner", async () => {});
      const pet = PetResponseV1Schema.parse(await getPet(db, "owner")).pet!;
      expect(pet.illness).toBeNull();
      expect(pet.medicine).toBe(1);
      expect(pet.medicinePrice).toBe(PET_MEDICINE_PRICE);
      expect(pet.stats.gold).toBe(1000 - PET_MEDICINE_PRICE);
      // A well pet keeps its dose rather than taking it.
      await expectApiError(givePetMedicine(db, "owner", async () => {}), "PET_NOT_ILL");
      for (let dose = 1; dose < PET_STOCK_MAX; dose += 1) await buyPetMedicine(db, "owner", async () => {});
      await expectApiError(buyPetMedicine(db, "owner", async () => {}), "PET_STOCK_FULL");
      expect((await getPet(db, "owner")).pet!.medicine).toBe(PET_STOCK_MAX);
    } finally {
      await close();
    }
  });

  it("keeps bought items in the bag until each expires, using the soonest first, and some never expire", async () => {
    const t0 = new Date("2026-10-05T08:00:00.000Z");
    vi.useFakeTimers({ toFake: ["Date"], now: t0 });
    const { db, close } = await setup([[
      item("Pie", "food", -8, 12, 10), item("Zoo Pass", "ticket", -12, 168, 120), item("Ball", "toy", -5, 72, null),
    ]], [["red", "green", "blue"]]);
    try {
      await refreshPetItems(db, "owner");
      const [pie, pass, ball] = (await shelf(db)).actions;
      await setGoldForTests(db, "owner", 100);
      await buyPetItem(db, "owner", { itemId: pie.id }, async () => {});
      vi.setSystemTime(new Date(t0.getTime() + 2 * HOUR));
      await buyPetItem(db, "owner", { itemId: pie.id }, async () => {});
      await buyPetItem(db, "owner", { itemId: pass.id }, async () => {});
      await buyPetItem(db, "owner", { itemId: ball.id }, async () => {});
      let pet = PetResponseV1Schema.parse(await getPet(db, "owner")).pet!;
      // The agent left out the restorer, so the ball became it, priced to match.
      expect(pet.stats.gold).toBe(100 + pie.effects.gold * 2 + pass.effects.gold + ball.effects.gold);
      expect(pet.bag).toEqual([
        { item: { ...pie, leavesAt: undefined }, count: 2, expiresAt: new Date(t0.getTime() + 10 * HOUR).toISOString() },
        { item: expect.objectContaining({ id: pass.id }), count: 1, expiresAt: new Date(t0.getTime() + 122 * HOUR).toISOString() },
        { item: expect.objectContaining({ id: ball.id }), count: 1, expiresAt: null },
      ]);

      // Using a pie uses the one expiring first, for free.
      const gold = pet.stats.gold;
      await interactWithPet(db, "owner", { actionId: pie.id, fromBag: true }, async () => {});
      pet = PetResponseV1Schema.parse(await getPet(db, "owner")).pet!;
      expect(pet.stats.gold).toBe(gold);
      expect(pet.bag?.[0]).toMatchObject({ count: 1, expiresAt: new Date(t0.getTime() + 12 * HOUR).toISOString() });

      // The other pie spoils, and with it gone from the shelf too, so does its picture.
      vi.setSystemTime(new Date(t0.getTime() + 13 * HOUR));
      expect((await getPet(db, "owner")).pet!.bag!.map((entry) => entry.item.title)).toEqual(["Zoo Pass", "Ball"]);
      await expectApiError(interactWithPet(db, "owner", { actionId: pie.id, fromBag: true }, async () => {}), "PET_BAG_ITEM_NOT_FOUND");
      await refreshPetItems(db, "owner");
      await expectApiError(getPetItemArtById(db, "owner", pie.id, 64), "PET_ITEM_NOT_FOUND");
      // The ball has left the shelf by now but is still in the bag, picture and all.
      vi.setSystemTime(new Date(t0.getTime() + 100 * HOUR));
      expect((await getPetItemArtById(db, "owner", ball.id, 64)).bytes?.length).toBeGreaterThan(0);

      // A year on, only what never expires is left.
      vi.setSystemTime(new Date(t0.getTime() + 365 * 24 * HOUR));
      expect((await getPet(db, "owner")).pet!.bag!.map((entry) => entry.item.title)).toEqual(["Ball"]);
    } finally {
      await close();
    }
  });
});
