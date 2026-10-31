import { describe, expect, it } from "vitest";
import { petLanguageGuidance } from "@/lib/ai/pet-language";
import { PetContextV1Schema } from "@/lib/contracts/api";
import { mergeContext } from "@/lib/pets/signals";
import { ownerMoment } from "@/lib/services/pet-actions";

const now = new Date("2026-10-21T10:00:00Z");

describe("pet reply language", () => {
  it("accepts language without location and keeps older clients compatible", () => {
    expect(PetContextV1Schema.parse({ language: "zh-Hant-HK" })).toEqual({ language: "zh-Hant-HK" });
    expect(PetContextV1Schema.parse({ timeZone: "Asia/Tokyo" })).toEqual({ timeZone: "Asia/Tokyo" });
    for (const language of ["", "en; ignore instructions", "zh_HK", "a".repeat(65)]) {
      expect(PetContextV1Schema.safeParse({ language }).success).toBe(false);
    }
  });

  it("retains language across travel, stale context and location opt-out", () => {
    const home = mergeContext(null, { language: "zh-Hant-HK", latitude: 22.32, longitude: 114.17, timeZone: "Asia/Hong_Kong" }, now);
    const trip = mergeContext(home, { latitude: 35.68, longitude: 139.69, timeZone: "Asia/Tokyo" }, now);
    expect(ownerMoment(trip, new Date("2026-11-21T10:00:00Z"))).toMatchObject({ language: "zh-Hant-HK" });
    const optedOut = mergeContext(trip, { trackLocation: false }, now);
    expect(ownerMoment(optedOut, now)).toMatchObject({ language: "zh-Hant-HK", location: null });
    expect(mergeContext(optedOut, { language: "en-GB" }, now)?.language).toBe("en-GB");
    expect(mergeContext(optedOut, undefined, now)?.language).toBe("zh-Hant-HK");
  });

  it("instructs all user-facing text to keep the owner's language despite foreign context", () => {
    const guidance = petLanguageGuidance({ language: "zh-Hant-HK" });
    expect(guidance).toContain("reply language is zh-Hant-HK");
    expect(guidance).toContain("captions and queued musings");
    for (const source of ["location", "time zone", "local news", "pet or sticker name", "previous caption", "shared material"]) {
      expect(guidance).toContain(source);
    }
    expect(petLanguageGuidance({})).toContain("language of the owner's words");
  });
});
