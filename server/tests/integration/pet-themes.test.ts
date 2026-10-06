import { eq } from "drizzle-orm";
import { afterEach, describe, expect, it } from "vitest";
import { setAiProviderForTests } from "@/lib/ai/gateway";
import { MockAiProvider } from "@/lib/ai/gateway-mock";
import { PetResponseV1Schema, PetThemesV1Schema } from "@/lib/contracts/api";
import { userPets } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { setPetRandomForTests } from "@/lib/pets/log";
import { visitPet } from "@/lib/services/pet-life";
import { setPetLifeStarterForTests } from "@/lib/services/pet-life-runner";
import { listPetEvents } from "@/lib/services/pet-state";
import { getPetThemeArt, listPetThemes, refreshPetThemes, setPetTheme } from "@/lib/services/pet-themes";
import { getPet, setPet, updatePetContext } from "@/lib/services/pets";
import { MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";

const sanFrancisco = { latitude: 37.77, longitude: -122.42, timeZone: "UTC" };
const tokyo = { latitude: 35.68, longitude: 139.69, timeZone: "UTC" };
const noNotify = async () => {};
const minutes = (from: Date, count: number) => new Date(from.getTime() + count * 60_000);

describe("pet themes", () => {
  afterEach(() => {
    setObjectStoreForTests(undefined);
    setPetRandomForTests(undefined);
    setAiProviderForTests(undefined);
    setPetLifeStarterForTests(undefined);
  });

  async function setup() {
    setPetRandomForTests(() => 0.5);
    setAiProviderForTests(new MockAiProvider());
    setPetLifeStarterForTests(async () => "run-1");
    const { db, close } = await createTestDatabase();
    setObjectStoreForTests(new MemoryObjectStore());
    await seedUser(db, "owner");
    const loaf = await seedPublishedSticker(db, "owner", { title: "Loaf", kind: "animated", controllable: true });
    await setPet(db, "owner", { stickerId: loaf.stickerId, context: sanFrancisco });
    const row = (await db.select().from(userPets).where(eq(userPets.userId, "owner")))[0];
    return { db, close, lifeId: row.lifeId!, token: row.lifeRunId! };
  }

  async function expectApiError(promise: Promise<unknown>, code: string) {
    const error = await promise.catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(ApiError);
    expect((error as ApiError).code).toBe(code);
  }

  /** Reports where the phone is, running what the route defers to after the response. */
  async function report(db: Awaited<ReturnType<typeof setup>>["db"], context: Parameters<typeof updatePetContext>[2]) {
    const deferred: Array<() => Promise<void>> = [];
    await updatePetContext(db, "owner", context, (task) => deferred.push(task));
    for (const task of deferred) await task();
  }

  it("discovers drawn everyday places once a day", async () => {
    const { db, close } = await setup();
    try {
      const now = new Date();
      expect((await listPetThemes(db, "owner", now)).discovering).toBe(true);
      await refreshPetThemes(db, "owner", now);
      const themes = PetThemesV1Schema.parse(await listPetThemes(db, "owner", now));
      expect(themes).toMatchObject({ activeThemeId: null, discovering: false, traveling: false, hasLocation: true });
      expect(themes.themes.map((theme) => [theme.title, theme.category, theme.limited])).toEqual(expect.arrayContaining([
        ["Corner Café", "restaurant", false], ["Sunny Park", "nature", false],
      ]));
      for (const theme of themes.themes) {
        const art = await getPetThemeArt(db, "owner", theme.id);
        expect(art.bytes?.length).toBeGreaterThan(0);
      }
      await refreshPetThemes(db, "owner", minutes(now, 60));
      expect((await listPetThemes(db, "owner")).themes).toHaveLength(2);
    } finally {
      await close();
    }
  });

  it("finds a place on a trip in the background, goes there, and loses it for good once home", async () => {
    const { db, close, lifeId, token } = await setup();
    try {
      await refreshPetThemes(db, "owner");
      await report(db, tokyo);
      const away = await listPetThemes(db, "owner");
      expect(away.traveling).toBe(true);
      const trip = away.themes.find((theme) => theme.category === "travel")!;
      expect(trip).toMatchObject({ title: "Faraway Streets", limited: true, available: true, expired: false,
        rules: { place: { label: "the trip", radiusKm: 60 } } });
      expect(trip.expiresAt).not.toBeNull();

      // On its next visit the pet's agent takes it on the trip, and its time there counts on the next.
      const start = new Date();
      expect(await visitPet(db, "owner", lifeId, token, noNotify, minutes(start, 1))).toBe(true);
      const there = PetResponseV1Schema.parse(await getPet(db, "owner")).pet!;
      expect(there.theme).toMatchObject({ id: trip.id, title: trip.title, artKey: trip.artKey, category: "travel" });
      // The place was drawn with a clock, a weather board and a status board for the app to write on.
      expect(there.theme?.fixtures?.clock).toBeTruthy();
      expect(there.theme?.fixtures?.weather).toBeTruthy();
      expect(there.theme?.fixtures?.status).toBeTruthy();
      await visitPet(db, "owner", lifeId, token, noNotify, minutes(start, 61));
      const lines = (await listPetEvents(db, "owner", { limit: 30 })).events.filter((event) => event.kind === "theme");
      expect(lines.map((line) => line.title)).toEqual(["Time at Faraway Streets", "Went to Faraway Streets"]);
      expect(lines[0].effects).toMatchObject({ happiness: 4, energy: -2 });

      // Home again: the trip is over, the pet comes home, and it can never go back.
      await report(db, sanFrancisco);
      await visitPet(db, "owner", lifeId, token, noNotify, minutes(start, 121));
      expect((await getPet(db, "owner")).pet!.theme).toBeNull();
      const home = await listPetThemes(db, "owner");
      expect(home.traveling).toBe(false);
      expect(home.themes.find((theme) => theme.id === trip.id)).toMatchObject({ expired: true, available: false });
      expect(home.themes.at(-1)!.id).toBe(trip.id);
      await expectApiError(setPetTheme(db, "owner", trip.id, noNotify), "PET_THEME_EXPIRED");
    } finally {
      await close();
    }
  });

  it("lets the owner take the pet somewhere until the day's minutes there are used up", async () => {
    const { db, close } = await setup();
    try {
      const now = new Date();
      await refreshPetThemes(db, "owner", now);
      const cafe = (await listPetThemes(db, "owner", now)).themes.find((theme) => theme.title === "Corner Café")!;
      expect(cafe.rules.dailyMinutes).toBe(90);

      await setPetTheme(db, "owner", cafe.id, noNotify, now);
      expect((await getPet(db, "owner")).pet!.theme?.id).toBe(cafe.id);
      await setPetTheme(db, "owner", null, noNotify, minutes(now, 90));
      expect((await getPet(db, "owner")).pet!.theme).toBeNull();
      const lines = (await listPetEvents(db, "owner", { limit: 30 })).events.filter((event) => event.kind === "theme");
      expect(lines.map((line) => line.title)).toEqual(["Came home", "Time at Corner Café", "Went to Corner Café"]);

      const later = minutes(now, 91);
      expect((await listPetThemes(db, "owner", later)).themes.find((theme) => theme.id === cafe.id))
        .toMatchObject({ available: false, minutesLeftToday: 0 });
      await expectApiError(setPetTheme(db, "owner", cafe.id, noNotify, later), "PET_THEME_UNAVAILABLE");
      await expectApiError(setPetTheme(db, "owner", crypto.randomUUID(), noNotify, later), "PET_THEME_NOT_FOUND");
    } finally {
      await close();
    }
  });

  it("forgets where the owner is when tracking is turned off", async () => {
    const { db, close } = await setup();
    try {
      await report(db, { trackLocation: false, timeZone: "UTC" });
      const row = (await db.select().from(userPets).where(eq(userPets.userId, "owner")))[0];
      expect(row.contextJson).not.toHaveProperty("latitude");
      expect(row.contextJson).not.toHaveProperty("home");
      expect((await listPetThemes(db, "owner")).hasLocation).toBe(false);
    } finally {
      await close();
    }
  });
});
