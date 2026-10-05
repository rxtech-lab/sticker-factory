import { describe, expect, it } from "vitest";
import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { resolve } from "node:path";
import sharp from "sharp";
import { CreationPreviewSchema } from "@/lib/contracts/creation-presets";
import { creationPresetCatalog } from "@/lib/creation-presets/catalog";
import { StickerDocumentSchema } from "@/lib/contracts/sticker";

describe("generated creation previews", () => {
  it("requires a complete, unambiguous pose and mood matrix", () => {
    const preview = structuredClone(creationPresetCatalog.groups[0].options[0].preview!);
    expect(CreationPreviewSchema.safeParse(preview).success).toBe(true);
    preview.variants[0] = preview.variants[1];
    expect(CreationPreviewSchema.safeParse(preview).success).toBe(false);
    preview.defaultPose = "missing";
    expect(CreationPreviewSchema.safeParse(preview).success).toBe(false);
  });
  it("ships real animated GIFs for every style, theme, pose and mood", async () => {
    const styles = new Set<string>();
    for (const group of creationPresetCatalog.groups) for (const option of group.options) {
      const root = resolve("public/images/creation/v3", option.id);
      const source = JSON.parse(await readFile(resolve(root, "manifest.json"), "utf8"));
      expect(source.source.workflow).toBe("stickerGenerationWorkflow");
      expect(source.source.generator).toBe("editable-svg-mascot-v3");
      const document = StickerDocumentSchema.parse(JSON.parse(await readFile(resolve(root, "document.json"), "utf8")));
      expect(document.layers.some(layer => layer.type === "sprite")).toBe(true);
      const animations = new Set<string>();
      for (const variant of option.preview!.variants) {
        const file = resolve(`public${variant.url}`);
        const metadata = await sharp(file, { animated: true }).metadata();
        expect(metadata.format).toBe("gif");
        expect(metadata.pages).toBeGreaterThan(1);
        expect(metadata.loop).toBe(0);
        expect(metadata.width).toBe(320);
        expect(metadata.pageHeight).toBe(320);
        const decoded = await sharp(file, { animated: true }).ensureAlpha().raw().toBuffer();
        const frameBytes = 320 * 320 * 4;
        const pixels = new Set<string>();
        for (let offset = 0; offset < decoded.length; offset += frameBytes) {
          pixels.add(createHash("sha256").update(decoded.subarray(offset, offset + frameBytes)).digest("hex"));
        }
        expect(pixels.size).toBeGreaterThan(1);
        expect(source.examples.find((example: { file: string }) => example.file === `${variant.pose}-${variant.mood}.gif`).distinctFrames).toBeGreaterThan(1);
        // Every pose starts from rest, so on a coarse pixel grid first frames can coincide; the
        // animations themselves must still all differ.
        animations.add(createHash("sha256").update(decoded).digest("hex"));
      }
      expect(animations.size).toBe(option.preview!.variants.length);
      styles.add((await sharp(resolve(`public${option.preview!.url}`)).resize(32, 32).png().toBuffer()).toString("base64"));
    }
    expect(styles.size).toBe(14);
  }, 60000);
});
