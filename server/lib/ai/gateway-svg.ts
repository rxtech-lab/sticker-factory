import { z } from "zod";
import { generateText, Output } from "ai";
import { orchestratorModel, svgAuthoringModel } from "./text-model";
import sharp from "sharp";
import { type SVGAnimationRig, type SVGScene, type SVGState } from "@/lib/contracts/controllable";
import { renderSVG } from "@/lib/controllable/sample";
import { recordTextApiCost, reportAiStepUsage } from "./cost";
import { traceEvent } from "@/lib/observability/trace";
import type { AiReferenceImage } from "./gateway-contracts";
import { fromWire, WireRigSchema, WireSceneSchema } from "./svg-wire";

export type SVGAuthoringProgress = {
  stage: "authoring" | "validation" | "review";
  status: "started" | "complete" | "failed";
  attempt: number; maxAttempts: number; durationMs: number;
  message?: string;
  errorType?: string;
};
export type SVGAuthoringInput = {
  reference: AiReferenceImage; brief: string; scene: boolean; requiredStates?: Record<string, string[]>;
  onProgress?: (event: SVGAuthoringProgress) => Promise<void>;
};
export class SVGArtworkValidationError extends Error {}

/** Only expose validation feedback, never a provider response body or request credentials. */
function failureMessage(error: unknown, stage: SVGAuthoringProgress["stage"]): string {
  let cause = error;
  for (let depth = 0; cause && depth < 4; depth++) {
    if (cause instanceof z.ZodError) return cause.issues.slice(0, 3).map(issue => `${issue.path.join(".") || "rig"}: ${issue.message.slice(0, 240)}`).join("; ");
    if (cause instanceof SVGArtworkValidationError) return cause.message.slice(0, 900);
    cause = (cause as { cause?: unknown }).cause;
  }
  return stage === "authoring" ? "The animation service could not finish the SVG artwork."
    : stage === "validation" ? "The SVG artwork could not be validated or rendered."
      : "The artwork review could not finish.";
}
const guidance = `Recreate the supplied approved image faithfully as animated vector artwork. Output is checked by a validator; a response that breaks any HARD RULE is rejected and redrawn.

HARD RULES
1. Every group's markup is one complete SVG document with the SAME width, height and viewBox="0 0 {width} {height}" as the rig.
2. Allowed elements only: svg, g, path, rect, circle, ellipse, polygon, polyline, line, defs, linearGradient, radialGradient, stop, clipPath. Never image, text, use, style, script, a, filter, mask, pattern or foreignObject.
3. Presentation attributes only: no style attribute, CSS, links, entities, namespaced attributes (xlink:) or embedded raster. url() may only reference a local #id. All ids begin with a letter.
4. clipPath sets clipPathUnits="userSpaceOnUse". Radial gradients are centered (no fx/fy). No spreadMethod.
5. Groups bind to states through when: a list of {key, values} entries naming the state values the group is visible in, e.g. [{"key":"pose","values":["walk"]}] or [{"key":"pose","values":["typing","stretch"]},{"key":"expression","values":["focused"]}]. All entries must match (AND); values within one entry are alternatives (OR). Empty when means always visible. defaults is a list of {key, value} with one entry for every key used in any when, e.g. [{"key":"pose","value":"idle"},{"key":"expression","value":"neutral"}].
6. The rig must animate: every pose has at least one group with a track that moves at least 3% of the canvas (x/y in viewBox units), rotates at least 6 degrees, or scales at least 5%. Opacity tracks alone do not count.
7. Tracks start at time 0, frame times strictly increase and stay within duration, interpolation is linear or step, and a group has at most one track per property.
8. emotions is a list of {expression, emotion} with one entry for every expression id, emotion being one of sick, sleepy, grumpy, content, joyful.

STATE KEYS
pose, expression, emotion (sick, sleepy, grumpy, content, joyful), facing (left, right), weather (sunny, cloudy, rainy, snowy, stormy, foggy, windy), night (boolean), sheltered (boolean). All conditions must select real states.

STYLE
Preserve the reference's style, identity, proportions and palette. If it is pixel art, build it from grid-aligned rect pixels with its dark outlines and shading bands rather than smooth flat shapes. colors entries override fills by state. No decorative effects covering the character's face.

STRUCTURE
Each group has a pivot in normalized 0-1 coordinates (track translations use viewBox units), tracks, colors and a nullable depth. Separate poses and expressions into groups so conditions compose them. Split each pose into separately pivoted parts (torso, arms, legs) so limbs swing about their joints. Blink with an eyelid group using a step opacity track. Keep the head and its expression groups still together (expressions are separate groups with no parent) and move the torso, limbs and props instead.

EXAMPLE GROUP (shape only; draw the real artwork)
{"id":"walkLegLeft","markup":"<svg xmlns=\\"http://www.w3.org/2000/svg\\" width=\\"256\\" height=\\"256\\" viewBox=\\"0 0 256 256\\"><rect x=\\"110\\" y=\\"180\\" width=\\"14\\" height=\\"40\\" fill=\\"#2B3A55\\"/></svg>","pivot":{"x":0.45,"y":0.7},"when":[{"key":"pose","values":["walk"]}],"tracks":[{"property":"rotation","duration":0.8,"loop":true,"interpolation":"linear","frames":[{"time":0,"value":-14},{"time":0.4,"value":14},{"time":0.8,"value":-14}]}],"colors":[],"depth":null}

Before answering, check every group against the HARD RULES and confirm each requested pose and expression appears in some group's when.`;
const sceneGuidance = `Create a scene WITHOUT the pet. Include a usable normalized walkable polygon, obstacle polygons, valid spawn on walkable ground, shelter polygons and normalized clock/weather/status fixture centers. Split objects the pet can walk behind into groups with depth equal to their normalized ground contact y; backgrounds have null depth. Include lamps and warm light pools visible only when night=true. Include daytime and nighttime sky groups, window clipping indoors, rain/snow effects, puddles and outdoor umbrellas visible during rain or storms. Weather must not rain indoors; clip it to windows. Emotion changes ambient color/motion, never real weather or daylight. Include the entire original scene, not just effects. Fixtures are blank surfaces for native values. Every scene must include nighttime light and rainy/stormy weather responses. Outdoor scenes must include umbrellas and puddles. Declare effects with group IDs for lights, lightPools, precipitation, umbrellas, puddles, and windows (groupId and normalized bounds polygon). Precipitation in indoor scenes must use clip-path to declared windows. Outdoor rain geometry must exclude shelter roofs so it never falls on a sheltered pet. Include explicit cloudy, rainy, snowy, stormy, foggy and windy bindings. Include emotion-driven color bindings; actual weather and night state always take precedence. Leave .025 horizontal and .015 vertical clearance around the spawn and walking routes. All polygons must be simple and nondegenerate.`;

const characterGuidance = ` Include idle and walk poses as well as all requested poses and expressions; keep one character on a transparent canvas. Every pose must have a clearly different silhouette, not the same drawing with a hand moved: walk is standing with legs apart and alternating, celebrate raises the arms, and so on. Props are their own groups whose when lists only the poses that use them (a desk or chair is hidden while walking). Every requested pose and expression id must appear in at least one group's when, except the defaults pose, which may be drawn by unconditional groups.`;

/** Smallest movement that still reads in a sticker thumbnail; below this a pose looks frozen. */
export function stillPoses(rig: SVGAnimationRig, poses: string[]): string[] {
  const size = Math.min(rig.width, rig.height);
  const visible = (track: SVGAnimationRig["groups"][number]["tracks"][number]) => {
    const values = track.frames.map(f => f.value), range = Math.max(...values) - Math.min(...values);
    return track.property === "x" || track.property === "y" ? range >= size * 0.02
      : track.property === "rotation" ? range >= 4
        : track.property === "opacity" ? false : range >= 0.04;
  };
  return poses.filter(pose => !rig.groups.some(group => (!group.when.pose || group.when.pose.includes(pose)) && group.tracks.some(visible)));
}

/**
 * Required states no group selects. The default pose may be drawn entirely by unconditional groups
 * (the base body every other pose swaps parts of), which renders correctly, so it counts as bound.
 */
export function unboundStates(rig: SVGAnimationRig, required: Record<string, string[]>): string[] {
  return Object.entries(required).flatMap(([key, values]) => values
    .filter(id => !(key === "pose" && rig.defaults.pose === id) && !rig.groups.some(g => g.when[key]?.includes(id)))
    .map(id => `${key} ${id}`));
}

/**
 * Lenient on purpose: providers do not enforce string or array length limits in structured output,
 * so a verbose reviewer must not fail the schema and discard a finished drawing. Trimmed here instead.
 */
const ReviewSchema = z.object({ approved: z.boolean(), corrections: z.array(z.string()) });

/** Returns undefined when the reviewer cannot produce a readable verdict after one retry. */
async function reviewArtwork(reference: AiReferenceImage, contact: Buffer, prompt: string) {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const review = await generateText({
        model: orchestratorModel(),
        output: Output.object({ schema: ReviewSchema }),
        messages: [{ role: "user", content: [
          { type: "text", text: `${prompt} Give at most 6 corrections, each one short sentence.` },
          { type: "image", image: reference.bytes, mediaType: reference.mimeType },
          { type: "image", image: contact, mediaType: "image/png" },
        ] }], maxOutputTokens: 1500, maxRetries: 0, abortSignal: AbortSignal.timeout(60_000),
      });
      await reportAiStepUsage(review); await recordTextApiCost(review);
      return { approved: review.output.approved, corrections: review.output.corrections.slice(0, 6).map(c => c.slice(0, 300)) };
    } catch (error) {
      traceEvent("svg:review:error", { attempt, errorType: error instanceof Error ? error.name : "unknown" });
    }
  }
  return undefined;
}

/** Bounded authoring repair: every attempt receives the actual reference pixels and validation feedback. */
export async function authorSVG(input: SVGAuthoringInput): Promise<SVGAnimationRig | SVGScene> {
  const problems: string[] = [];
  // The last drawing the model returned, so a repair edits it instead of redrawing from scratch.
  let previous: string | undefined;
  for (let attempt = 0; attempt < 3; attempt++) {
    const started = Date.now();
    let stage: SVGAuthoringProgress["stage"] = "authoring";
    let stageStarted = started;
    let reportingFailed = false;
    const report = async (status: SVGAuthoringProgress["status"], message?: string, errorType?: string) => {
      try { await input.onProgress?.({ stage, status, attempt: attempt + 1, maxAttempts: 3, durationMs: Date.now() - stageStarted, message, errorType }); }
      catch (error) { reportingFailed = true; throw error; }
    };
    const advance = async (next: SVGAuthoringProgress["stage"]) => {
      await report("complete");
      stage = next; stageStarted = Date.now();
      await report("started");
    };
    traceEvent("svg:authoring:start", { engine: "svg", scene: input.scene, attempt });
    try {
      await report("started");
      const result = await generateText({
        model: svgAuthoringModel(),
        output: Output.object({ schema: (input.scene ? WireSceneSchema : WireRigSchema) as z.ZodType<unknown> }),
        system: `${guidance}\n\n${input.scene ? sceneGuidance : characterGuidance.trim()}`,
        messages: [
          { role: "user", content: [{ type: "text", text: input.brief }, { type: "image", image: input.reference.bytes, mediaType: input.reference.mimeType }] },
          ...(problems.length ? [
            ...(previous ? [{ role: "assistant" as const, content: previous }] : []),
            { role: "user" as const, content: `${previous ? "Your drawing above was rejected. Return the complete corrected JSON, keeping everything that was already right" : "Your previous drawing was rejected. Draw it again"} and fixing every one of these problems:\n${problems.map(p => `- ${p}`).join("\n")}` },
          ] : []),
        ],
        maxOutputTokens: 32000, maxRetries: 0, abortSignal: AbortSignal.timeout(180_000),
      });
      await reportAiStepUsage(result); await recordTextApiCost(result);
      previous = JSON.stringify(result.output);
      await advance("validation");
      const value = fromWire(result.output, input.scene);
      const rig = "rig" in value ? value.rig : value;
      if (!rig.groups.some(g => g.tracks.some(t => t.frames.some(f => f.value !== t.frames[0].value)))) throw new SVGArtworkValidationError("The SVG needs animated artwork, not just a static poster.");
      if (!input.scene) {
        const still = stillPoses(rig, input.requiredStates?.pose ?? [String(rig.defaults.pose ?? "idle")]);
        if (still.length) throw new SVGArtworkValidationError(`Motion is too small to see in poses ${still.join(", ")}: give each a limb or body track moving at least 3% of the canvas or rotating 6 degrees.`);
      }
      const unbound = unboundStates(rig, input.requiredStates ?? {});
      if (unbound.length) throw new SVGArtworkValidationError(`Missing bindings: ${unbound.join(", ")}. Give each a group whose when lists it.`);
      const unmapped = (input.requiredStates?.expression ?? []).filter(id => !rig.emotions[id]);
      if (unmapped.length) throw new SVGArtworkValidationError(`Missing emotion mapping: ${unmapped.join(", ")}`);
      const representativeStates: SVGState[] = [{}, { night: true }, { weather: "rainy" }, { emotion: "joyful" }, ...Object.entries(input.requiredStates ?? {}).flatMap(([key, values]) => values.map(value => ({ [key]: value })))];
      for (const state of representativeStates) {
        await sharp(Buffer.from(renderSVG(rig, state, 0.5))).resize(256, 256, { fit: "inside" }).png().toBuffer();
      }
      const expression = input.requiredStates?.expression.at(-1) ?? rig.defaults.expression;
      const pose = input.requiredStates?.pose.at(-1) ?? rig.defaults.pose;
      const reviewStates: SVGState[] = input.scene
        ? [{}, { night: true }, { weather: "rainy" }, { weather: "rainy", emotion: "joyful" }]
        : [{}, { pose: "walk" }, { expression }, { pose, expression }];
      const samples = await Promise.all(reviewStates.map(async (state, index) => ({
        input: await sharp(Buffer.from(renderSVG(rig, state, index * 0.3))).resize(256, 256, { fit: "contain", background: "#DADADA" }).png().toBuffer(), left: (index % 2) * 256, top: Math.floor(index / 2) * 256,
      })));
      const contact = await sharp({ create: { width: 512, height: 512, channels: 4, background: "#DADADA" } }).composite(samples).png().toBuffer();
      await advance("review");
      const review = await reviewArtwork(input.reference, contact, `Compare the original reference with the SVG contact sheet. The brief was: ${input.brief.slice(0, 1200)} States in reading order: ${JSON.stringify(reviewStates)}. The contact sheet is a hand-authored vector redraw, so simplified shading, softer pixel edges and small proportion differences are expected and acceptable. Verify the character is recognizably the same (hair, outfit, palette, silhouette), everything the brief asks for is present, and nothing is clipped, missing or duplicated. Requested poses and expressions are supposed to differ from the reference, and from each other: reject poses that share one silhouette or a walk pose that is not standing. ${input.scene ? "Verify lit lamps at night and umbrellas/shelter/weather in rain, no pet painted into the background. Joyful emotion must retain the rain." : "Verify the complete character matches the reference in walking and expression states, without missing limbs or a duplicate face."} Approve only if usable; otherwise give concrete corrections.`);
      // The artwork already passed every structural check; an unreadable review is not worth a new drawing.
      if (!review) {
        await report("complete", "SVG artwork passed validation; the visual review was unavailable.");
        traceEvent("svg:review:unavailable", { engine: "svg", scene: input.scene, attempt, durationMs: Date.now() - started });
        return value;
      }
      // The final attempt already passed every structural check; keep it rather than fail a paid job over polish.
      if (!review.approved && attempt === 2) {
        await report("complete", "SVG artwork accepted; it may differ slightly from the reference style.");
        traceEvent("svg:review:accepted-with-corrections", { engine: "svg", scene: input.scene, attempt, durationMs: Date.now() - started });
        return value;
      }
      if (!review.approved) throw new SVGArtworkValidationError(review.corrections.join("; ") || "The artwork needs another pass to match the reference.");
      await report("complete");
      traceEvent("svg:authoring:complete", { engine: "svg", scene: input.scene, attempt, durationMs: Date.now() - started });
      return value;
    } catch (error) {
      // A cancelled job or failed status write must not buy another authoring attempt.
      if (reportingFailed) throw error;
      // Output that failed the schema still beats a blank page as the starting point for a repair.
      const rejected = (error as { text?: unknown }).text;
      if (stage === "authoring" && typeof rejected === "string" && rejected.trim()) previous = rejected;
      const message = failureMessage(error, stage);
      await report("failed", message, error instanceof Error ? error.name.slice(0, 80) : "unknown");
      traceEvent("svg:validation:failed", { engine: "svg", scene: input.scene, attempt, durationMs: Date.now() - started, errorType: error instanceof Error ? error.name : "unknown" });
      if (attempt === 2) throw error;
      // Keep earlier failures too, so fixing the latest problem does not reintroduce an older one.
      problems.push(message);
    }
  }
  throw new Error("SVG authoring failed");
}
