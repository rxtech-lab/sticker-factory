import { eq } from "drizzle-orm";
import { afterEach, describe, expect, it } from "vitest";
import { PetResponseV1Schema, RecordPetSendResponseV1Schema } from "@/lib/contracts/api";
import { assets, packInstalls, stickerPackItems, stickerPacks, stickers, userPets } from "@/lib/db/schema";
import { getObjectStore, MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";
import { clearPet, getPet, getPetPose, interactWithPet, readPetSend, recordPetSend, sendPetPhoto, setPet } from "@/lib/services/pets";
import { notifyPetStatusChanged, PET_STATUS_PUSH_KIND } from "@/lib/notifications/pet";
import type { ApnsPush } from "@/lib/notifications/apns";
import { registerDeviceToken } from "@/lib/services/devices";
import sharp from "sharp";
import { fadingPet } from "@/tests/helpers/pet-documents";
import { setAiProviderForTests } from "@/lib/ai/gateway";
import { unusedAiProvider } from "@/tests/helpers/workflow";
import type { StickerConfiguration } from "@/lib/contracts/configuration";
import { listLibrarySections } from "@/lib/services/packs";
import { listStickers } from "@/lib/services/sticker-summaries";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";
import { setPetRandomForTests } from "@/lib/pets/log";

describe("pets", () => {
  afterEach(() => {
    setObjectStoreForTests(undefined);
    setPetRandomForTests(undefined);
  });

  async function setup() {
    // No jitter on a new pet's max HP, and above the chance a send rolls a random event.
    setPetRandomForTests(() => 0.5);
    const { db, close } = await createTestDatabase();
    setObjectStoreForTests(new MemoryObjectStore());
    await seedUser(db, "owner");
    await seedUser(db, "friend");
    const controllable = await seedPublishedSticker(db, "owner", { title: "Loaf", kind: "animated", controllable: true });
    const still = await seedPublishedSticker(db, "owner", { title: "Still" });
    return { db, close, controllable, still };
  }

  it("adopts, replaces and releases a controllable pet", async () => {
    const { db, close, controllable } = await setup();
    try {
      expect(await getPet(db, "owner")).toEqual({ pet: null });

      const adopted = PetResponseV1Schema.parse(await setPet(db, "owner", { stickerId: controllable.stickerId }));
      expect(adopted.pet?.sticker).toMatchObject({ id: controllable.stickerId, playbackRevisionId: controllable.revisionId });

      const second = await seedPublishedSticker(db, "owner", { title: "Bun", kind: "animated", controllable: true });
      await setPet(db, "owner", { stickerId: second.stickerId });
      expect((await getPet(db, "owner")).pet?.sticker.id).toBe(second.stickerId);

      expect(await clearPet(db, "owner")).toEqual({ pet: null });
      expect(await clearPet(db, "owner")).toEqual({ pet: null });
      expect(await getPet(db, "owner")).toEqual({ pet: null });
    } finally {
      await close();
    }
  });

  it("generates actions from the chosen sticker once and keeps their ids on re-adoption", async () => {
    const { db, close, controllable } = await setup();
    const seen: string[] = [];
    setAiProviderForTests({ ...unusedAiProvider, generatePetActions: async ({ petTitle, controls }) => {
      seen.push(`${petTitle}:${controls.length}`);
      return [{ title: `Wave to ${petTitle}`, description: `Wave at ${petTitle}'s ears.`,
        effects: { happiness: 3, hp: 0, energy: -1, gold: 0 } }];
    }, respondToPetInteraction: async ({ action }) => ({ values: {}, caption: action.description }) });
    try {
      const first = await setPet(db, "owner", { stickerId: controllable.stickerId });
      expect(first.pet?.actions).toMatchObject([{ title: "Wave to Loaf", effects: { happiness: 3, hp: 0, energy: -1 } }]);
      const again = await setPet(db, "owner", { stickerId: controllable.stickerId });
      expect(again.pet?.actions).toEqual(first.pet?.actions);
      expect(seen).toEqual(["Loaf:0"]);
      const waved = await interactWithPet(db, "owner", { actionId: first.pet!.actions[0].id }, async () => {});
      expect(waved.pet).toMatchObject({ stats: { happiness: 83, hp: 100, energy: 79 }, status: { caption: "Wave at Loaf's ears." } });
      await expect(interactWithPet(db, "owner", { actionId: crypto.randomUUID() }, async () => {}))
        .rejects.toMatchObject({ code: "PET_ACTION_NOT_AVAILABLE" });
    } finally {
      setAiProviderForTests(undefined);
      await close();
    }
  });

  it("keeps an existing pet readable while action generation is unavailable", async () => {
    const { db, close, controllable } = await setup();
    try {
      await setPet(db, "owner", { stickerId: controllable.stickerId });
      await db.update(userPets).set({ actionsJson: null }).where(eq(userPets.userId, "owner"));
      setAiProviderForTests({ ...unusedAiProvider, generatePetActions: async () => { throw new Error("model down"); } });
      expect(PetResponseV1Schema.parse(await getPet(db, "owner")).pet?.actions).toEqual([]);
      setAiProviderForTests(undefined);
      expect((await getPet(db, "owner")).pet?.actions).toHaveLength(3);
    } finally {
      setAiProviderForTests(undefined);
      await close();
    }
  });

  it("applies bounded care stats and a model response, then resets them for a different pet", async () => {
    const { db, close, controllable } = await setup();
    try {
      const first = PetResponseV1Schema.parse(await setPet(db, "owner", { stickerId: controllable.stickerId }));
      expect(first.pet?.stats).toEqual({ happiness: 80, hp: 100, energy: 80, gold: 20 });
      expect(first.pet?.actions.map((action) => action.title)).toEqual(["Greet Loaf", "Dance with Loaf", "Rest with Loaf"]);
      const notified: string[] = [];
      const notify = async (_db: typeof db, userId: string) => { notified.push(userId); };
      const played = PetResponseV1Schema.parse(await interactWithPet(db, "owner", { actionId: first.pet!.actions[1].id }, notify));
      expect(played.pet).toMatchObject({
        stats: { happiness: 94, hp: 100, energy: 68, gold: 15 },
        status: { caption: "Loaf: Move together with Loaf." },
      });
      let latest = played;
      for (let index = 0; index < 10; index += 1) {
        const rest = latest.pet!.actions.find((action) => action.title === "Rest with Loaf")!;
        latest = PetResponseV1Schema.parse(await interactWithPet(db, "owner", { actionId: rest.id }, notify));
      }
      expect((await getPet(db, "owner")).pet?.stats.energy).toBe(100);
      expect(notified).toHaveLength(11);

      const other = await seedPublishedSticker(db, "owner", { title: "Bun", kind: "animated", controllable: true });
      await setPet(db, "owner", { stickerId: other.stickerId });
      expect((await getPet(db, "owner")).pet?.stats).toEqual({ happiness: 80, hp: 100, energy: 80, gold: 20 });
      expect((await getPet(db, "owner")).pet?.status).toBeNull();
      await expect(interactWithPet(db, "owner", { actionId: first.pet!.actions[1].id }, notify))
        .rejects.toMatchObject({ code: "PET_ACTION_NOT_AVAILABLE" });
    } finally {
      await close();
    }
  });

  it("lets the agent replace the actions with ones fitting the mood an interaction leaves", async () => {
    const { db, close, controllable } = await setup();
    const asked: { stats?: unknown; mood?: string | null; previous?: string[] }[] = [];
    try {
      const adopted = await setPet(db, "owner", { stickerId: controllable.stickerId });
      setAiProviderForTests({ ...unusedAiProvider,
        generatePetActions: async ({ stats, mood, previous }) => {
          asked.push({ stats, mood, previous });
          return [{ title: "Nap in a sunbeam", description: "Curl up somewhere warm.", effects: { happiness: 2, hp: 4, energy: 15, gold: 0 } }];
        },
        respondToPetInteraction: async ({ action }) => ({ values: {}, caption: action.description }) });
      const danced = PetResponseV1Schema.parse(await interactWithPet(db, "owner", { actionId: adopted.pet!.actions[1].id }, async () => {}));
      expect(danced.pet!.actions).toMatchObject([{ title: "Nap in a sunbeam" }]);
      expect(asked).toEqual([{ stats: { happiness: 94, hp: 100, energy: 68, gold: 15 },
        mood: "Just did “Dance with Loaf” with its owner: Move together with Loaf.",
        previous: ["Greet Loaf", "Dance with Loaf", "Rest with Loaf"] }]);
      await expect(interactWithPet(db, "owner", { actionId: adopted.pet!.actions[0].id }, async () => {}))
        .rejects.toMatchObject({ code: "PET_ACTION_NOT_AVAILABLE" });

      // An agent that cannot think of new actions leaves the pet with the ones it has.
      setAiProviderForTests({ ...unusedAiProvider,
        generatePetActions: async () => { throw new Error("model down"); },
        respondToPetInteraction: async ({ action }) => ({ values: {}, caption: action.description }) });
      const napped = await interactWithPet(db, "owner", { actionId: danced.pet!.actions[0].id }, async () => {});
      expect(napped.pet).toMatchObject({ status: { caption: "Curl up somewhere warm." }, actions: danced.pet!.actions });
    } finally {
      setAiProviderForTests(undefined);
      await close();
    }
  });

  it("spends and earns gold, and refuses an action the pet cannot afford", async () => {
    const { db, close, controllable } = await setup();
    try {
      await setPet(db, "owner", { stickerId: controllable.stickerId, context: { latitude: 22.3193, longitude: 114.1694, timeZone: "Asia/Hong_Kong" } });
      const seen: { localTime?: string | null; location?: unknown }[] = [];
      setAiProviderForTests({ ...unusedAiProvider,
        generatePetActions: async ({ localTime, location }) => {
          seen.push({ localTime, location });
          return [
            { title: "Busk together", description: "Sing on the corner for coins.", effects: { happiness: 3, hp: 0, energy: -6, gold: 15 } },
            { title: "Buy a cake", description: "Share a fancy cake.", effects: { happiness: 12, hp: 2, energy: 0, gold: -40 } },
          ];
        },
        respondToPetInteraction: async ({ action }) => ({ values: {}, caption: action.description }) });
      await db.update(userPets).set({ actionsJson: null }).where(eq(userPets.userId, "owner"));
      const offered = PetResponseV1Schema.parse(await getPet(db, "owner")).pet!;
      expect(seen[0].location).toEqual({ latitude: 22.32, longitude: 114.17 });
      expect(seen[0].localTime).toMatch(/\d{2}:\d{2}/);

      const cake = offered.actions.find((action) => action.title === "Buy a cake")!;
      await expect(interactWithPet(db, "owner", { actionId: cake.id }, async () => {}))
        .rejects.toMatchObject({ code: "PET_NOT_ENOUGH_GOLD" });
      let pet = offered;
      for (let index = 0; index < 2; index += 1) {
        const busk = pet.actions.find((action) => action.title === "Busk together")!;
        pet = PetResponseV1Schema.parse(await interactWithPet(db, "owner", { actionId: busk.id }, async () => {})).pet!;
      }
      expect(pet.stats.gold).toBe(50);
      const bought = await interactWithPet(db, "owner", { actionId: pet.actions.find((action) => action.title === "Buy a cake")!.id }, async () => {});
      expect(bought.pet?.stats.gold).toBe(10);
    } finally {
      setAiProviderForTests(undefined);
      await close();
    }
  });

  it("shows the pet a picture: it looks, reacts, and is offered actions for its new mood", async () => {
    const { db, close, controllable } = await setup();
    async function upload(mimeType: string) {
      const id = crypto.randomUUID();
      const bytes = new Uint8Array(await sharp({ create: { width: 8, height: 8, channels: 3, background: "#f80" } }).png().toBuffer());
      await getObjectStore().put(`photos/${id}`, { bytes, contentType: mimeType });
      await db.insert(assets).values({ id, ownerId: "owner", kind: "reference", state: "ready", r2Key: `photos/${id}`, mimeType,
        byteSize: bytes.byteLength, createdAt: new Date(), readyAt: new Date() });
      return id;
    }
    const looked: string[] = [];
    try {
      await expect(sendPetPhoto(db, "owner", { assetId: crypto.randomUUID() }, async () => {}))
        .rejects.toMatchObject({ code: "PET_NOT_FOUND" });
      await setPet(db, "owner", { stickerId: controllable.stickerId });
      setAiProviderForTests({ ...unusedAiProvider,
        reactToPetPhoto: async ({ photo }) => {
          looked.push(photo.mimeType);
          return { values: {}, caption: "A cake! Is it for me?", effects: { happiness: 6, hp: 0, energy: 1 } };
        },
        generatePetActions: async ({ mood }) => [{ title: "Share the cake", description: mood ?? "", effects: { happiness: 5, hp: 2, energy: 0, gold: -5 } }] });
      const notified: string[] = [];
      const shown = PetResponseV1Schema.parse(await sendPetPhoto(db, "owner", { assetId: await upload("image/png") },
        async (_db, userId) => { notified.push(userId); })).pet!;
      expect(looked).toEqual(["image/jpeg"]);
      expect(notified).toEqual(["owner"]);
      expect(shown).toMatchObject({ status: { caption: "A cake! Is it for me?" }, stats: { happiness: 88, hp: 100, energy: 80, gold: 20 },
        actions: [{ title: "Share the cake", description: "A cake! Is it for me? (after its owner showed it a picture)" }] });

      await expect(sendPetPhoto(db, "owner", { assetId: await upload("image/gif") }, async () => {}))
        .rejects.toMatchObject({ code: "PET_PHOTO_NOT_IMAGE" });
      await expect(sendPetPhoto(db, "owner", { assetId: crypto.randomUUID() }, async () => {}))
        .rejects.toMatchObject({ code: "INVALID_ASSET_REFERENCE" });
    } finally {
      setAiProviderForTests(undefined);
      await close();
    }
  });

  it("keeps stats and dialogue unchanged when the pet cannot answer", async () => {
    const { db, close, controllable } = await setup();
    try {
      const adopted = await setPet(db, "owner", { stickerId: controllable.stickerId });
      setAiProviderForTests({ ...unusedAiProvider, respondToPetInteraction: async () => { throw new Error("model down"); } });
      await expect(interactWithPet(db, "owner", { actionId: adopted.pet!.actions[0].id }, async () => {})).rejects.toThrow("model down");
      expect((await getPet(db, "owner")).pet).toMatchObject({ stats: { happiness: 80, hp: 100, energy: 80 }, status: null });
    } finally {
      setAiProviderForTests(undefined);
      await close();
    }
  });

  it("refuses a sticker that cannot be posed or that the caller cannot reach", async () => {
    const { db, close, controllable, still } = await setup();
    try {
      await expect(setPet(db, "owner", { stickerId: still.stickerId })).rejects.toMatchObject({ status: 404, code: "PET_NOT_AVAILABLE" });
      await expect(setPet(db, "friend", { stickerId: controllable.stickerId })).rejects.toMatchObject({ status: 404, code: "PET_NOT_AVAILABLE" });
      await expect(setPet(db, "owner", { stickerId: crypto.randomUUID() })).rejects.toMatchObject({ code: "PET_NOT_AVAILABLE" });
    } finally {
      await close();
    }
  });

  it("lets a friend adopt a member of an installed pack, and drops it when the pack is uninstalled", async () => {
    const { db, close, controllable } = await setup();
    try {
      const packId = crypto.randomUUID();
      const now = new Date();
      await db.insert(stickerPacks).values({
        id: packId, creatorId: "owner", slug: `pets-${packId.slice(0, 8)}`, title: "Pets", state: "published",
        createdAt: now, updatedAt: now,
      });
      await db.insert(stickerPackItems).values({ packId, stickerId: controllable.stickerId, position: 0, addedAt: now });
      await db.insert(packInstalls).values({ packId, userId: "friend", state: "installed", acquisition: "free", installedAt: now });

      // A still in the same pack is not offered; the pack section shows only what can be posed.
      const still = await seedPublishedSticker(db, "owner", { title: "Rock" });
      await db.insert(stickerPackItems).values({ packId, stickerId: still.stickerId, position: 1, addedAt: now });
      const offered = await listLibrarySections(db, "friend", { controllable: true });
      expect(offered.sections.map((section) => [section.id, section.stickers.map((sticker) => sticker.id)]))
        .toEqual([["mine", []], [`pack:${packId}`, [controllable.stickerId]]]);

      const adopted = await setPet(db, "friend", { stickerId: controllable.stickerId });
      expect(adopted.pet?.sticker.id).toBe(controllable.stickerId);

      await db.update(packInstalls).set({ state: "uninstalled" }).where(eq(packInstalls.userId, "friend"));
      expect(await getPet(db, "friend")).toEqual({ pet: null });
    } finally {
      await close();
    }
  });

  it("forgets the pet when its sticker is deleted", async () => {
    const { db, close, controllable } = await setup();
    try {
      await setPet(db, "owner", { stickerId: controllable.stickerId });
      await db.delete(stickers).where(eq(stickers.id, controllable.stickerId));
      expect(await getPet(db, "owner")).toEqual({ pet: null });
    } finally {
      await close();
    }
  });

  it("lists only controllable stickers when asked", async () => {
    const { db, close, controllable } = await setup();
    try {
      const all = await listStickers(db, "owner", { status: "published" });
      expect(all.data).toHaveLength(2);
      const posable = await listStickers(db, "owner", { status: "published", controllable: true });
      expect(posable.data.map((sticker) => sticker.id)).toEqual([controllable.stickerId]);
    } finally {
      await close();
    }
  });

  describe("status from sent stickers", () => {
    const configuration: StickerConfiguration = {
      controls: [
        { id: "mood", label: "Mood", type: "choice", defaultValue: "calm",
          options: [{ id: "calm", label: "Calm" }, { id: "happy", label: "Happy" }, { id: "sleepy", label: "Sleepy" }] },
        { id: "pose", label: "Pose", type: "choice", defaultValue: "sit",
          options: [{ id: "sit", label: "Sit" }, { id: "dance", label: "Dance" }] },
        { id: "speed", label: "Speed", type: "number", binding: "speed", defaultValue: 1, minimum: 0.5, maximum: 2, step: 0.1 },
      ],
      variants: [],
    };

    async function petSetup() {
      const base = await setup();
      const pet = await seedPublishedSticker(base.db, "owner", { title: "Loaf", kind: "animated", controllable: true, configuration });
      await setPet(base.db, "owner", { stickerId: pet.stickerId });
      const tasks: Array<() => Promise<void>> = [];
      const send = async (stickerId: string) => {
        const result = RecordPetSendResponseV1Schema.parse(
          await recordPetSend(base.db, "owner", { stickerId }, (task) => tasks.push(task)));
        await Promise.all(tasks.splice(0).map((task) => task()));
        return result;
      };
      return { ...base, pet, send };
    }

    afterEach(() => setAiProviderForTests(undefined));

    it("poses the pet from a sent sticker, keeping what the sticker says nothing about", async () => {
      const { db, close, send } = await petSetup();
      try {
        expect((await getPet(db, "owner")).pet?.status).toBeNull();

        const party = await seedPublishedSticker(db, "owner", { title: "Happy Dance" });
        expect(await send(party.stickerId)).toEqual({ accepted: true });
        const first = PetResponseV1Schema.parse(await getPet(db, "owner")).pet?.status;
        expect(first).toMatchObject({ values: { mood: "happy", pose: "dance", speed: 1 }, caption: "Feeling Happy Dance" });

        // "Sleepy" moves only the mood; the pose the last sticker set stays.
        const nap = await seedPublishedSticker(db, "owner", { title: "Sleepy Monday" });
        await send(nap.stickerId);
        expect((await getPet(db, "owner")).pet?.status?.values).toEqual({ mood: "sleepy", pose: "dance", speed: 1 });
      } finally {
        await close();
      }
    });

    it("never hands the watch a value the pet's controls cannot play", async () => {
      const { db, close, send } = await petSetup();
      try {
        setAiProviderForTests({ ...unusedAiProvider,
          choosePetStatus: async () => ({ values: { mood: "furious", pose: "dance", speed: 9, wings: true }, caption: "  Grr  " }),
        });
        const sent = await seedPublishedSticker(db, "owner", { title: "Anything" });
        await send(sent.stickerId);
        expect((await getPet(db, "owner")).pet?.status).toMatchObject({
          values: { mood: "calm", pose: "dance", speed: 2 }, caption: "Grr",
        });
      } finally {
        await close();
      }
    });

    it("folds a repeated send into one reading, and ignores sends without a pet", async () => {
      const { db, close, send } = await petSetup();
      try {
        let calls = 0;
        setAiProviderForTests({ ...unusedAiProvider, choosePetStatus: async () => { calls += 1; return { values: {}, caption: "Hi" }; } });
        const sent = await seedPublishedSticker(db, "owner", { title: "Wave" });
        expect(await send(sent.stickerId)).toEqual({ accepted: true });
        expect(await send(sent.stickerId)).toEqual({ accepted: false });
        expect(calls).toBe(1);

        await clearPet(db, "owner");
        expect(await send(sent.stickerId)).toEqual({ accepted: false });
      } finally {
        await close();
      }
    });

    it("refuses a sticker the caller cannot send, and survives a failed reading", async () => {
      const { db, close, send } = await petSetup();
      try {
        const theirs = await seedPublishedSticker(db, "friend", { title: "Happy" });
        await expect(send(theirs.stickerId)).rejects.toMatchObject({ status: 404, code: "STICKER_NOT_FOUND" });

        setAiProviderForTests({ ...unusedAiProvider, choosePetStatus: async () => { throw new Error("model down"); } });
        const mine = await seedPublishedSticker(db, "owner", { title: "Happy" });
        expect(await send(mine.stickerId)).toEqual({ accepted: true });
        expect((await getPet(db, "owner")).pet?.status).toBeNull();
      } finally {
        await close();
      }
    });

    it("drops a reading that a newer send has overtaken, and resets when another pet is chosen", async () => {
      const { db, close, pet } = await petSetup();
      try {
        const older = await seedPublishedSticker(db, "owner", { title: "Happy" });
        const newer = await seedPublishedSticker(db, "owner", { title: "Sleepy" });
        const tasks: Array<() => Promise<void>> = [];
        await recordPetSend(db, "owner", { stickerId: older.stickerId }, (task) => tasks.push(task));
        await new Promise((resolve) => setTimeout(resolve, 5));
        await recordPetSend(db, "owner", { stickerId: newer.stickerId }, (task) => tasks.push(task));
        await tasks[0]();
        expect((await getPet(db, "owner")).pet?.status).toBeNull();
        await tasks[1]();
        expect((await getPet(db, "owner")).pet?.status?.values.mood).toBe("sleepy");

        await setPet(db, "owner", { stickerId: pet.stickerId });
        expect((await getPet(db, "owner")).pet?.status?.values.mood).toBe("sleepy");
        const other = await seedPublishedSticker(db, "owner", { title: "Bun", kind: "animated", controllable: true, configuration });
        await setPet(db, "owner", { stickerId: other.stickerId });
        expect((await getPet(db, "owner")).pet?.status).toBeNull();
        const [row] = await db.select().from(userPets).where(eq(userPets.userId, "owner"));
        expect(row.statusJson).toBeNull();
      } finally {
        await close();
      }
    });

    it("wakes the phone only when a reading lands", async () => {
      const { db, close } = await petSetup();
      try {
        const notified: string[] = [];
        const notify = async (_db: unknown, userId: string) => { notified.push(userId); };
        const sent = await seedPublishedSticker(db, "owner", { title: "Happy" });
        const tasks: Array<() => Promise<void>> = [];
        await recordPetSend(db, "owner", { stickerId: sent.stickerId }, (task) => tasks.push(task));
        const [row] = await db.select().from(userPets).where(eq(userPets.userId, "owner"));
        await readPetSend(db, "owner", row.lastSentAt!, notify);
        expect(notified).toEqual(["owner"]);

        // An overtaken reading stores nothing, so there is nothing to wake anyone for.
        await readPetSend(db, "owner", new Date(0), notify);
        setAiProviderForTests({ ...unusedAiProvider, choosePetStatus: async () => { throw new Error("model down"); } });
        await readPetSend(db, "owner", row.lastSentAt!, notify);
        expect(notified).toEqual(["owner"]);
      } finally {
        await close();
      }
    });
  });

  describe("pose", () => {
    async function poseSetup() {
      const base = await setup();
      const pet = await seedPublishedSticker(base.db, "owner", {
        title: "Glow", kind: "animated", controllable: true, playbackDocument: fadingPet(),
      });
      return { ...base, pet };
    }

    it("draws the pet in its current pose, and answers a matching ETag without drawing", async () => {
      const { db, close, pet } = await poseSetup();
      try {
        await expect(getPetPose(db, "owner", 128)).rejects.toMatchObject({ status: 404, code: "PET_NOT_FOUND" });
        await setPet(db, "owner", { stickerId: pet.stickerId });

        const shown = await getPetPose(db, "owner", 128);
        expect(await sharp(Buffer.from(shown.bytes!)).metadata()).toMatchObject({ format: "png", width: 128 });
        expect((await sharp(Buffer.from(shown.bytes!)).stats()).channels[3].mean).toBeGreaterThan(0);
        expect(await getPetPose(db, "owner", 128, shown.etag)).toEqual({ etag: shown.etag, bytes: null });
        expect((await getPetPose(db, "owner", 64, shown.etag)).etag).not.toBe(shown.etag);

        // A new reading is a new pose: the old ETag no longer matches, and the pet is drawn hidden.
        await db.update(userPets).set({ statusJson: { values: { visible: false }, caption: "Hiding" }, statusUpdatedAt: new Date() })
          .where(eq(userPets.userId, "owner"));
        const hidden = await getPetPose(db, "owner", 128, shown.etag);
        expect(hidden.etag).not.toBe(shown.etag);
        expect((await sharp(Buffer.from(hidden.bytes!)).stats()).channels[3].mean).toBe(0);
      } finally {
        await close();
      }
    });

    it("refuses a pet the caller can no longer pose", async () => {
      const { db, close, pet } = await poseSetup();
      try {
        await setPet(db, "owner", { stickerId: pet.stickerId });
        await db.update(stickers).set({ status: "draft" }).where(eq(stickers.id, pet.stickerId));
        await expect(getPetPose(db, "owner", 128)).rejects.toMatchObject({ status: 404, code: "PET_NOT_FOUND" });
      } finally {
        await close();
      }
    });
  });

  describe("status push", () => {
    const config = { keyId: "k", teamId: "t", privateKey: "unused", bundleId: "app.rxlab.stickerfactory" };

    it("sends a silent background push to each of the owner's devices", async () => {
      const { db, close } = await setup();
      try {
        await registerDeviceToken(db, "owner", { token: "a".repeat(64), platform: "ios", environment: "sandbox" });
        await registerDeviceToken(db, "friend", { token: "b".repeat(64), platform: "ios", environment: "sandbox" });
        const sent: ApnsPush[] = [];
        await notifyPetStatusChanged(db, "owner", {
          config,
          send: async (pushes) => {
            sent.push(...pushes);
            return pushes.map((push) => ({ token: push.token, ok: true, status: 200, permanentlyGone: false }));
          },
        });
        expect(sent).toEqual([{
          token: "a".repeat(64),
          environment: "sandbox",
          payload: { aps: { "content-available": 1 }, kind: PET_STATUS_PUSH_KIND },
          collapseId: "pet-owner",
          pushType: "background",
          priority: "5",
        }]);
      } finally {
        await close();
      }
    });

    it("stays quiet without credentials and never throws", async () => {
      const { db, close } = await setup();
      try {
        await notifyPetStatusChanged(db, "owner", { config: undefined });
        await notifyPetStatusChanged(db, "owner", { config, send: async () => { throw new Error("apple down"); } });
      } finally {
        await close();
      }
    });
  });
});
