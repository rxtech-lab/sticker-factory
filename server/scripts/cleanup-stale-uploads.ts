import { getDatabase } from "@/lib/db/client";
import { purgeStaleUnboundUploads } from "@/lib/services/assets";

const count = await purgeStaleUnboundUploads(await getDatabase());
console.log(`Purged ${count} stale unbound upload${count === 1 ? "" : "s"}`);
