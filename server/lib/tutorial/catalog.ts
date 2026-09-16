export const tutorialLocales = ["en", "zh-CN", "zh-HK"] as const;
export type TutorialLocale = typeof tutorialLocales[number];
export type TutorialActionPath = "create?kind=static" | "create?kind=animated" | "create?kind=animated&controllable=1" | "sticker?action=plan" | "sticker?action=controls" | "sticker?action=export" | "packs?tab=browse" | "packs?tab=mine" | "packs/new" | "pack?action=whatsapp" | "pack?action=telegram";
export type TutorialChapter = { id: string; section: "create" | "finish" | "packs"; titles: Record<TutorialLocale, string>; steps: string[]; action: TutorialActionPath; stepActions?: Record<string, TutorialActionPath> };
export const chapters: TutorialChapter[] = [
  {
    "id": "static",
    "section": "create",
    "titles": {
      "en": "Make a static sticker",
      "zh-CN": "制作静态贴纸",
      "zh-HK": "製作靜態貼紙"
    },
    "steps": [
      "choose",
      "describe",
      "references",
      "review"
    ],
    "action": "create?kind=static"
  },
  {
    "id": "animated",
    "section": "create",
    "titles": {
      "en": "Make an animated sticker",
      "zh-CN": "制作动态贴纸",
      "zh-HK": "製作動態貼紙"
    },
    "steps": [
      "choose",
      "reference",
      "build",
      "preview"
    ],
    "action": "create?kind=animated"
  },
  {
    "id": "controllable",
    "section": "create",
    "titles": {
      "en": "Make it controllable",
      "zh-CN": "制作可操控贴纸",
      "zh-HK": "製作可操控貼紙"
    },
    "steps": [
      "enable",
      "variety",
      "build",
      "controls",
      "apply"
    ],
    "action": "create?kind=animated&controllable=1"
  },
  {
    "id": "finish",
    "section": "finish",
    "titles": {
      "en": "Plan, confirm and export",
      "zh-CN": "方案、确认与导出",
      "zh-HK": "方案、確認與匯出"
    },
    "steps": [
      "plan",
      "confirm",
      "accept",
      "export"
    ],
    "action": "sticker?action=plan"
  },
  {
    "id": "packs",
    "section": "packs",
    "titles": {
      "en": "Explore sticker packs",
      "zh-CN": "探索贴纸包",
      "zh-HK": "探索貼紙包"
    },
    "steps": [
      "browse",
      "preview",
      "install",
      "share"
    ],
    "action": "packs?tab=browse"
  },
  {
    "id": "new-pack",
    "section": "packs",
    "titles": {
      "en": "Create a sticker pack",
      "zh-CN": "创建贴纸包",
      "zh-HK": "建立貼紙包"
    },
    "steps": [
      "name",
      "select",
      "save",
      "prepare"
    ],
    "action": "packs/new"
  },
  {
    "id": "whatsapp",
    "section": "packs",
    "titles": {
      "en": "Add a pack to WhatsApp",
      "zh-CN": "添加到 WhatsApp",
      "zh-HK": "加入 WhatsApp"
    },
    "steps": [
      "open",
      "parts",
      "emoji",
      "handoff"
    ],
    "action": "pack?action=whatsapp"
  },
  {
    "id": "telegram",
    "section": "packs",
    "titles": {
      "en": "Add a pack to Telegram",
      "zh-CN": "添加到 Telegram",
      "zh-HK": "加入 Telegram"
    },
    "steps": [
      "open",
      "parts",
      "emoji",
      "handoff"
    ],
    "action": "pack?action=telegram"
  }
];
const stepActions: Record<string, Record<string, TutorialActionPath>> = {
  static: { review: "sticker?action=plan" },
  animated: { reference: "sticker?action=plan", build: "sticker?action=plan", preview: "sticker?action=controls" },
  controllable: { build: "sticker?action=plan", controls: "sticker?action=controls", apply: "sticker?action=controls" },
  finish: { accept: "sticker?action=plan", export: "sticker?action=export" },
};
for (const chapter of chapters) chapter.stepActions = stepActions[chapter.id];
export function tutorialLocale(value: string): TutorialLocale {
  const normalized = value.toLowerCase();
  if (/^zh-(hant|hk|tw|mo)(-|$)/.test(normalized)) return "zh-HK";
  if (normalized === "zh" || normalized.startsWith("zh-")) return "zh-CN";
  return "en";
}
export function chapterByID(id: string) { return chapters.find(chapter => chapter.id === id); }
export function chapterURL(locale: TutorialLocale, chapter: string, step?: string) {
  return `/tutorial/${locale}/${chapter}${step ? `?step=${encodeURIComponent(step)}` : ""}`;
}
export type TutorialProgress = { lastChapter?: string; lastStep?: string; steps: Record<string, string>; completed: string[] };
export function cleanProgress(value: unknown): TutorialProgress {
  const result: TutorialProgress = { steps: {}, completed: [] };
  if (!value || typeof value !== "object") return result;
  const data = value as Partial<TutorialProgress>;
  for (const chapter of chapters) {
    const step = data.steps?.[chapter.id];
    if (typeof step === "string" && chapter.steps.includes(step)) result.steps[chapter.id] = step;
    if (Array.isArray(data.completed) && data.completed.includes(chapter.id)) result.completed.push(chapter.id);
  }
  if (typeof data.lastChapter === "string" && result.steps[data.lastChapter]) {
    result.lastChapter = data.lastChapter; result.lastStep = result.steps[data.lastChapter];
  }
  return result;
}
