import type { AuthConfig } from "convex/server";
import { taxiXpressAuthProviders } from "../apps/taxi-xpress/host/auth";

// One token issuer per application. Tokens carry an opaque subject and the claims
// the application's live functions need; sign-in itself happens on Neon.
export default {
  providers: [...taxiXpressAuthProviders()],
} satisfies AuthConfig;
