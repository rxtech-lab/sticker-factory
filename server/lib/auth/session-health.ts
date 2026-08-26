import type { Session } from "next-auth";

// Public value exported by @rxtech-lab/authjs-rxlab. Kept in this pure module so
// health checks can be tested without loading the Next.js Auth.js runtime.
export const RX_LAB_REFRESH_TOKEN_ERROR_VALUE = "RefreshTokenError";

export function isHealthyWebSession(session: Session | null): session is Session & { user: NonNullable<Session["user"]> & { id: string } } {
  return Boolean(session?.user?.id && session.error !== RX_LAB_REFRESH_TOKEN_ERROR_VALUE);
}
