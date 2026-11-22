import type { GenericActionCtx, GenericDataModel } from "convex/server";
import { components } from "./_generated/api";
import {
  taxiXpressApp, taxiXpressArchiveAdmission, taxiXpressArchivePath,
  taxiXpressTelegramPath, taxiXpressTelegramWebhook,
} from "../apps/taxi-xpress/host";

/**
 * Applications mounted on the shared DriVio deployment. Each one is a Convex
 * component in its own repository (included under apps/<name>) and gets:
 * - its sign-in providers in convex/auth.ts, tagging its users with its name,
 * - public functions re-exported from convex/<appName>.ts,
 * - an archive upload route that runs its admission check, then stores the
 *   chunk in the shared DriVio archive,
 * - any extra HTTP routes it needs (webhooks).
 * An application's users are only accepted by that application's functions
 * and routes, and the core upload route refuses them.
 */
export type DrivioApp = {
  name: string;
  archivePath: string;
  admitArchiveUpload: (
    ctx: GenericActionCtx<GenericDataModel>, owner: string,
  ) => Promise<Response | null>;
  routes: { path: string; handler: ReturnType<typeof taxiXpressTelegramWebhook> }[];
};

export const apps: DrivioApp[] = [
  {
    name: taxiXpressApp,
    archivePath: taxiXpressArchivePath,
    admitArchiveUpload: taxiXpressArchiveAdmission(components.taxiXpress),
    routes: [{
      path: taxiXpressTelegramPath,
      handler: taxiXpressTelegramWebhook(components.taxiXpress),
    }],
  },
];
