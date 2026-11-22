import { convexAuth } from "@convex-dev/auth/server";
import { Anonymous } from "@convex-dev/auth/providers/Anonymous";

/**
 * Sign-in for DriVio's own clients (the example app): anonymous accounts, no
 * personal data. Applications such as Taxi Xpress bring their own token issuer
 * (see auth.config.ts) and do not use this.
 */
export const { auth, signIn, signOut, store, isAuthenticated } = convexAuth({
  providers: [Anonymous],
  jwt: { durationMs: 60 * 60 * 1000 },
});
