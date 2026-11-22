import type { PublicHttpAction } from "convex/server";
import { components } from "./_generated/api";
import { taxiXpressApp, taxiXpressControlPath, taxiXpressControlRoute } from "../apps/taxi-xpress/host";

/**
 * Applications mounted on the shared DriVio deployment. Each one is a Convex
 * component in its own repository (included under apps/<name>) and gets:
 * - its token issuer in convex/auth.config.ts,
 * - public live functions re-exported from convex/<appName>.ts,
 * - any HTTP routes it needs, such as the control route its Neon side calls.
 */
export type DrivioApp = {
  name: string;
  routes: { path: string; handler: PublicHttpAction }[];
};

export const apps: DrivioApp[] = [
  {
    name: taxiXpressApp,
    routes: [{ path: taxiXpressControlPath, handler: taxiXpressControlRoute(components.taxiXpress) }],
  },
];
