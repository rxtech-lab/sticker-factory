import sharp from "sharp";
import { afterEach, expect, it } from "vitest";
import { setAiProviderForTests } from "@/lib/ai/gateway";
import { PetResponseV1Schema } from "@/lib/contracts/api";
import { getPet, interactWithPet, setPet } from "@/lib/services/pets";
import { getPetItemArt, refreshPetItems } from "@/lib/services/pet-items";
import { MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";
import { unusedAiProvider } from "@/tests/helpers/workflow";

afterEach(() => {
  setAiProviderForTests(undefined);
  setObjectStoreForTests(undefined);
});

it("generates one four-item sheet, serves its crops, and keeps the set for twelve hours", async () => {
  const { db, close } = await createTestDatabase();
  setObjectStoreForTests(new MemoryObjectStore());
  await seedUser(db, "owner");
  const sticker = await seedPublishedSticker(db, "owner", { title: "Loaf", kind: "animated", controllable: true });
  const svg = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024">
    <rect width="512" height="512" fill="red"/><rect x="512" width="512" height="512" fill="green"/>
    <rect y="512" width="512" height="512" fill="blue"/><rect x="512" y="512" width="512" height="512" fill="yellow"/>
  </svg>`);
  const sheet = await sharp(svg).png().toBuffer();
  let generations = 0;
  let drawings = 0;
  setAiProviderForTests({
    ...unusedAiProvider,
    generatePetActions: async () => [{ title: "Wave", description: "Wave hello",
      effects: { happiness: 2, hp: 0, energy: -3, gold: 0 } }],
    generatePetItems: async ({ signals }) => {
      generations += 1;
      return ["Ball", "Ribbon", "Bell", "Cushion"].map((title) => ({
        title, description: `Use ${title} with the pet in ${signals?.weather?.kind ?? "unknown weather"}.`,
        effects: { happiness: 3, hp: 0, energy: -3, gold: 0 },
      }));
    },
    generateStickerImage: async ({ sheet: grid }) => {
      expect(grid).toMatchObject({ columns: 2, rows: 2, count: 4, independentCells: true });
      drawings += 1;
      return { bytes: new Uint8Array(sheet), mimeType: "image/png" };
    },
    respondToPetInteraction: async ({ action }) => ({ values: {}, caption: action.description }),
  });
  try {
    await setPet(db, "owner", { stickerId: sticker.stickerId });
    const now = new Date("2026-10-05T00:00:00.000Z");
    await refreshPetItems(db, "owner", now);
    const first = PetResponseV1Schema.parse(await getPet(db, "owner")).pet!;
    expect(first.items?.actions).toHaveLength(4);
    // The agent forgot the restorer; the last of the tied items becomes it, priced to match.
    expect(first.items?.actions.map((item) => item.effects)).toEqual([
      { happiness: 3, hp: 0, energy: -3, gold: 0 }, { happiness: 3, hp: 0, energy: -3, gold: 0 },
      { happiness: 3, hp: 0, energy: -3, gold: 0 }, { happiness: 3, hp: 0, energy: 30, gold: -30 },
    ]);
    expect(generations).toBe(1);
    expect(drawings).toBe(1);
    for (const [index, expected] of [[0, [255, 0, 0]], [1, [0, 128, 0]], [2, [0, 0, 255]], [3, [255, 255, 0]]] as const) {
      const { bytes } = await getPetItemArt(db, "owner", index, 64);
      const pixel = await sharp(bytes!).extract({ left: 32, top: 32, width: 1, height: 1 }).raw().toBuffer();
      expect([...pixel].slice(0, 3)).toEqual([...expected]);
    }
    await refreshPetItems(db, "owner", now);
    expect(generations).toBe(1);
    const used = await interactWithPet(db, "owner", { actionId: first.items!.actions[0].id }, async () => {});
    expect(used.pet?.status?.caption).toContain("Ball");
    await refreshPetItems(db, "owner", now);
    expect(generations).toBe(1);
    await refreshPetItems(db, "owner", new Date(now.getTime() + 7 * 60 * 60 * 1000));
    expect(generations).toBe(1);
    expect((await getPet(db, "owner")).pet?.items).toEqual(first.items);
    await refreshPetItems(db, "owner", new Date(now.getTime() + 12 * 60 * 60 * 1000 - 1));
    expect(generations).toBe(1);
    await refreshPetItems(db, "owner", new Date(now.getTime() + 12 * 60 * 60 * 1000));
    expect(generations).toBe(2);
    expect(drawings).toBe(2);
    expect((await getPet(db, "owner")).pet?.items?.artKey).not.toBe(first.items?.artKey);
  } finally {
    await close();
  }
});
