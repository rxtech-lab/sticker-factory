import { count, eq } from "drizzle-orm";
import { firstRow, getDatabase } from "@/lib/db/client";
import { packInstalls, stickerPackItems, stickerPacks } from "@/lib/db/schema";
import { recomputePackCounters } from "@/lib/services/packs";

/**
 * Reconciles `sticker_packs.install_count` and `item_count` against the rows they summarize.
 *
 * SQLite does not fire row triggers for rows removed by a foreign-key `ON DELETE CASCADE` unless
 * `PRAGMA recursive_triggers` is on, so a cascading delete can leave a counter high. Nothing
 * hard-deletes users today; this exists so that stays a repairable bug rather than a permanent one.
 */
const db = await getDatabase();

const before = await db.select({
  id: stickerPacks.id,
  installCount: stickerPacks.installCount,
  itemCount: stickerPacks.itemCount,
}).from(stickerPacks);

await recomputePackCounters(db);

let repaired = 0;
for (const pack of before) {
  const installs = await db.select({ value: count() }).from(packInstalls)
    .where(eq(packInstalls.packId, pack.id)).then(firstRow);
  const items = await db.select({ value: count() }).from(stickerPackItems)
    .where(eq(stickerPackItems.packId, pack.id)).then(firstRow);
  const after = await db.select({
    installCount: stickerPacks.installCount,
    itemCount: stickerPacks.itemCount,
  }).from(stickerPacks).where(eq(stickerPacks.id, pack.id)).then(firstRow);
  if (!after) continue;
  if (after.installCount !== pack.installCount || after.itemCount !== pack.itemCount) {
    repaired += 1;
    console.log(
      `${pack.id}: installs ${pack.installCount} -> ${after.installCount}, `
      + `items ${pack.itemCount} -> ${after.itemCount} `
      + `(rows: ${installs?.value ?? 0} installs, ${items?.value ?? 0} items)`,
    );
  }
}

console.log(`Checked ${before.length} pack${before.length === 1 ? "" : "s"}, repaired ${repaired}`);
