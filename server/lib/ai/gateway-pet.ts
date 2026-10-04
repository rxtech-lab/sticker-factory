// The pet's mood: one short look at a sticker the user just sent, answered with the pose their pet
// should hold on the watch and widget until the next one.

import { gateway } from "@ai-sdk/gateway";
import { generateText, hasToolCall, stepCountIs, tool } from "ai";
import { z } from "zod";
import { recordTextApiCost, reportAiStepUsage } from "@/lib/ai/cost";
import { PET_ACTION_GOLD_EARN_MAX, PET_ACTION_GOLD_MAX, PET_CLASSES, PET_WEATHER_KINDS, type PetIdentityV1, type PetSignalsV1 } from "@/lib/contracts/api";
import type { AiOwnerMoment, AiPetActionsContext, AiPetEvolutionChoice, AiPetStickerContext, AiPetStickerReaction, AiPetEventContext, AiPetHeadlinesContext, AiPetInteractionContext, AiPetPhotoContext, AiPetPersona, AiPetPersonaContext, AiPetStatus, AiPetStatusContext, PetAction } from "./gateway-contracts";
import { userTurn } from "./gateway-models";

const PetStatusInputSchema = z.object({
  values: z.record(z.string(), z.union([z.string(), z.number(), z.boolean()])),
  caption: z.string().trim().min(1).max(60),
}).strict();

/** A send's reading: the pose and caption, plus how the sticker's mood moves the stats. */
const PetSendStatusInputSchema = PetStatusInputSchema.extend({
  effects: z.object({
    happiness: z.number().int().min(-8).max(8),
    hp: z.number().int().min(-8).max(8),
    energy: z.number().int().min(-8).max(8),
  }).strict(),
}).strict();

const PetPersonaInputSchema = z.object({
  class: z.enum(PET_CLASSES),
  personality: z.string().trim().min(1).max(80),
  likes: z.array(z.string().trim().min(1).max(32)).min(1).max(4),
  dislikes: z.array(z.string().trim().min(1).max(32)).min(1).max(4),
  favoriteWeather: z.enum(PET_WEATHER_KINDS),
}).strict();

/** What the pet asks the planner for when it decides to grow. */
const PetEvolveInputSchema = z.object({ brief: z.string().trim().min(1).max(400) }).strict();

/**
 * The extra instruction a pet that may grow is given. Growing redraws its sticker in the
 * background, so it is meant to be rare: a milestone, not a pat on the head.
 */
function evolutionGuidance(input: AiPetEvolutionChoice): string {
  if (!input.canEvolve) return "";
  return [
    "You may also decide to grow from this moment. Only when it truly matters — a feeling or a moment none of",
    "your current controls can show, a milestone, something new you just learned — set evolve.brief: one or two",
    "sentences in English for the artist who draws you, asking for exactly one new thing on your own sticker:",
    "a new mood (a new option on your mood or expression control), a new pose or property (a new choice option",
    "or a toggle), or a small accessory. Ask to keep everything you already are unchanged. Most moments are not",
    "a reason to grow: leave evolve out unless this one clearly is.",
  ].join(" ");
}

const PetHeadlinesInputSchema = z.object({ headlines: z.array(z.string().trim().min(1).max(160)).max(3) }).strict();

/** Who the pet is, in the words the model reads it in. */
function describeIdentity(identity: PetIdentityV1 | null | undefined): string {
  if (!identity) return "Identity: not yet known";
  return [
    `Class: ${identity.class}`,
    `Personality: ${identity.personality}`,
    `Likes: ${identity.likes.join(", ") || "nothing in particular"}`,
    `Dislikes: ${identity.dislikes.join(", ") || "nothing in particular"}`,
    `Favourite weather: ${identity.favoriteWeather}`,
  ].join("\n");
}

/** The owner's world right now, or a line saying the pet does not know. */
function describeSignals(signals: PetSignalsV1 | null | undefined): string {
  if (!signals) return "World: unknown";
  return [
    signals.weather ? `Weather: ${signals.weather.kind}, ${signals.weather.temperatureC}°C, ${signals.weather.isDay ? "day" : "night"}` : "Weather: unknown",
    signals.stepsToday !== null ? `Owner's steps today: ${signals.stepsToday}` : "Owner's steps today: unknown",
    signals.headlines.length ? `Recent news:\n${signals.headlines.map((headline) => `- ${headline}`).join("\n")}` : "Recent news: none",
  ].join("\n");
}

/** The owner's time and place, as lines for the model; empty when the phone has told us neither. */
function describeMoment(input: AiOwnerMoment): string {
  return [
    input.localTime ? `Owner's local time: ${input.localTime}` : "",
    input.location ? `Owner's rough location: latitude ${input.location.latitude}, longitude ${input.location.longitude}` : "",
  ].filter(Boolean).join("\n");
}

const PetEffectsInputSchema = z.object({
  happiness: z.number().int().min(-20).max(20),
  hp: z.number().int().min(-20).max(20),
  energy: z.number().int().min(-20).max(20),
}).strict();

const PetActionsInputSchema = z.object({ actions: z.array(z.object({
  title: z.string().trim().min(1).max(32),
  description: z.string().trim().min(1).max(120),
  effects: PetEffectsInputSchema.extend({ gold: z.number().int().min(-PET_ACTION_GOLD_MAX).max(PET_ACTION_GOLD_EARN_MAX) }).strict(),
}).strict()).min(3).max(5) }).strict();

/** The controls as the model reads them: ids it must answer with, labels it can reason about. */
function describeControls(input: Pick<AiPetStatusContext, "controls">): string {
  return input.controls.map((control) => {
    if (control.type === "choice") {
      const options = control.options.map((option) => `${option.id} ("${option.label}")`).join(", ");
      return `- ${control.id} ("${control.label}"): choose one of ${options}; default ${control.defaultValue}`;
    }
    if (control.type === "toggle") return `- ${control.id} ("${control.label}"): true or false; default ${control.defaultValue}`;
    return `- ${control.id} ("${control.label}"): animation speed from ${control.minimum} to ${control.maximum}; default ${control.defaultValue}`;
  }).join("\n");
}

/**
 * The actions the owner can pick from right now. Made when a sticker becomes a pet, and made again
 * whenever its mood changes, so what is on offer follows how the pet feels: a tired pet is offered
 * rest, a bored one an adventure. The owner never writes these; the agent decides all of them.
 */
export async function generatePetActions(input: AiPetActionsContext): Promise<Omit<PetAction, "id">[]> {
  const result = await generateText({
    onLanguageModelCallEnd: reportAiStepUsage,
    model: gateway(process.env.AI_SUMMARY_MODEL ?? process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
    system: [
      "Design 3 to 5 playful actions an owner can perform with this exact sticker character right now.",
      "Look at its picture, name, and available poses. Make each action specific to what the character is or does.",
      "Fit them to how the pet feels at the moment: its mood, its stats, its personality and likes, the owner's",
      "local time and place, and the world around it. Low energy calls for something restful, low HP for care,",
      "low happiness for comfort or fun; late at night, something quiet; a morning, something to start the day.",
      `Gold is the pet's money, and it comes from the owner's walks, not from actions. Set each action's gold from`,
      `-${PET_ACTION_GOLD_MAX} to ${PET_ACTION_GOLD_EARN_MAX}: negative for treats, toys, outings and other things that cost money,`,
      "0 for free things. Most actions are free or cost gold, and at least one is free. Rarely, and only when gold is",
      `low, one action may earn a little (1 to ${PET_ACTION_GOLD_EARN_MAX}) for a small chore; never more than one. Never price an action above what it is worth.`,
      "When earlier actions are listed, offer a fresh mix; keep one only if it still fits the mood best.",
      "Give each action a short button title and a description of what happens, in the language of the pet's name.",
      "Set small, plausible changes to happiness, HP, and energy, each from -20 to 20; most fun has a cost.",
      "Doing things tires the pet: every action costs energy (-3 or less), except at most one restful action",
      "that may restore it.",
      "Return only through set-pet-actions, exactly once. Do not use generic pet/play/feed/rest actions unless the character itself calls for one.",
    ].join(" "),
    messages: userTurn([
      `Pet: ${input.petTitle}`,
      input.identity !== undefined ? describeIdentity(input.identity) : "",
      input.stats ? `Stats: ${JSON.stringify(input.stats)}` : "",
      input.mood ? `Mood right now: ${input.mood}` : "",
      describeMoment(input),
      input.signals !== undefined ? describeSignals(input.signals) : "",
      input.previous?.length ? `Earlier actions: ${input.previous.join(", ")}` : "",
      `Controls:\n${describeControls(input)}`,
      input.image ? "The attached picture is this pet." : "Use its name and controls to infer its character.",
    ].filter(Boolean).join("\n\n"), input.image ? [input.image] : []),
    tools: { "set-pet-actions": tool({
      description: "Save the interactive actions offered for this pet right now.",
      inputSchema: PetActionsInputSchema,
      execute: async (value) => value,
    }) },
    toolChoice: "required",
    stopWhen: [hasToolCall("set-pet-actions"), stepCountIs(2)],
    maxRetries: 1,
    abortSignal: AbortSignal.timeout(30_000),
  });
  await recordTextApiCost(result);
  const call = result.toolCalls.find((candidate) => candidate?.toolName === "set-pet-actions");
  if (!call) throw new Error("Pet agent did not generate actions");
  const actions = PetActionsInputSchema.parse(call.input).actions;
  if (new Set(actions.map((action) => action.title.toLocaleLowerCase())).size !== actions.length) {
    throw new Error("Pet agent generated duplicate actions");
  }
  return actions;
}

export async function choosePetStatus(input: AiPetStatusContext): Promise<AiPetStatus> {
  const tools = {
    "set-pet-status": tool({
      description: "Set the pet's pose, the short caption shown under it, and how the sticker's mood moves its stats.",
      inputSchema: PetSendStatusInputSchema,
      execute: async (value) => value,
    }),
  };
  const sent = [
    `Title: ${input.sent.title}`,
    `Kind: ${input.sent.kind}`,
    input.sent.emoji ? `Emoji: ${input.sent.emoji}` : "",
    input.sent.image ? "The attached image is the sticker that was sent." : "",
  ].filter(Boolean).join("\n");
  const result = await generateText({
    // Feeds the chat screen's live token meter; see `reportAiStepUsage`.
    onLanguageModelCallEnd: reportAiStepUsage,
    // Runs after the send has already been answered, once per sticker sent, so it takes the cheap
    // model the title summary uses rather than the orchestrator's.
    model: gateway(process.env.AI_SUMMARY_MODEL ?? process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
    system: [
      "You look after a user's virtual pet, shown on their Apple Watch and home screen widget.",
      "The user just sent a sticker to a friend. Read what that sticker says about how the user is",
      "feeling or what they are up to, and pose the pet to match by setting its controls.",
      "Answer only through set-pet-status, exactly once. Use only the control ids and option ids",
      "listed; leave out a control to keep its current value. The caption is a few warm words in the",
      "pet's voice about its mood, at most 60 characters, in the language of the sticker's title.",
      "If the sticker says nothing about mood, keep the current pose and say something calm.",
      "Stay in character: the pet's class, personality and likes colour how it reacts. It may mention",
      "the weather, its owner's steps, a headline, or the event that just happened when it fits.",
      "Let the owner's local time and place colour it too: sleepy late at night, bright in the morning.",
      "Set effects from -8 to 8 for how the sticker's mood moves happiness, HP and energy; mostly small.",
    ].join(" "),
    messages: userTurn([
      `Pet: ${input.petTitle}`,
      describeIdentity(input.identity),
      input.stats ? `Stats: ${JSON.stringify(input.stats)}` : "",
      describeSignals(input.signals),
      describeMoment(input),
      input.event ? `Just happened: ${input.event.title} — ${input.event.detail}` : "",
      `Controls:\n${describeControls(input)}`,
      `Current pose: ${input.current ? JSON.stringify(input.current) : "defaults"}`,
      `Sticker sent:\n${sent}`,
    ].filter(Boolean).join("\n\n"), input.sent.image ? [input.sent.image] : []),
    tools,
    toolChoice: "required",
    stopWhen: [hasToolCall("set-pet-status"), stepCountIs(2)],
    // Nobody is waiting on this; a pet that misses one mood keeps the last one.
    maxRetries: 1,
    abortSignal: AbortSignal.timeout(30_000),
  });
  await recordTextApiCost(result);
  const call = result.toolCalls.find((candidate) => candidate?.toolName === "set-pet-status");
  if (!call) throw new Error("Pet agent did not call set-pet-status");
  return PetSendStatusInputSchema.parse(call.input);
}

/** A direct interaction gets a fresh line in the pet's voice and a matching validatable pose. */
export async function respondToPetInteraction(input: AiPetInteractionContext): Promise<AiPetStatus> {
  const result = await generateText({
    onLanguageModelCallEnd: reportAiStepUsage,
    model: gateway(process.env.AI_SUMMARY_MODEL ?? process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
    system: [
      "You are a friendly virtual pet. The owner has just interacted with you.",
      "Reply in the pet's voice with one warm, specific sentence (at most 60 characters).",
      "Use the language of the pet's name. Choose controls to pose yourself for the action.",
      "Answer only through respond-as-pet, exactly once. Use only listed control and option ids.",
      "Omit a control to keep its current value. Never claim an action happened if it did not.",
      "Fit the reply to the owner's local time and place when they are given.",
      evolutionGuidance(input),
    ].filter(Boolean).join(" "),
    messages: userTurn([
      `Pet: ${input.petTitle}`,
      `Action: ${input.action.title} — ${input.action.description}`,
      `Stats after action: ${JSON.stringify(input.stats)}`,
      describeMoment(input),
      `Controls:\n${describeControls(input)}`,
      `Current pose: ${input.current ? JSON.stringify(input.current) : "defaults"}`,
    ].filter(Boolean).join("\n\n"), []),
    tools: { "respond-as-pet": tool({
      description: "Set the pet's new pose and spoken response.",
      inputSchema: input.canEvolve ? PetStatusInputSchema.extend({ evolve: PetEvolveInputSchema.optional() }).strict() : PetStatusInputSchema,
      execute: async (value) => value,
    }) },
    toolChoice: "required",
    stopWhen: [hasToolCall("respond-as-pet"), stepCountIs(2)],
    maxRetries: 1,
    abortSignal: AbortSignal.timeout(30_000),
  });
  await recordTextApiCost(result);
  const call = result.toolCalls.find((candidate) => candidate?.toolName === "respond-as-pet");
  if (!call) throw new Error("Pet agent did not respond to interaction");
  return input.canEvolve
    ? PetStatusInputSchema.extend({ evolve: PetEvolveInputSchema.optional() }).strict().parse(call.input)
    : PetStatusInputSchema.parse(call.input);
}

/** The pet looks at a picture its owner showed it, says what it thinks, and is moved by it. */
export async function reactToPetPhoto(input: AiPetPhotoContext): Promise<AiPetStatus> {
  const result = await generateText({
    onLanguageModelCallEnd: reportAiStepUsage,
    model: gateway(process.env.AI_SUMMARY_MODEL ?? process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
    system: [
      "You are a virtual pet. Your owner just showed you the attached picture. Look at what is in it and react",
      "in one warm, specific sentence (at most 60 characters) about what you see, in character and in the language",
      "of your name. Pose yourself to match by setting your controls. Set effects from -8 to 8 for how the picture",
      "moves your happiness, HP and energy: something you like cheers you, something you dislike or find scary",
      "upsets you, food may make you hungry. Mostly small. Answer only through react-to-photo, exactly once. Use only",
      "listed control and option ids, and omit a control to keep its current value. The owner's local time and",
      "place, when given, may colour your reaction.",
      evolutionGuidance(input),
    ].filter(Boolean).join(" "),
    messages: userTurn([
      `Pet: ${input.petTitle}`,
      describeIdentity(input.identity),
      `Stats now: ${JSON.stringify(input.stats)}`,
      describeSignals(input.signals),
      describeMoment(input),
      `Controls:\n${describeControls(input)}`,
      `Current pose: ${input.current ? JSON.stringify(input.current) : "defaults"}`,
      "The attached picture is what your owner just showed you.",
    ].filter(Boolean).join("\n\n"), [input.photo]),
    tools: { "react-to-photo": tool({
      description: "Set the pet's pose, what it says about the picture, and how the picture moves its stats.",
      inputSchema: input.canEvolve ? PetSendStatusInputSchema.extend({ evolve: PetEvolveInputSchema.optional() }).strict() : PetSendStatusInputSchema,
      execute: async (value) => value,
    }) },
    toolChoice: "required",
    stopWhen: [hasToolCall("react-to-photo"), stepCountIs(2)],
    maxRetries: 1,
    abortSignal: AbortSignal.timeout(30_000),
  });
  await recordTextApiCost(result);
  const call = result.toolCalls.find((candidate) => candidate?.toolName === "react-to-photo");
  if (!call) throw new Error("Pet agent did not react to the photo");
  return input.canEvolve
    ? PetSendStatusInputSchema.extend({ evolve: PetEvolveInputSchema.optional() }).strict().parse(call.input)
    : PetSendStatusInputSchema.parse(call.input);
}

/**
 * Decides who a newly adopted pet is. Only the class and the words: max HP and the energy
 * multiplier are derived from the class on the server.
 */
export async function generatePetPersona(input: AiPetPersonaContext): Promise<AiPetPersona> {
  const result = await generateText({
    onLanguageModelCallEnd: reportAiStepUsage,
    model: gateway(process.env.AI_SUMMARY_MODEL ?? process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
    system: [
      "A user just adopted this sticker character as a virtual pet. Decide who it is.",
      `Pick one class: ${PET_CLASSES.join(", ")}. Write a personality of a few words, 1 to 4 short likes and`,
      "1 to 4 short dislikes (single words or short phrases such as 'rain', 'naps', 'long walks'), and a favourite",
      `weather from: ${PET_WEATHER_KINDS.join(", ")}. Fit everything to the character's look and name.`,
      "Write the words in the language of the pet's name. Answer only through set-pet-persona, exactly once.",
    ].join(" "),
    messages: userTurn([
      `Pet: ${input.petTitle}`,
      `Controls:\n${describeControls(input)}`,
      `The world on adoption day:\n${describeSignals(input.birth)}`,
      input.image ? "The attached picture is this pet." : "Use its name and controls to infer its character.",
    ].join("\n\n"), input.image ? [input.image] : []),
    tools: { "set-pet-persona": tool({
      description: "Save the new pet's class, personality and preferences.",
      inputSchema: PetPersonaInputSchema,
      execute: async (value) => value,
    }) },
    toolChoice: "required",
    stopWhen: [hasToolCall("set-pet-persona"), stepCountIs(2)],
    maxRetries: 1,
    abortSignal: AbortSignal.timeout(30_000),
  });
  await recordTextApiCost(result);
  const call = result.toolCalls.find((candidate) => candidate?.toolName === "set-pet-persona");
  if (!call) throw new Error("Pet agent did not set a persona");
  return PetPersonaInputSchema.parse(call.input);
}

/**
 * A web search for what is going on around the owner today, boiled down to three headlines the pet
 * can have an opinion about. The search runs inside the gateway; only the headlines come back.
 */
export async function searchPetHeadlines(input: AiPetHeadlinesContext): Promise<string[]> {
  const where = input.latitude !== null && input.longitude !== null
    ? `near latitude ${input.latitude}, longitude ${input.longitude}` : input.timeZone ? `in the ${input.timeZone} time zone` : "worldwide";
  const result = await generateText({
    onLanguageModelCallEnd: reportAiStepUsage,
    model: gateway(process.env.AI_SUMMARY_MODEL ?? process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
    system: [
      "Find a few light, recent, non-graphic news items a cute virtual pet could react to.",
      "Search the web once or twice, then answer through set-headlines with at most three short headlines",
      "(under 120 characters each). Prefer local and everyday news — weather, events, sport, science, animals.",
      "Avoid violence, disasters with casualties, and politics. Return an empty list if nothing suitable turns up.",
    ].join(" "),
    prompt: [
      `Date: ${input.date}`,
      `Where: ${where}`,
      input.interests.length ? `The pet is interested in: ${input.interests.join(", ")}` : "",
    ].filter(Boolean).join("\n"),
    tools: {
      search: gateway.tools.perplexitySearch({ maxResults: 5, searchRecencyFilter: "day" }),
      "set-headlines": tool({
        description: "Save up to three short headlines.",
        inputSchema: PetHeadlinesInputSchema,
        execute: async (value) => value,
      }),
    },
    stopWhen: [hasToolCall("set-headlines"), stepCountIs(4)],
    maxRetries: 1,
    abortSignal: AbortSignal.timeout(45_000),
  });
  await recordTextApiCost(result);
  const call = result.steps.flatMap((step) => step.toolCalls).find((candidate) => candidate?.toolName === "set-headlines");
  if (!call) throw new Error("Pet agent did not return headlines");
  return PetHeadlinesInputSchema.parse(call.input).headlines;
}

/** The pet reacts, in character, to something that happened to it while its owner was away. */
export async function narratePetEvent(input: AiPetEventContext): Promise<AiPetStatus> {
  const result = await generateText({
    onLanguageModelCallEnd: reportAiStepUsage,
    model: gateway(process.env.AI_SUMMARY_MODEL ?? process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
    system: [
      "You are a virtual pet. Something just happened to you; tell your owner about it in one warm, specific",
      "sentence (at most 60 characters), in character and in the language of your name. Pose yourself to match",
      "by setting your controls. Answer only through respond-as-pet, exactly once. Use only listed control and",
      "option ids, and omit a control to keep its current value. Fit it to the owner's local time and place when given.",
    ].join(" "),
    messages: userTurn([
      `Pet: ${input.petTitle}`,
      describeIdentity(input.identity),
      `Stats now: ${JSON.stringify(input.stats)}`,
      describeSignals(input.signals),
      describeMoment(input),
      `What happened: ${input.event.title} — ${input.event.detail}`,
      `Controls:\n${describeControls(input)}`,
      `Current pose: ${input.current ? JSON.stringify(input.current) : "defaults"}`,
    ].filter(Boolean).join("\n\n"), []),
    tools: { "respond-as-pet": tool({
      description: "Set the pet's new pose and what it says.",
      inputSchema: PetStatusInputSchema,
      execute: async (value) => value,
    }) },
    toolChoice: "required",
    stopWhen: [hasToolCall("respond-as-pet"), stepCountIs(2)],
    maxRetries: 1,
    abortSignal: AbortSignal.timeout(30_000),
  });
  await recordTextApiCost(result);
  const call = result.toolCalls.find((candidate) => candidate?.toolName === "respond-as-pet");
  if (!call) throw new Error("Pet agent did not narrate the event");
  return PetStatusInputSchema.parse(call.input);
}

const PetStickerReactionInputSchema = z.discriminatedUnion("react", [
  z.object({ react: z.literal(false) }).strict(),
  PetSendStatusInputSchema.extend({ react: z.literal(true) }).strict(),
]);

/**
 * Its owner just made a new sticker. The pet looks at it and decides whether it cares: a sticker
 * of something it likes, or one that looks like a friend, gets a reaction; most get let pass.
 */
export async function noticePetSticker(input: AiPetStickerContext): Promise<AiPetStickerReaction> {
  const result = await generateText({
    onLanguageModelCallEnd: reportAiStepUsage,
    model: gateway(process.env.AI_SUMMARY_MODEL ?? process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
    system: [
      "You are a virtual pet. Your owner just made a new sticker, attached. Decide whether you care.",
      "React only when it means something to you: it shows something you like or dislike, looks like you or a",
      "friend, fits the moment, or is simply delightful. Otherwise answer react false and nothing else.",
      "When you react, say one warm, specific sentence (at most 60 characters) about the sticker, in character and",
      "in the language of your name; pose yourself to match by setting your controls; and set effects from -8 to 8",
      "for how it moves your happiness, HP and energy, mostly small. Use only listed control and option ids, and",
      "omit a control to keep its current value. Answer only through notice-sticker, exactly once.",
    ].join(" "),
    messages: userTurn([
      `Pet: ${input.petTitle}`,
      describeIdentity(input.identity),
      `Stats now: ${JSON.stringify(input.stats)}`,
      describeSignals(input.signals),
      describeMoment(input),
      `Controls:\n${describeControls(input)}`,
      `Current pose: ${input.current ? JSON.stringify(input.current) : "defaults"}`,
      `New sticker: ${input.made.title} (${input.made.kind})`,
      input.made.image ? "The attached image is the new sticker." : "",
    ].filter(Boolean).join("\n\n"), input.made.image ? [input.made.image] : []),
    tools: { "notice-sticker": tool({
      description: "Decide whether the pet reacts to the new sticker, and if so how.",
      inputSchema: PetStickerReactionInputSchema,
      execute: async (value) => value,
    }) },
    toolChoice: "required",
    stopWhen: [hasToolCall("notice-sticker"), stepCountIs(2)],
    maxRetries: 1,
    abortSignal: AbortSignal.timeout(30_000),
  });
  await recordTextApiCost(result);
  const call = result.toolCalls.find((candidate) => candidate?.toolName === "notice-sticker");
  if (!call) throw new Error("Pet agent did not decide about the new sticker");
  return PetStickerReactionInputSchema.parse(call.input);
}
