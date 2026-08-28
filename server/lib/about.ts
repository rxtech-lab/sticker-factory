export function aboutCredit(year = new Date().getUTCFullYear()): string {
  return `Created by Bard and Zoey · © ${year}`;
}

export const aboutPurpose =
  "We built Sticker Factory to provide the best sticker-creation experience in the world. We do not want to restrict sticker creation to one platform; everyone should benefit from the app, no matter which platform they use.";

export function aboutMarkdown(year = new Date().getUTCFullYear()): string {
  return `# About Sticker Factory

${aboutPurpose}

---

${aboutCredit(year)}
`;
}
