import { and, eq, isNull } from "drizzle-orm";
import { firstRow, type Database } from "@/lib/db/client";
import { users } from "@/lib/db/schema";
import { ControllableEngineSchema, type ControllableEngineID } from "@/lib/contracts/controllable";

/**
 * ANIMATION_ENGINE (`svg` | `legacy`) pins every new project to one engine, overriding the account
 * preference and the client's request. Unset, each account's preference decides. Clients that have
 * not announced SVG support always get Legacy, whatever the flag says.
 */
export function serverAnimationEngine(): ControllableEngineID | undefined {
  const value = process.env.ANIMATION_ENGINE?.trim().toLowerCase();
  if (!value) return undefined;
  const parsed = ControllableEngineSchema.safeParse(value);
  if (!parsed.success) throw new Error(`ANIMATION_ENGINE must be "svg" or "legacy", got "${value}"`);
  return parsed.data;
}

export async function animationSettings(db: Database, userId: string) {
  const user = await db.select({ engine: users.animationEngine }).from(users).where(eq(users.id, userId)).then(firstRow);
  return { engine: serverAnimationEngine() ?? user?.engine ?? "svg" as ControllableEngineID };
}
export async function setAnimationSettings(db: Database, userId: string, engine: ControllableEngineID) {
  await db.update(users).set({ animationEngine: engine }).where(eq(users.id, userId));
  return { engine: serverAnimationEngine() ?? engine };
}

/** Null identifies accounts whose clients have not announced SVG support. */
export async function backgroundAnimationEngine(db: Database, userId: string): Promise<ControllableEngineID> {
  const row = await db.select({ engine: users.animationEngine }).from(users).where(eq(users.id, userId)).then(firstRow);
  return row?.engine ? serverAnimationEngine() ?? row.engine : "legacy";
}
export async function rememberSVGCapability(db: Database, userId: string) {
  await db.update(users).set({ animationEngine: "svg" }).where(and(eq(users.id, userId), isNull(users.animationEngine)));
}
