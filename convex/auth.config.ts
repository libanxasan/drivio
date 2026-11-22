import type { AuthConfig } from "convex/server";
import { taxiXpressAuthProviders } from "../apps/taxi-xpress/host/auth";

// Convex Auth for DriVio's own clients, plus one issuer per application.
export default {
  providers: [
    { domain: process.env.CONVEX_SITE_URL!, applicationID: "convex" },
    ...taxiXpressAuthProviders(),
  ],
} satisfies AuthConfig;
