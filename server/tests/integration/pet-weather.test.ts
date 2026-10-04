import { eq } from "drizzle-orm";
import sharp from "sharp";
import { afterEach, describe, expect, it } from "vitest";
import { setAiProviderForTests } from "@/lib/ai/gateway";
import { PetResponseV1Schema } from "@/lib/contracts/api";
import { petWeatherArt, userPets } from "@/lib/db/schema";
import { setPetRandomForTests } from "@/lib/pets/log";
import { drawPetWeatherArt, getPetWeatherArt } from "@/lib/services/pet-weather";
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
