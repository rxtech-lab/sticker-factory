/** Package reviewed outputs from generate-creation-previews.ts. Never synthesizes motion.
 * Run from server: bun scripts/build-creation-demo.ts /path/to/local-preview-jobs */
import { cp, mkdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import sharp from "sharp";
import { publicCreationPresetCatalog } from "@/lib/creation-presets/catalog";
import { StickerDocumentSchema } from "@/lib/contracts/sticker";

const work = process.argv[2];
if (!work) throw new Error("Provide the reviewed workflow output directory");
const bundled = resolve("../StickerGeniOS/StickerGeniOS/Creation/Resources");
const catalog = publicCreationPresetCatalog();
const requested = new Set(process.argv.slice(3));
for (const id of requested) if (!catalog.groups.some(group => group.options.some(option => option.id === id))) {
  throw new Error(`Unknown preview option: ${id}`);
}
for (const group of catalog.groups) for (const option of group.options) {
  if (requested.size && !requested.has(option.id)) continue;
  const input = resolve(work, option.id, "export");
  const manifest = JSON.parse(await readFile(resolve(input, "manifest.json"), "utf8"));
  if (manifest.source.workflow !== "stickerGenerationWorkflow" || manifest.examples.length !== 24) {
    throw new Error(`Missing complete generated example: ${option.id}`);
  }
  StickerDocumentSchema.parse(JSON.parse(await readFile(resolve(input, "document.json"), "utf8")));
  for (const variant of option.preview!.variants) {
    const filename = `${variant.pose}-${variant.mood}.gif`;
    const metadata = await sharp(resolve(input, filename), { animated: true }).metadata();
    if ((metadata.pages ?? 1) < 2) throw new Error(`Still preview: ${option.id}/${filename}`);
  }
  const output = resolve("public/images/creation/v3", option.id);
  await mkdir(output, { recursive: true });
  await cp(input, output, { recursive: true });
  if (option.id === "bold-cartoon") {
    await cp(resolve(input, "document.json"), resolve(bundled, "creation-demo.json"));
    const assets: Record<string, string> = JSON.parse(await readFile(resolve(input, "assets.json"), "utf8"));
    const bundledAssets: Record<string, string> = {};
    for (const [id, filename] of Object.entries(assets)) {
      const name = `creation-demo-${id}`;
      await cp(resolve(input, "assets", filename), resolve(bundled, `${name}.png`));
      bundledAssets[id] = name;
    }
    await writeFile(resolve(bundled, "creation-demo-assets.json"), JSON.stringify(bundledAssets, null, 2));
    for (const example of manifest.examples) {
      await cp(resolve(input, example.file), resolve(bundled, `creation-preview-${example.file}`));
    }
    await cp(resolve(input, "wave-happy.gif"), resolve(bundled, "creation-type-animated.gif"));
    await sharp(resolve(input, "wave-happy.gif")).png().toFile(resolve(bundled, "creation-type-static.png"));
  }
  console.log(`Packaged ${option.id}: 8 poses × 3 moods`);
}
await writeFile(resolve(bundled, "creation-presets-preview.json"), JSON.stringify(catalog, null, 2) + "\n");
