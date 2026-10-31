import type { AiOwnerMoment } from "./gateway-contracts";

/** Language is a user preference, never a consequence of travel or material being discussed. */
export function petLanguageGuidance(input: Pick<AiOwnerMoment, "language">): string {
  return [
    input.language ? `The owner's reply language is ${input.language}.` : "Use the language of the owner's words; if unavailable, keep the established conversation language.",
    "Write all user-facing text, including captions and queued musings, in the owner's reply language.",
    "Never switch language because of location, time zone, local news, a pet or sticker name, a previous caption, or shared material.",
    "Keep any explicitly requested English artist briefs in English.",
  ].join(" ");
}

