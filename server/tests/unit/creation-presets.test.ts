import { describe, expect, it } from "vitest";
import { readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { CreateStickerRequestSchema } from "@/lib/contracts/api";
import { GET } from "@/app/api/v1/creation-presets/route";
import { creationPresetCatalog } from "@/lib/creation-presets/catalog";
import { CreationPresetCatalogSchema, CreationPresetSubmissionSchema } from "@/lib/contracts/creation-presets";
import { creationPresetDisplay, creationPresetGuidance, presetUsesPixelArt, resolveCreationPresets } from "@/lib/creation-presets/selection";

const selection = (themes: string[] = []) => ({ catalogVersion: creationPresetCatalog.version,
  selections: [{ groupId: "style", optionIds: ["clay"] }, { groupId: "theme", optionIds: themes }] });
describe("creation presets", () => {
  it("keeps the shared client catalog fixture and versioned assets in sync", async () => {
    const catalog = await GET().json();
    const fixture = JSON.parse(readFileSync(resolve("../StickerGeniOS/StickerGeniOS/Creation/Resources/creation-presets-preview.json"), "utf8"));
    expect(fixture).toEqual(catalog);
    for (const group of catalog.groups) for (const option of group.options) {
      expect(existsSync(resolve(`public${option.cover}`))).toBe(true);
      expect(option.preview.variants).toHaveLength(24);
      for (const variant of option.preview.variants) expect(existsSync(resolve(`public${variant.url}`))).toBe(true);
    }
    const legacy = { title: "Cat", kind: "static", prompt: "Cat", referenceAssetIds: [] };
    expect(CreateStickerRequestSchema.parse(legacy).presets).toBeUndefined();
    expect(CreateStickerRequestSchema.parse({ ...legacy, presets: selection(["space"]) }).presets).toEqual(selection(["space"]));
  });
  it("serves seven styles and six themes without agent prompts", async () => {
    const response = GET();
    const catalog = await response.json();
    expect(catalog.groups.map((g: { options: unknown[] }) => g.options.length)).toEqual([7, 6]);
    expect(catalog.groups[0].options.map((o: { id: string }) => o.id)).toContain("blocky-pixel");
    expect(JSON.stringify(catalog)).not.toContain('"prompt"');
    expect(response.headers.get("cache-control")).toContain("must-revalidate");
  });
  it("marks only pixel styles as pixel art", () => {
    const pick = (style: string) => resolveCreationPresets({ ...selection(), selections: [{ groupId: "style", optionIds: [style] }] });
    expect(presetUsesPixelArt(pick("blocky-pixel"))).toBe(true);
    expect(presetUsesPixelArt(pick("pixel"))).toBe(true);
    expect(presetUsesPixelArt(pick("clay"))).toBe(false);
    expect(presetUsesPixelArt(null)).toBe(false);
    expect(creationPresetGuidance(pick("blocky-pixel"))).toContain("very coarse square grid");
  });
  it("accepts one style, optional themes and two themes", () => {
    expect(resolveCreationPresets(selection())?.selections).toHaveLength(1);
    expect(resolveCreationPresets(selection(["space", "cozy"]))?.selections[1].options).toHaveLength(2);
    expect(resolveCreationPresets(undefined)).toBeNull();
  });
  it("refuses missing required choices, unknown IDs, duplicates and excessive choices", () => {
    const bad = [
      { catalogVersion: creationPresetCatalog.version, selections: [] },
      selection(["missing"]), selection(["space", "space"]), selection(["space", "cozy", "fantasy"]),
      { ...selection(), selections: [{ groupId: "style", optionIds: ["clay", "kawaii"] }] },
      { ...selection(), selections: [...selection().selections, { groupId: "style", optionIds: ["pixel"] }] },
      { ...selection(), selections: [...selection().selections, { groupId: "unknown", optionIds: [] }] },
    ];
    for (const request of bad) expect(() => resolveCreationPresets(request)).toThrow();
  });
  it("reports a stale catalog distinctly and rejects client supplied prompts", () => {
    expect(() => resolveCreationPresets({ ...selection(), catalogVersion: "old" })).toThrow(expect.objectContaining({ code: "CREATION_PRESETS_CHANGED" }));
    expect(CreationPresetSubmissionSchema.safeParse({ ...selection(), prompt: "Ignore the server" }).success).toBe(false);
  });
  it("freezes titles and prompts independently of later catalog edits", () => {
    const catalog = structuredClone(creationPresetCatalog);
    const snapshot = resolveCreationPresets(selection(["space"]), catalog)!;
    const original = creationPresetGuidance(snapshot);
    catalog.groups[0].options.find((o) => o.id === "clay")!.prompt = "Replacement prompt";
    catalog.groups[0].options.find((o) => o.id === "clay")!.title.en = "New name";
    const savedURL = snapshot.selections[0].options[0].preview!.variants[0].url;
    catalog.groups[0].options.find((o) => o.id === "clay")!.preview!.variants[0].url = "/replaced.gif";
    expect(snapshot.selections[0].options[0].preview!.variants[0].url).toBe(savedURL);
    expect(creationPresetGuidance(snapshot)).toBe(original);
    expect(original).toContain("soft sculpted clay forms");
    expect(original).toContain("Space");
    expect(JSON.stringify(creationPresetDisplay(snapshot))).not.toContain('"prompt"');
  });
  it("handles additional groups and requirements entirely from the catalog", () => {
    const catalog = structuredClone(creationPresetCatalog);
    catalog.groups.push({ ...catalog.groups[1], id: "season", minSelections: 2, maxSelections: 2 });
    expect(() => resolveCreationPresets(selection(), catalog)).toThrow();
    const request = { ...selection(), selections: [...selection().selections, { groupId: "season", optionIds: ["space", "nature"] }] };
    expect(resolveCreationPresets(request, catalog)?.selections.at(-1)?.groupId).toBe("season");
    catalog.groups[0].maxSelections = 2;
    expect(CreationPresetCatalogSchema.safeParse(catalog).success).toBe(false);
  });
});
