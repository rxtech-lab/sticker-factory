import { CONFIGURATION_LIMITS } from "@/lib/contracts/configuration";
import { MAX_PLAN_LAYERS } from "@/lib/contracts/plan";

/**
 * The budget the plan editor spends, as the only place the app learns it.
 *
 * The device writes none of these numbers down: it greys out "Add control", stops a table growing
 * past its ceiling, and warns about an over-budget cast from what this says — and enforces nothing
 * at all until it has heard, because a plan is refused where it is decided. Public and
 * unauthenticated, since the numbers are the same for everyone and the editor wants them before
 * the first plan exists. `must-revalidate` so a raised cap reaches an open app on its next launch.
 */
export function GET() {
  return Response.json(
    { ...CONFIGURATION_LIMITS, planLayers: MAX_PLAN_LAYERS },
    { headers: { "cache-control": "public, max-age=0, must-revalidate" } },
  );
}
