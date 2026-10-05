import { userWalletGrants } from "@/lib/db/schema";
import type { Database } from "@/lib/db/client";
import { goldBalance } from "@/lib/subscription/gold";

/** Sets the owner's gold, as a points pack or an adjustment in RxSubscription would. */
export async function setGoldForTests(db: Database, userId: string, gold: number): Promise<void> {
  const delta = gold - await goldBalance(db, userId, null);
  await db.insert(userWalletGrants).values({ id: `test:${crypto.randomUUID()}`, userId, kind: "pet", gold: delta,
    settledAt: new Date(), createdAt: new Date() });
}
