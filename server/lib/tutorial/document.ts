/** Versioned, presentation-only contract. Never ship executable MDX or HTML to the app. */
export type TutorialBlock =
  | { type: "paragraph" | "heading" | "callout"; text: string }
  | { type: "list"; items: string[]; ordered: boolean }
  | { type: "media"; id: string; caption: string; poster: string; animation?: string }
  | { type: "action"; title: string; url: string };
export type TutorialDocument = {
  version: 1;
  locale: string;
  strings: Record<string, string>;
  sections: { id: string; title: string }[];
  chapters: { id: string; section: string; title: string; steps: { id: string; title: string; blocks: TutorialBlock[]; action: string }[] }[];
};
