import type { PublicHttpAction } from "convex/server";
import { components } from "./_generated/api";
import {
  taxiXpressApp, taxiXpressArchiveSource, taxiXpressControlPath, taxiXpressControlRoute,
} from "../apps/taxi-xpress/host";

/** A chunk found in an app's archive, ready to download and verify. */
export type ArchivedChunk = {
  startedAtMs: number; endedAtMs: number; checksumSha256: string;
  download(): Promise<ArrayBuffer>;
};

/** Where an app keeps its archives, for stream backfill. Null when not configured. */
export type ArchiveSource = {
  find(owner: string, from: number, to: number): Promise<ArchivedChunk[] | null>;
};

/**
 * Applications mounted on DriVio's deployment. Each one is a Convex component in
 * its own repository (included under apps/<name>) and gets:
 * - its token issuer in convex/auth.config.ts,
 * - public live functions re-exported from convex/<appName>.ts,
 * - HTTP routes it needs (such as its control route),
 * - optionally an archive source, when its archives live outside this deployment.
 * DriVio's own clients ("drivio") archive on this deployment.
 */
export type DrivioApp = {
  name: string;
  routes: { path: string; handler: PublicHttpAction }[];
  archiveSource?: () => ArchiveSource;
};

export const apps: DrivioApp[] = [
  {
    name: taxiXpressApp,
    routes: [{ path: taxiXpressControlPath, handler: taxiXpressControlRoute(components.taxiXpress) }],
    archiveSource: () => {
      const source = taxiXpressArchiveSource();
      return {
        async find(owner, from, to) {
          const chunks = await source.find(owner, from, to, ["continuous"]);
          return chunks?.map(chunk => ({
            startedAtMs: chunk.startedAtMs, endedAtMs: chunk.endedAtMs,
            checksumSha256: chunk.checksumSha256, download: () => source.download(chunk),
          })) ?? null;
        },
      };
    },
  },
];

export function archiveSourceFor(app: string) {
  return apps.find(candidate => candidate.name === app)?.archiveSource?.() ?? null;
}
