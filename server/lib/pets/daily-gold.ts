import type { PetStoredContext, UserWalletRow } from "@/lib/db/schema";
import { localDate } from "./signals";

/** The gold every owner is given once a day, on their own local date, whichever pet they have. */
export const DAILY_GOLD = 10;

export type DailyGold = { gold: number; date: string };

/** Today's allowance if it has not been granted yet, read on the owner's local date. */
export function dailyGold(
  context: Pick<PetStoredContext, "timeZone"> | null,
  wallet: Pick<UserWalletRow, "dailyGoldDate"> | null,
  now: Date,
): DailyGold | null {
  const date = localDate(now, context?.timeZone);
  return wallet?.dailyGoldDate === date ? null : { gold: DAILY_GOLD, date };
}
