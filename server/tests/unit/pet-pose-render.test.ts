import sharp from "sharp";
import { describe, expect, it } from "vitest";
import { resolveStickerConfiguration } from "@/lib/contracts/sticker";
import { renderPosePng, renderStillPng } from "@/lib/render/renditions";
import { fadingPet } from "@/tests/helpers/pet-documents";

/** Mean alpha, 0…255. */
async function coverage(png: Uint8Array): Promise<number> {
  const stats = await sharp(Buffer.from(png)).ensureAlpha().stats();
  return stats.channels[3].mean;
}

describe("pet pose render", () => {
  it("draws an animated pet settled, not at its empty first instant", async () => {
    const pet = resolveStickerConfiguration(fadingPet(), { visible: true });
    expect(await coverage(await renderStillPng(pet, new Map(), 96))).toBe(0);
    const png = await renderPosePng(pet, new Map(), 96);
    const metadata = await sharp(Buffer.from(png)).metadata();
    expect(metadata).toMatchObject({ format: "png", width: 96, height: 96 });
    expect(await coverage(png)).toBeGreaterThan(50);
  });

  it("draws the pose the pet's values select", async () => {
    const hidden = await renderPosePng(resolveStickerConfiguration(fadingPet(), { visible: false }), new Map(), 64);
    expect(await coverage(hidden)).toBe(0);
  });
});
