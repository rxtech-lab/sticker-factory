import { describe, expect, it } from "vitest";
import sharp from "sharp";
import { stickerInstruction } from "@/lib/ai/gateway-models";
import { PRESET_BOARD_LABEL } from "@/lib/creation-presets/references";
import { normalizeTransparentPng } from "@/lib/storage/r2";

const image = (label?: string) => ({ bytes: new Uint8Array(), mimeType: "image/png", ...(label ? { label } : {}) });

describe("sticker instruction", () => {
  it("names labelled references in order and asks to keep the user's subject", () => {
    const text = stickerInstruction({ prompt: "Wave hello", mode: "generate",
      references: [image("original or carried reference 1"), image(PRESET_BOARD_LABEL)] });
    expect(text).toContain(`Reference images, in the order attached:\n1. original or carried reference 1\n2. ${PRESET_BOARD_LABEL}`);
    expect(text).toContain("Keep it recognisably the same subject");
  });

  it("omits the fidelity rule without a user reference or for an isolated overlay", () => {
    const presetOnly = stickerInstruction({ prompt: "Cat", mode: "generate", references: [image(PRESET_BOARD_LABEL)] });
    expect(presetOnly).not.toContain("recognisably the same subject");
    const overlay = stickerInstruction({ prompt: "Hat", mode: "generate", isolatedLayer: true,
      references: [image("original or carried reference 1")] });
    expect(overlay).not.toContain("recognisably the same subject");
    expect(overlay).toContain("References provide style or likeness only.");
  });

  it("adds no reference list for unlabelled references", () => {
    expect(stickerInstruction({ prompt: "Cat", mode: "conversation_edit", references: [image()] })).not.toContain("Reference images");
  });
});

describe("pixel art normalization", () => {
  it("keeps hard block edges and binary alpha", async () => {
    // A 20x20 blocky sprite with a hole: every pixel is either solid orange or fully transparent.
    const size = 20;
    const raw = Buffer.alloc(size * size * 4);
    for (let y = 0; y < size; y += 1) for (let x = 0; x < size; x += 1) {
      const solid = x >= 3 && x < 17 && y >= 4 && y < 16 && !(y === 8 && (x === 6 || x === 13));
      if (solid) raw.set([217, 119, 87, 255], (y * size + x) * 4);
    }
    const png = await sharp(raw, { raw: { width: size, height: size, channels: 4 } }).png().toBuffer();
    const normalized = await normalizeTransparentPng(png, { subjectCrop: true, pixelArt: true });
    const { data } = await sharp(normalized.bytes).raw().toBuffer({ resolveWithObject: true });
    const colors = new Set<string>();
    for (let index = 0; index < data.length; index += 4) {
      expect([0, 255]).toContain(data[index + 3]);
      if (data[index + 3]) colors.add(`${data[index]},${data[index + 1]},${data[index + 2]}`);
    }
    expect([...colors]).toEqual(["217,119,87"]);

    const smooth = await normalizeTransparentPng(png, { subjectCrop: true });
    const soft = await sharp(smooth.bytes).raw().toBuffer();
    expect(soft.some((value, index) => index % 4 === 3 && value > 0 && value < 255)).toBe(true);
  });
});
