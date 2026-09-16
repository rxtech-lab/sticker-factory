import { createProcessor } from "@mdx-js/mdx";
import { chapters, type TutorialLocale } from "./catalog";
import { strings } from "./strings";
import type { TutorialBlock, TutorialDocument } from "./document";

// The native subset deliberately rejects JS, HTML and arbitrary links at build time.
// Inline emphasis is serialized as Markdown and drawn by SwiftUI Text.
type Node = { type: string; name?: string; value?: string; children?: Node[]; ordered?: boolean; attributes?: { type: string; name?: string; value?: unknown }[] };
const animatedMedia = new Set(["create-animated", "controls", "new-pack", "whatsapp", "telegram"]);
const actions = new Set<string>(chapters.flatMap(c => [c.action, ...Object.values(c.stepActions ?? {})]));
function attribute(node: Node, key: string): string {
  const attribute = node.attributes?.find(a => a.name === key);
  if (!attribute || attribute.type !== "mdxJsxAttribute" || typeof attribute.value !== "string") throw new Error(`Missing literal ${key} on ${node.name}`);
  return attribute.value;
}
function inline(node: Node): string {
  const content = () => (node.children ?? []).map(inline).join("");
  switch (node.type) {
    case "text": return node.value ?? "";
    case "strong": return `**${content()}**`;
    case "emphasis": return `*${content()}*`;
    case "inlineCode": return `\`${node.value}\``;
    case "break": return "\n";
    case "paragraph": return content();
    default: throw new Error(`Unsupported native inline node: ${node.type}`);
  }
}
function actionURL(action: string) {
  if (!actions.has(action)) throw new Error(`Unsupported tutorial action: ${action}`);
  return `stickerfactory://open/${action}`;
}
function block(node: Node, locale: TutorialLocale): TutorialBlock {
  if (node.type === "paragraph" || node.type === "heading") return { type: node.type, text: (node.children ?? []).map(inline).join("") };
  if (node.type === "list") return { type: "list", ordered: !!node.ordered, items: (node.children ?? []).map(item => (item.children ?? []).map(inline).join("\n")) };
  if (node.type === "mdxJsxFlowElement") {
    if (node.name === "TutorialMedia") {
      const id = attribute(node, "id");
      if (!/^[a-z0-9-]+$/.test(id)) throw new Error(`Invalid media ID ${id}`);
      const path = `/tutorial/media/${locale}/${id}`;
      return { type: "media", id, caption: attribute(node, "caption"), poster: `${path}.webp`, ...(animatedMedia.has(id) ? { animation: `${path}.animated.webp` } : {}) };
    }
    if (node.name === "TutorialCallout") return { type: "callout", text: (node.children ?? []).map(inline).join("\n") };
    if (node.name === "TutorialActionLink") return { type: "action", title: (node.children ?? []).map(inline).join(""), url: actionURL(attribute(node, "action")) };
  }
  throw new Error(`Unsupported native content: ${node.type}/${node.name ?? ""}`);
}
export function compileTutorialDocument(locale: TutorialLocale, source: (chapter: string) => string): TutorialDocument {
  return {
    version: 1, locale, strings: strings[locale],
    sections: (["create", "finish", "packs"] as const).map(id => ({ id, title: strings[locale][id] })),
    chapters: chapters.map(chapter => {
      const tree = createProcessor().parse(source(chapter.id)) as Node;
      const steps = (tree.children ?? []).map(node => {
        if (node.type !== "mdxJsxFlowElement" || node.name !== "TutorialStep") throw new Error(`Only TutorialStep is allowed at document root: ${chapter.id}`);
        const id = attribute(node, "id");
        return { id, title: attribute(node, "title"), blocks: (node.children ?? []).map(child => block(child, locale)), action: actionURL(chapter.stepActions?.[id] ?? chapter.action) };
      });
      if (JSON.stringify(steps.map(s => s.id)) !== JSON.stringify(chapter.steps)) throw new Error(`Step mismatch: ${locale}/${chapter.id}`);
      return { id: chapter.id, title: chapter.titles[locale], section: chapter.section, steps };
    }),
  };
}
