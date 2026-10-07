// The pet's item shop: the agent that restocks it with things that fit the pet's world, each with
// its own time on the shelf and its own time it keeps once bought.

import { generateText, hasToolCall, stepCountIs, tool } from "ai";
import { z } from "zod";
import { recordTextApiCost, reportAiStepUsage } from "@/lib/ai/cost";
import {
  PET_ACTION_GOLD_EARN_MAX, PET_ACTION_GOLD_MAX, PET_ITEM_KEEP_HOURS_MAX, PET_ITEM_KEEP_HOURS_MIN, PET_ITEM_KINDS,
  PET_ITEM_RESTORE_ENERGY_MAX, PET_ITEM_RESTORE_ENERGY_MIN, PET_ITEM_RESTORE_PRICE_MAX, PET_ITEM_RESTORE_PRICE_MIN,
  PET_ITEM_SHELF_HOURS_MAX, PET_ITEM_SHELF_HOURS_MIN,
} from "@/lib/contracts/api";
import type { AiPetItem, AiPetItemsContext } from "./gateway-contracts";
import { userTurn } from "./gateway-models";
import { petAgentModel } from "./pet-models";
import { describeIdentity, describeMoment, describeSignals, PetEffectsInputSchema } from "./gateway-pet";

export async function generatePetItems(input: AiPetItemsContext): Promise<AiPetItem[]> {
  const schema = z.object({ actions: z.array(z.object({
    title: z.string().trim().min(1).max(32),
    description: z.string().trim().min(1).max(120),
    kind: z.enum(PET_ITEM_KINDS),
    effects: PetEffectsInputSchema.extend({
      energy: z.number().int().min(-20).max(PET_ITEM_RESTORE_ENERGY_MAX),
      gold: z.number().int().min(-PET_ACTION_GOLD_MAX).max(PET_ACTION_GOLD_EARN_MAX),
    }).strict(),
    shelfHours: z.number().int().min(PET_ITEM_SHELF_HOURS_MIN).max(PET_ITEM_SHELF_HOURS_MAX),
    keepsHours: z.number().int().min(PET_ITEM_KEEP_HOURS_MIN).max(PET_ITEM_KEEP_HOURS_MAX).nullable(),
  }).strict()).min(input.minCount).max(input.maxCount) }).strict();
  const keptRestorer = input.keeping.some((item) => item.effects.energy > 20);
  const result = await generateText({
    onLanguageModelCallEnd: reportAiStepUsage,
    model: petAgentModel(),
    system: [
      `Restock this pet's item shop with between ${input.minCount} and ${input.maxCount} distinct physical objects for it to play with or use;`,
      "pick how many yourself, as a shopkeeper would on a given day.",
      input.keeping.length ? "Some items are still on the shelf; the new ones must be different from them." : "",
      "Base the choices on its location, weather, current mood, personality and recent news.",
      "Use only the context provided; do not invent a specific place, forecast or headline when unknown.",
      "Each object needs a short name, a description of using it with this pet, a kind, plausible small stat effects,",
      "and two lifetimes that fit what it is, varied rather than round numbers.",
      "Kind is food for anything eaten or drunk, ticket for a pass to an outing, show or ride, and toy for everything else.",
      `shelfHours is how long it stays in the shop before it goes (${PET_ITEM_SHELF_HOURS_MIN} to ${PET_ITEM_SHELF_HOURS_MAX}):`,
      "fresh or seasonal things go fast, everyday things linger.",
      `keepsHours is how long one keeps after the owner buys it (${PET_ITEM_KEEP_HOURS_MIN} to ${PET_ITEM_KEEP_HOURS_MAX}),`,
      "or null when it never expires: fresh food spoils within hours or a day or two, tickets lapse after some days,",
      "and sturdy toys usually never expire, while flimsy ones (a bubble wand, a paper kite) wear out.",
      "Gold is the cost of obtaining the object: use zero for found or free objects, otherwise a negative number.",
      "Keep at least one free object in the shop. Most uses cost at least 3 energy, and none of these restores more than 20.",
      keptRestorer
        ? "The shop already has its energy restorer, so none of the new objects restores more than 20 energy."
        : [`Exactly one object is a precious energy restorer — a tonic, a feast, a magic charm, whatever fits the pet —`,
          `that restores ${PET_ITEM_RESTORE_ENERGY_MIN} to ${PET_ITEM_RESTORE_ENERGY_MAX} energy and costs ${PET_ITEM_RESTORE_PRICE_MIN} to`,
          `${PET_ITEM_RESTORE_PRICE_MAX} gold (gold -${PET_ITEM_RESTORE_PRICE_MIN} to -${PET_ITEM_RESTORE_PRICE_MAX}); make it look and sound special.`].join(" "),
      "Medicine is always sold separately; do not offer any.",
      "The object names must describe visually distinct things an artist can draw. Return only through set-pet-items.",
    ].filter(Boolean).join(" "),
    messages: userTurn([
      `Pet: ${input.petTitle}`,
      describeIdentity(input.identity),
      input.stats ? `Stats: ${JSON.stringify(input.stats)}` : "",
      input.mood ? `Mood: ${input.mood}` : "",
      describeMoment(input),
      describeSignals(input.signals),
      input.keeping.length ? `On the shelf: ${input.keeping.map((item) => `${item.title} (${JSON.stringify(item.effects)})`).join(", ")}` : "",
      input.previous?.length ? `Previous items: ${input.previous.join(", ")}` : "",
      input.image ? "The attached picture is the pet; use its visual style." : "",
    ].filter(Boolean).join("\n\n"), input.image ? [input.image] : []),
    tools: { "set-pet-items": tool({ description: "Add new objects to this pet's shop.", inputSchema: schema, execute: async (value) => value }) },
    toolChoice: "required",
    stopWhen: [hasToolCall("set-pet-items"), stepCountIs(2)],
    maxRetries: 1,
    abortSignal: AbortSignal.timeout(30_000),
  });
  await recordTextApiCost(result);
  const call = result.toolCalls.find((candidate) => candidate?.toolName === "set-pet-items");
  if (!call) throw new Error("Pet agent did not generate items");
  const items = schema.parse(call.input).actions;
  const titles = [...items, ...input.keeping].map((item) => item.title.toLocaleLowerCase());
  if (new Set(titles).size !== titles.length) {
    throw new Error("Pet agent generated duplicate items");
  }
  return items;
}
