import { eq } from "drizzle-orm";
import { readFileSync } from "node:fs";
import { SVGSceneSchema } from "@/lib/contracts/controllable";
import sharp from "sharp";
import { afterEach, describe, expect, it } from "vitest";
import { setAiProviderForTests } from "@/lib/ai/gateway";
import { PetResponseV1Schema } from "@/lib/contracts/api";
import { petRooms, petWeatherArt, stickerRevisions, stickers, userPets } from "@/lib/db/schema";
import { setPetRandomForTests } from "@/lib/pets/log";
import { drawPetWeatherArt, forgetPetWeatherArt, getPetWeatherArt } from "@/lib/services/pet-weather";
import { getPet, setPet } from "@/lib/services/pets";
import { MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";
import { unusedAiProvider } from "@/tests/helpers/workflow";

describe("pet weather art", () => {
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
    await seedUser(db, "friend");
    const pet = await seedPublishedSticker(db, "owner", { title: "Loaf", kind: "animated", controllable: true });
    await setPet(db, "owner", { stickerId: pet.stickerId });
    const rain = { weather: { kind: "rainy" as const, temperatureC: 12, isDay: true }, stepsToday: null, headlines: [] };
    await db.update(userPets).set({ signalsJson: rain }).where(eq(userPets.userId, "owner"));
    return { db, close, pet };
  }

  function drawer(prompts: string[], fail = false) {
    return {
      ...unusedAiProvider,
      generateStickerImage: async ({ prompt }: { prompt: string }) => {
        prompts.push(prompt);
        if (fail) throw new Error("model down");
        const bytes = await sharp({ create: { width: 300, height: 200, channels: 4, background: { r: 80, g: 120, b: 255, alpha: 1 } } })
          .png().toBuffer();
        return { bytes: new Uint8Array(bytes), mimeType: "image/png" as const };
      },
    };
  }

  it("draws each look once, in the pet's style, and serves it at any size", async () => {
    const { db, close } = await setup();
    try {
      expect((await getPet(db, "owner")).pet?.weatherArt).toBeNull();
      await expect(getPetWeatherArt(db, "owner", 128)).rejects.toMatchObject({ code: "PET_WEATHER_ART_NOT_READY" });

      const prompts: string[] = [];
      setAiProviderForTests(drawer(prompts));
      await drawPetWeatherArt(db, "owner");
      await drawPetWeatherArt(db, "owner");
      expect(prompts).toHaveLength(1);
      expect(prompts[0]).toContain("rain cloud");

      const pet = PetResponseV1Schema.parse(await getPet(db, "owner")).pet;
      expect(pet?.weatherArt).toMatchObject({ kind: "rainy", isDay: true });

      const art = await getPetWeatherArt(db, "owner", 128);
      expect(await sharp(art.bytes!).metadata()).toMatchObject({ width: 128, height: 128, format: "png" });
      expect((await getPetWeatherArt(db, "owner", 128, art.etag)).bytes).toBeNull();

      // Night is its own look.
      await db.update(userPets).set({ signalsJson: { weather: { kind: "rainy", temperatureC: 9, isDay: false }, stepsToday: null, headlines: [] } })
        .where(eq(userPets.userId, "owner"));
      expect((await getPet(db, "owner")).pet?.weatherArt).toBeNull();
      await drawPetWeatherArt(db, "owner");
      expect(prompts).toHaveLength(2);
      expect(prompts[1]).toContain("dusky");
    } finally {
      await close();
    }
  });

  it("does not ask again soon after a failed draw", async () => {
    const { db, close } = await setup();
    try {
      const prompts: string[] = [];
      setAiProviderForTests(drawer(prompts, true));
      await drawPetWeatherArt(db, "owner");
      await drawPetWeatherArt(db, "owner");
      expect(prompts).toHaveLength(1);
      expect((await db.select().from(petWeatherArt))[0]).toMatchObject({ state: "failed", r2Key: null });
      expect((await getPet(db, "owner")).pet?.weatherArt).toBeNull();

      // Hours later it is worth another try.
      setAiProviderForTests(drawer(prompts));
      await drawPetWeatherArt(db, "owner", new Date(Date.now() + 7 * 60 * 60 * 1000));
      expect(prompts).toHaveLength(2);
      expect((await getPet(db, "owner")).pet?.weatherArt).toMatchObject({ kind: "rainy" });
    } finally {
      await close();
    }
  });

  it("keeps weather until the sticker revision changes or its artwork is forgotten", async () => {
    const { db, close, pet } = await setup();
    try {
      const prompts: string[] = [];
      setAiProviderForTests(drawer(prompts));
      await drawPetWeatherArt(db, "owner");
      const drawn = (await getPet(db, "owner")).pet?.weatherArt;
      expect(drawn).toMatchObject({ kind: "rainy" });

      // The pet grows: a new published revision becomes the active one.
      const [sticker] = await db.select().from(stickers).where(eq(stickers.id, pet.stickerId));
      const [revision] = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, sticker.activeRevisionId!));
      const grownId = crypto.randomUUID();
      await db.insert(stickerRevisions).values({ ...revision, id: grownId, parentRevisionId: revision.id, createdAt: new Date() });
      await db.update(stickers).set({ activeRevisionId: grownId }).where(eq(stickers.id, pet.stickerId));

      expect((await getPet(db, "owner")).pet?.weatherArt).toBeNull();
      await drawPetWeatherArt(db, "owner");
      expect(prompts).toHaveLength(2);
      const updated = (await getPet(db, "owner")).pet?.weatherArt;
      expect(updated?.key).not.toBe(drawn?.key);
      await drawPetWeatherArt(db, "owner");
      expect(prompts).toHaveLength(2);
      expect((await getPetWeatherArt(db, "owner", 128)).bytes).not.toBeNull();

      // A restyle forgets it; the next read draws it from the grown revision.
      await forgetPetWeatherArt(db, pet.stickerId);
      expect((await getPet(db, "owner")).pet?.weatherArt).toBeNull();
      await drawPetWeatherArt(db, "owner");
      expect(prompts).toHaveLength(3);
      expect((await db.select().from(petWeatherArt))[0]).toMatchObject({ stickerId: pet.stickerId, revisionId: grownId, state: "ready" });
      expect((await getPet(db, "owner")).pet?.weatherArt?.key).not.toBe(updated?.key);
    } finally {
      await close();
    }
  });

  it("draws the sky outside the window as four pieces once the pet lives in a room", async () => {
    const { db, close } = await setup();
    try {
      const prompts: string[] = [];
      setAiProviderForTests(drawer(prompts));
      // On the plain page there is no window, so only the sticker is drawn.
      await drawPetWeatherArt(db, "owner");
      expect(prompts).toHaveLength(1);
      expect((await getPet(db, "owner")).pet?.windowWeatherArt).toBeNull();

      const roomId = crypto.randomUUID();
      await db.insert(petRooms).values({
        id: roomId, userId: "owner", title: "Attic", description: "A cosy attic.", price: 40,
        effectsJson: { happiness: 1, hp: 0, energy: 0 }, artKey: crypto.randomUUID(), state: "owned", createdAt: new Date(),
      });
      await db.update(userPets).set({ roomId }).where(eq(userPets.userId, "owner"));
      await drawPetWeatherArt(db, "owner");
      await drawPetWeatherArt(db, "owner");
      expect(prompts).toHaveLength(2);
      expect(prompts[1]).toContain("2 by 2");
      expect(prompts[1]).toContain("raindrop");

      const pet = PetResponseV1Schema.parse(await getPet(db, "owner")).pet;
      expect(pet?.windowWeatherArt).toMatchObject({ kind: "rainy", isDay: true });
      expect(pet?.windowWeatherArt?.key).not.toBe(pet?.weatherArt?.key);

      const sheet = await getPetWeatherArt(db, "owner", 1024, null, pet?.windowWeatherArt?.key, "window");
      expect(await sharp(sheet.bytes!).metadata()).toMatchObject({ width: 1024, height: 1024, format: "png", hasAlpha: true });
      expect((await getPetWeatherArt(db, "owner", 1024, sheet.etag, null, "window")).bytes).toBeNull();
      // The sticker is still its own drawing.
      expect((await getPetWeatherArt(db, "owner", 128, sheet.etag)).bytes).not.toBeNull();
    } finally {
      await close();
    }
  });

  it("updates SVG scene weather without generating new sky or weather images", async () => {
    const { db, close } = await setup();
    try {
      const prompts: string[] = []; setAiProviderForTests(drawer(prompts));
      const scene = SVGSceneSchema.parse(JSON.parse(readFileSync(new URL("../../../StickerGeniOS/packages/AnimatedView/Tests/AnimatedViewTests/Fixtures/controllable-scene.json", import.meta.url), "utf8")));
      const roomId = crypto.randomUUID();
      await db.insert(petRooms).values({ id: roomId, userId: "owner", title: "SVG room", description: "A responsive room", price: 40,
        effectsJson: { happiness: 1, hp: 0, energy: 0 }, artKey: crypto.randomUUID(), state: "owned", sceneJson: scene, createdAt: new Date() });
      await db.update(userPets).set({ roomId }).where(eq(userPets.userId, "owner"));
      await drawPetWeatherArt(db, "owner");
      await db.update(userPets).set({ signalsJson: { weather: { kind: "stormy", temperatureC: 8, isDay: false }, stepsToday: null, headlines: [] } }).where(eq(userPets.userId, "owner"));
      await drawPetWeatherArt(db, "owner");
      expect(prompts).toEqual([]);
      expect(await db.select().from(petWeatherArt)).toEqual([]);
    } finally { await close(); }
  });

  it("draws nothing for a pet that has no weather", async () => {
    const { db, close } = await setup();
    try {
      await db.update(userPets).set({ signalsJson: null }).where(eq(userPets.userId, "owner"));
      const prompts: string[] = [];
      setAiProviderForTests(drawer(prompts));
      await drawPetWeatherArt(db, "owner");
      await drawPetWeatherArt(db, "friend");
      expect(prompts).toHaveLength(0);
      await expect(getPetWeatherArt(db, "friend", 128)).rejects.toMatchObject({ code: "PET_NOT_FOUND" });
    } finally {
      await close();
    }
  });
});
