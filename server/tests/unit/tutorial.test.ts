import { describe, expect, it } from "vitest";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { compileTutorialDocument } from "@/lib/tutorial/compile";
import documents from "@/lib/tutorial/documents.generated.json";
import { compile } from "@mdx-js/mdx";
import { chapters, cleanProgress, tutorialLocale, tutorialLocales } from "@/lib/tutorial/catalog";

describe("tutorial content contract", () => {
  it("matches supported app languages", () => {
    expect(["en-GB", "zh-Hans-CN", "zh-Hant-TW", "zh-HK", "fr"].map(tutorialLocale)).toEqual(["en", "zh-CN", "zh-HK", "zh-HK", "en"]);
  });
  it("discards invalid saved locations without losing completed chapters", () => {
    expect(cleanProgress({ steps: { static: "review", finish: "missing", bad: "step" }, completed: ["static", "bad"], lastChapter: "static" })).toEqual({ steps: { static: "review" }, completed: ["static"], lastChapter: "static", lastStep: "review" });
    expect(cleanProgress(null)).toEqual({ steps: {}, completed: [] });
  });
  it("compiles every translation with matching, unique steps", async () => {
    expect(new Set(chapters.map(c => c.id)).size).toBe(8);
    for (const chapter of chapters) for (const locale of tutorialLocales) {
      const source = readFileSync(join(process.cwd(), "content/tutorial", locale, `${chapter.id}.mdx`), "utf8");
      await expect(compile(source)).resolves.toBeDefined();
      const steps = [...source.matchAll(/<TutorialStep id="([^"]+)"/g)].map(match => match[1]);
      expect(steps).toEqual(chapter.steps);
      expect(new Set(steps).size).toBe(steps.length);
      expect(chapter.titles[locale]).toBeTruthy();
    }
  });
  it("ships the same MDX as validated native blocks in every language", () => {
    for (const locale of tutorialLocales) {
      const document = compileTutorialDocument(locale, chapter => readFileSync(join(process.cwd(), "content/tutorial", locale, `${chapter}.mdx`), "utf8"));
      expect(document).toEqual(documents[locale]);
      expect(document.version).toBe(1);
      expect(document.chapters.map(c => c.steps.map(s => s.id))).toEqual(chapters.map(c => c.steps));
      expect(document.chapters.flatMap(c => c.steps.flatMap(s => s.blocks)).every(b => ["paragraph", "media", "callout", "heading", "list", "action"].includes(b.type))).toBe(true);
    }
  });
  it("rejects executable and unsupported content instead of sending it to native views", () => {
    for (const body of ["{process.env.SECRET}", "<script>alert(1)</script>", "[Sign in](https://evil.test)", '<TutorialMedia id="../secret" caption="Bad" />']) {
      expect(() => compileTutorialDocument("en", () => `<TutorialStep id="choose" title="Choose">\n\n${body}\n\n</TutorialStep>`)).toThrow();
    }
  });
  it("uses only refreshed screenshots with preserved source captures", () => {
    for (const locale of tutorialLocales) {
      const media = documents[locale].chapters.flatMap(chapter => chapter.steps.flatMap(step => step.blocks))
        .filter(block => block.type === "media");
      expect(media.length).toBeGreaterThan(0);
      for (const block of media) {
        expect(block.id).toMatch(/-20260916$/);
        expect(block).not.toHaveProperty("animation");
        expect(existsSync(join(process.cwd(), "public", block.poster!)), block.poster).toBe(true);
        expect(existsSync(join(process.cwd(), "../docs/tutorial/source", locale, `${block.id}.png`)), block.id).toBe(true);
      }
      const references = documents[locale].chapters.find(chapter => chapter.id === "static")!
        .steps.find(step => step.id === "references")!;
      expect(references.blocks.find(block => block.type === "media")?.id).toBe("create-references-20260916");
    }
  });
});
