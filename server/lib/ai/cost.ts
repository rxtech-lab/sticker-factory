import { AsyncLocalStorage } from "node:async_hooks";

/** RxSubscription grants 700 points for every 10 USD of API spend. */
export const POINTS_PER_USD = 70;

/**
 * USD is kept as an integer while a chat turn is running so several small text
 * calls are rounded up once as a whole, rather than each costing a full point.
 */
export const NANODOLLARS_PER_USD = 1_000_000_000;

export type AiApiCostEvent =
  | { kind: "text"; costNanodollars: number }
  | { kind: "image"; costNanodollars: number; points: number }
  | { kind: "video"; costNanodollars: number; points: number };

type CostRecorder = (event: AiApiCostEvent) => Promise<void>;

const recorderStorage = new AsyncLocalStorage<CostRecorder>();

/** Installs the recorder used by every Gateway call made during one workflow step. */
export function withAiApiCostRecorder<T>(recorder: CostRecorder, run: () => Promise<T>): Promise<T> {
  return recorderStorage.run(recorder, run);
}

/** Converts the Gateway's decimal USD value without accumulating float drift. */
export function apiCostNanodollars(costUsd: number | string): number {
  const parsed = typeof costUsd === "number" ? costUsd : Number(costUsd);
  if (!Number.isFinite(parsed) || parsed < 0) {
    throw new Error("AI Gateway returned an invalid API cost");
  }
  return Math.round(parsed * NANODOLLARS_PER_USD);
}

/**
 * The conversion: 10 USD = 700 points, rounded up to a whole point.
 *
 * Rounding up means any spend that is not exactly zero costs at least one
 * point, so no request is ever handed out for free.
 */
export function apiCostPoints(costUsd: number | string): number {
  return Math.ceil(apiCostNanodollars(costUsd) * POINTS_PER_USD / NANODOLLARS_PER_USD);
}

/**
 * Reads the authoritative request charge returned by Vercel AI Gateway.
 * It is currently a decimal string, but accepting a number keeps the boundary
 * compatible with both the wire response and test fixtures.
 */
export function gatewayCostUsd(providerMetadata: unknown): number | string | undefined {
  if (!providerMetadata || typeof providerMetadata !== "object") return undefined;
  const gateway = (providerMetadata as Record<string, unknown>).gateway;
  if (!gateway || typeof gateway !== "object") return undefined;
  const cost = (gateway as Record<string, unknown>).cost;
  return typeof cost === "number" || typeof cost === "string" ? cost : undefined;
}

/**
 * Reports what one model round trip wrote, while the call it belongs to is still running.
 *
 * Separate from the cost recorder above, which cannot do this job: `recordTextApiCost` runs after
 * `generateText` resolves, and a chat turn's tool loop takes minutes to resolve — so a meter fed
 * from it stays empty for exactly the wait it exists to fill. `onStepEnd` fires per round trip, so
 * the count climbs while the agent is still working.
 *
 * Nothing bills on this. The charge stays with the cost recorder, which reads the Gateway's own
 * price rather than a token count.
 */
type StepUsageReporter = (outputTokens: number) => Promise<void>;

const usageStorage = new AsyncLocalStorage<StepUsageReporter>();

/** Installs the reporter every Gateway text call reports its per-step usage to. */
export function withAiStepUsageReporter<T>(reporter: StepUsageReporter, run: () => Promise<T>): Promise<T> {
  return usageStorage.run(reporter, run);
}

/**
 * Pass as `onStepEnd` on every Gateway text call.
 *
 * Reads the count through `stepOutputTokens` rather than off the field directly: the AI SDK flattens
 * output tokens to a number at the result level and the provider protocol reports them as a
 * breakdown (`{ total, text, reasoning }`), and which of the two arrives here is a property of the
 * installed version, not of this code. Accepting both means an SDK upgrade cannot quietly empty the
 * meter.
 *
 * Swallows its own failures: this is a progress readout, and the AI SDK would otherwise let a
 * failed event insert take down the generation the user is paying for.
 */
export async function reportAiStepUsage(
  step: { usage?: { outputTokens?: number | { total?: number } } },
): Promise<void> {
  const reporter = usageStorage.getStore();
  if (!reporter) return;
  const tokens = stepOutputTokens(step.usage?.outputTokens);
  if (tokens === undefined) return;
  try {
    await reporter(tokens);
  } catch {
    // Reported nowhere on purpose: the caller's own tracing covers the write that failed.
  }
}

function stepOutputTokens(value: number | { total?: number } | undefined): number | undefined {
  const total = typeof value === "object" && value !== null ? value.total : value;
  if (typeof total !== "number" || !Number.isFinite(total) || total <= 0) return undefined;
  return Math.round(total);
}

/** Records every provider step in one text/tool-loop call. */
export async function recordTextApiCost(result: {
  steps: ReadonlyArray<{ providerMetadata?: unknown }>;
}): Promise<void> {
  const recorder = recorderStorage.getStore();
  if (!recorder) return;

  let costNanodollars = 0;
  for (const step of result.steps) {
    const cost = gatewayCostUsd(step.providerMetadata);
    if (cost === undefined) {
      throw new Error("AI Gateway did not return API pricing for a chat response");
    }
    costNanodollars += apiCostNanodollars(cost);
  }
  await recorder({ kind: "text", costNanodollars });
}

/** Records one image response, rounding this image independently as requested. */
export async function recordImageApiCost(result: { providerMetadata?: unknown }): Promise<void> {
  const recorder = recorderStorage.getStore();
  if (!recorder) return;

  const cost = gatewayCostUsd(result.providerMetadata);
  if (cost === undefined) {
    throw new Error("AI Gateway did not return API pricing for an image response");
  }
  await recorder({
    kind: "image",
    costNanodollars: apiCostNanodollars(cost),
    points: apiCostPoints(cost),
  });
}

/**
 * Gateway list prices per output second, in USD, for the video models a deployment may name.
 *
 * Used only when a video response carries no `gateway.cost`. Whether the Gateway prices video the
 * way it prices images is not something this code can verify ahead of the first real call, and
 * "no price" must not mean "free" — so the fallback is the published rate, which errs on the side
 * of charging what the model card says the clip costs. Keep this in step with
 * `https://ai-gateway.vercel.sh/v1/models` when adding a model.
 */
export const VIDEO_MODEL_USD_PER_SECOND: Readonly<Record<string, Readonly<Record<string, number>>>> = {
  "bytedance/seedance-v1.0-pro-fast": { "480p": 0.0097, "720p": 0.0206, "1080p": 0.049 },
  "bytedance/seedance-v1.5-pro": { "480p": 0.0121, "720p": 0.0259, "1080p": 0.0583 },
  "spacexai/grok-imagine-video": { "480p": 0.05, "720p": 0.07 },
};

export interface VideoPricingInput {
  modelId: string;
  resolution: string;
  durationSeconds: number;
}

/**
 * The pricing tier a resolution string falls in.
 *
 * The Gateway prices video by named tier (`480p`), while the AI SDK spells a resolution as
 * `{width}x{height}`; a deployment may configure either. A dimension pair is priced by its shorter
 * side, which is what the tier names count.
 */
export function videoPricingTier(resolution: string): string {
  const pair = /^(\d+)x(\d+)$/i.exec(resolution.trim());
  if (!pair) return resolution.trim().toLowerCase();
  return `${Math.min(Number(pair[1]), Number(pair[2]))}p`;
}

/** The list-price estimate for one clip, or `undefined` when the model or resolution is unknown. */
export function estimatedVideoCostUsd(input: VideoPricingInput): number | undefined {
  const perSecond = VIDEO_MODEL_USD_PER_SECOND[input.modelId]?.[videoPricingTier(input.resolution)];
  if (perSecond === undefined || !Number.isFinite(input.durationSeconds) || input.durationSeconds <= 0) {
    return undefined;
  }
  return perSecond * input.durationSeconds;
}

/**
 * Records one video response, rounding this clip independently like an image.
 *
 * Takes the Gateway's own charge when it sends one and the list price otherwise; a clip whose price
 * is known neither way is refused rather than handed out for nothing. Returns which one was used so
 * the caller can trace an estimate — it is the signal that the fallback is still load-bearing.
 */
export async function recordVideoApiCost(
  result: { providerMetadata?: unknown },
  pricing: VideoPricingInput,
): Promise<"gateway" | "estimate" | "unrecorded"> {
  const recorder = recorderStorage.getStore();
  if (!recorder) return "unrecorded";

  const reported = gatewayCostUsd(result.providerMetadata);
  const cost = reported ?? estimatedVideoCostUsd(pricing);
  if (cost === undefined) {
    throw new Error(
      `AI Gateway did not return API pricing for a video response and ${pricing.modelId} at `
        + `${pricing.resolution} has no list price`,
    );
  }
  await recorder({
    kind: "video",
    costNanodollars: apiCostNanodollars(cost),
    points: apiCostPoints(cost),
  });
  return reported === undefined ? "estimate" : "gateway";
}

/** Text is rounded up once per chat turn; image and video points have already been rounded per item. */
export function totalApiCostPoints(input: {
  textCostNanodollars: number;
  imagePoints: number;
  videoPoints?: number;
}): number {
  const textPoints = Math.ceil(
    input.textCostNanodollars * POINTS_PER_USD / NANODOLLARS_PER_USD,
  );
  return textPoints + input.imagePoints + (input.videoPoints ?? 0);
}
