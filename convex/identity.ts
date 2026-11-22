import type { UserIdentity } from "convex/server";
import { taxiXpressCaller } from "../apps/taxi-xpress/host/auth";

/** The app name of DriVio's own clients, which sign in with Convex Auth. */
export const drivioApp = "drivio";

export type Principal = { app: string; owner: string; subject: string };

const convexAuthIssuer = () => process.env.CONVEX_SITE_URL?.replace(/\/$/, "");

/**
 * Who owns the caller's telemetry. Convex Auth subjects are
 * "<userId>|<sessionId>", so DriVio's own clients are owned by the user, not the
 * session. Application tokens (Taxi Xpress) are owned by their token identifier,
 * which holds only an opaque user id.
 */
export function principal(identity: UserIdentity | null): Principal | null {
  if (!identity) return null;
  if (identity.issuer.replace(/\/$/, "") === convexAuthIssuer()) {
    const userId = identity.subject.split("|")[0];
    return { app: drivioApp, owner: `${identity.issuer}|${userId}`, subject: userId };
  }
  const taxi = taxiXpressCaller(identity);
  if (taxi) return { app: "taxi-xpress", owner: taxi.owner, subject: taxi.subject };
  return null;
}
