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
  | { kind: "image"; costNanodollars: number; points: number };

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

/** Text is rounded up once per chat turn; image points have already been rounded per image. */
export function totalApiCostPoints(input: {
  textCostNanodollars: number;
  imagePoints: number;
}): number {
  const textPoints = Math.ceil(
    input.textCostNanodollars * POINTS_PER_USD / NANODOLLARS_PER_USD,
  );
  return textPoints + input.imagePoints;
}
