import type {
  GenericActionCtx, GenericDataModel, UserIdentity,
} from "convex/server";
import { components } from "./_generated/api";
import {
  isTaxiXpressIdentity, taxiXpressArchiveAdmission, taxiXpressArchivePath,
} from "../apps/taxi-xpress/host";

/**
 * Applications mounted on the shared DriVio deployment. Each one is a Convex
 * component in its own repository (included under apps/<name>) and gets:
 * - its own auth provider in auth.config.ts,
 * - public functions re-exported from convex/<appName>.ts,
 * - an archive upload route that runs its admission check, then stores the
 *   chunk in the shared DriVio archive.
 * Identities of an app are only accepted on that app's routes and functions.
 */
export type DrivioApp = {
  name: string;
  archivePath: string;
  owns: (identity: UserIdentity | null) => boolean;
  admitArchiveUpload: (
    ctx: GenericActionCtx<GenericDataModel>, identity: UserIdentity,
  ) => Promise<Response | null>;
};

export const apps: DrivioApp[] = [
  {
    name: "taxi-xpress",
    archivePath: taxiXpressArchivePath,
    owns: isTaxiXpressIdentity,
    admitArchiveUpload: taxiXpressArchiveAdmission(components.taxiXpress),
  },
];

/** True when the identity belongs to one of the mounted applications. */
export function belongsToApp(identity: UserIdentity | null) {
  return apps.some(app => app.owns(identity));
}
