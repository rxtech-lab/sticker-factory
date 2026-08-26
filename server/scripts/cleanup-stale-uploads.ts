import { getDatabase } from "@/lib/db/client";
import { purgeStaleUnboundUploads } from "@/lib/services/assets";

const count = await purgeStaleUnboundUploads(getDatabase());
console.log(`Purged ${count} stale unbound upload${count === 1 ? "" : "s"}`);
