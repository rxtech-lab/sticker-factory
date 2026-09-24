import { eq } from "drizzle-orm";
import { firstRow, getDatabase } from "@/lib/db/client";
import { assets, generationJobs } from "@/lib/db/schema";
import { padGeneratedAtlas, SpriteSheetValidationError, validateGeneratedAtlas } from "@/lib/render/sprite-atlas";
import { getObjectStore, objectKey } from "@/lib/storage/r2";
import { assertJobStillRunning, reportTurnNote } from "./turn-context";

/**
 * Buying a sprite sheet until one registers.
 *
 * Every kind of sheet — a sprite's clip, its expressions, a configurable pose — is drawn the same
 * way: ask for an image, check the drawings land one per cell, repair what can be repaired for
 * free, and redraw with the specific complaint attached when it cannot. The parts that differ are
 * the prompt and what registering the sheet means, so those are the arguments.
 */

type Job = typeof generationJobs.$inferSelect;
type Grid = { columns: number; rows: number; frameCount: number };

/** What a rejected sheet was rejected for, so the redraws it earns can be told what to fix. */
export class SheetRejected extends Error {
  constructor(readonly problems: string[]) {
    super(`Generated sheet was rejected: ${problems.join("; ")}`);
    this.name = "SheetRejected";
  }
}

/**
 * How many corrective redraws one sheet may spend.
 *
 * Two rather than one because the corrections escalate: the first asks for wider margins, the
 * second for a visibly smaller character. A model that ignored the margin rule once usually obeys
 * a blunter instruction, and the alternative — failing the turn — costs the user everything the
 * turn had already drawn.
 */
export const MAX_SHEET_REDRAWS = 2;

/** Only failures in generated artwork justify another paid image, never infrastructure errors. */
export function redrawFeedback(error: unknown, attempt = 0): string[] | undefined {
  if (error instanceof SheetRejected) return error.problems;
  if (!(error instanceof SpriteSheetValidationError)) return undefined;
  const correction = error.reason === "clipped"
    ? attempt > 0
      ? "The last attempt still crossed the cell boundaries. Draw the character noticeably smaller than it appears in the references: leave at least 25% of every cell's width and height transparent on each side, so every complete pose, accessory and effect sits inside the central 50% of its cell. One uniform scale for all frames; never crop a drawing or shrink just one frame."
      : "Redraw the entire sheet at one smaller uniform scale. Leave at least 20% of every cell's width and height transparent on each side, including the outer edges of the sheet. Fit every complete pose and effect within the central 60%; never crop a drawing or shrink just one frame."
    : error.reason === "empty"
      ? "Draw every requested frame in its specified row-major cell; no used cell may be empty. Keep unused cells transparent."
      : "Give every frame exactly one flat solid magenta face placeholder in the specified face region, with no scattered magenta or oversized marker.";
  return [error.message, correction];
}

/**
 * Repair intact drawings before spending on a redraw, and register only the repaired pixels.
 *
 * `normalize` runs on a sheet that already validates — `anchorSpriteFrames` for a sticker that
 * stays put — and before `register`, so the inspector and the face registration both measure the
 * pixels that get stored. A sheet it changes counts as repaired, so the caller stores those pixels
 * as the raw sheet too and a later face repair starts from the same frames.
 */
export async function prepareSheet<T>(
  original: Uint8Array, grid: Grid,
  register: (bytes: Uint8Array, grid: Grid) => Promise<T>,
  normalize?: (bytes: Uint8Array, grid: Grid) => Promise<Uint8Array>,
): Promise<{ bytes: Uint8Array; repaired: boolean; registered: T }> {
  const validate = async (valid: Uint8Array) => {
    await validateGeneratedAtlas(valid, grid);
    const bytes = normalize ? await normalize(valid, grid) : valid;
    if (bytes !== valid) await validateGeneratedAtlas(bytes, grid);
    return { bytes, normalized: bytes !== valid, registered: await register(bytes, grid) };
  };
  try {
    const { bytes, normalized, registered } = await validate(original);
    return { bytes, repaired: normalized, registered };
  } catch (error) {
    if (!(error instanceof SpriteSheetValidationError) || error.reason !== "clipped") throw error;
    // Re-cutting the grid preserves complete artwork. Padding already-cut cells would hide
    // missing pixels.
    let padded: Uint8Array;
    try { padded = await padGeneratedAtlas(original, grid); }
    catch { throw error; }
    const { bytes, registered } = await validate(padded);
    return { bytes, repaired: true, registered };
  }
}

/** Failed sheets are not reused unless they can be repaired and fully registered. */
export async function discardSheet(assetId: string): Promise<void> {
  const db = await getDatabase();
  await db.update(assets).set({ state: "failed" }).where(eq(assets.id, assetId));
}

/**
 * Draws one sheet, and keeps drawing it until it can be prepared or the redraw budget runs out.
 *
 * `prepare` is the caller's whole acceptance pipeline — validation, repair, registration, and for a
 * sprite the vision inspector too — so layout and inspection failures share one budget, and both
 * get to state their complaint in the next prompt.
 */
export async function drawSheet<T>(params: {
  job: Job;
  stickerId: string;
  assetId: string;
  generate: (feedback: string[] | undefined) => Promise<unknown>;
  prepare: (bytes: Uint8Array) => Promise<T>;
  note: (error: unknown) => string;
}): Promise<{ prepared: T; recoveredSavedSheet: boolean }> {
  const { job, stickerId, assetId, generate, prepare, note } = params;
  const db = await getDatabase();
  let prepared: T | undefined;
  let feedback: string[] | undefined;
  // An earlier attempt may have rejected an intact sheet solely for drifting across the grid, or
  // reviewed it without the context this one has. Try the saved pixels before buying another image.
  const existing = await db.select().from(assets).where(eq(assets.id, assetId)).then(firstRow);
  if (existing?.state === "failed" && existing.ownerId === job.ownerId && existing.stickerId === stickerId) {
    const saved = await getObjectStore().get(existing.r2Key);
    try { prepared = await prepare(saved.bytes); }
    catch (error) {
      feedback = redrawFeedback(error);
      if (!feedback) throw error;
    }
  }
  const recoveredSavedSheet = prepared !== undefined;
  for (let attempt = 0; prepared === undefined; attempt += 1) {
    await assertJobStillRunning(job.id);
    await generate(feedback);
    try {
      const drawn = await getObjectStore().get(objectKey(job.ownerId, assetId, "image/png"));
      prepared = await prepare(drawn.bytes);
    } catch (error) {
      await discardSheet(assetId);
      const problems = redrawFeedback(error, attempt);
      if (problems && attempt < MAX_SHEET_REDRAWS) {
        feedback = problems;
        await reportTurnNote(job, note(error));
        continue;
      }
      throw error;
    }
  }
  return { prepared, recoveredSavedSheet };
}
