import { getDatabase } from "@/lib/db/client";
import { requeueFailedCleanupJobs } from "@/lib/services/stickers";
import { startCleanupWorkflow } from "@/lib/services/workflows";

const db = getDatabase();
const claimed = await requeueFailedCleanupJobs(db, { limit: 20 });
for (const { jobId } of claimed) {
  try {
    await startCleanupWorkflow(db, jobId);
  } catch (error) {
    console.error("Failed to redispatch cleanup", { jobId, error });
  }
}
console.log(`Redispatched ${claimed.length} failed cleanup workflow(s)`);
