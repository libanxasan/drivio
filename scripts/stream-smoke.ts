// End-to-end check of the live stream and its backfill on a Convex deployment:
// anonymous sign-in, a live stream with a 20 minute hole, an archive chunk that
// covers the hole, then the restored stream. Writes test data to the deployment.
// Run from the repository root: npx tsx scripts/stream-smoke.ts
import { existsSync, readFileSync } from "node:fs";
import { parseEnv } from "node:util";
import { continuousChunk, sha256Hex } from "../tests/dtl1";

const local = existsSync(".env.local") ? parseEnv(readFileSync(".env.local", "utf8")) : {};
const url = (process.env.CONVEX_URL ?? local.CONVEX_URL ?? "").replace(/\/$/, "");
const site = (process.env.CONVEX_SITE_URL ?? local.CONVEX_SITE_URL ?? url.replace(".convex.cloud", ".convex.site"))
  .replace(/\/$/, "");
if (!url) throw new Error("Set CONVEX_URL");

let token = "";
async function call(kind: "query" | "mutation" | "action", path: string, args: unknown) {
  const response = await fetch(`${url}/api/${kind}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify({ path, args, format: "json" }),
  });
  const body = await response.json() as { status: string; value?: unknown; errorMessage?: string };
  if (body.status !== "success") throw new Error(`${path}: ${body.errorMessage}`);
  return body.value as any;
}

const signIn = await call("action", "auth:signIn", { provider: "anonymous" });
token = signIn.tokens.token;
const subject = JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString()).sub.split("|")[0];
console.log("signed in anonymously");

const now = Date.now();
const start = now - 26 * 60_000, holeFrom = now - 24 * 60_000, holeTo = now - 4 * 60_000, end = now - 3 * 60_000;
const at = (t: number) => {
  const i = (t - start) / 1000;
  return { t, latitude: 11.5721 + i * 0.00005, longitude: 43.1456 + i * 0.00003, speedMps: 12 };
};
const seconds = (from: number, to: number) => Array.from({ length: Math.floor((to - from) / 1000) + 1 }, (_, i) => from + i * 1000);
const point = (t: number) => ({ ...at(t), headingDegrees: 40, accuracyMeters: 5, isMocked: false });
const streamId = `smoke-${now}`;
const kinds = ["points"];

for (const [from, to] of [[start, holeFrom], [holeTo, end]] as const) {
  const times = seconds(from, to);
  for (let i = 0; i < times.length; i += 100) {
    await call("mutation", "streams:publish", { streamId, kinds, points: times.slice(i, i + 100).map(point) });
  }
}
let state = await call("query", "streams:recent", { streamId, kind: "points", limit: 500 });
console.log("live points:", state.items.length, "gaps:", JSON.stringify(state.gaps.map((g: any) => ({ minutes: ((g.to - g.from) / 60_000).toFixed(1), status: g.status }))));

const body = continuousChunk({
  tripId: streamId, chunkId: `continuous-${start}`, chunkIndex: 0, startedAt: start, endedAt: end,
  fixes: seconds(start, end).map(at),
});
const upload = await fetch(`${site}/v1/telemetry/chunks`, {
  method: "POST", body,
  headers: {
    authorization: `Bearer ${token}`, "content-type": "application/octet-stream", "content-encoding": "gzip",
    "x-user-id": subject, "x-trip-id": streamId, "x-chunk-id": `continuous-${start}`, "x-chunk-index": "0",
    "x-chunk-type": "continuous", "x-schema-version": "1", "x-payload-format": "compact-binary",
    "x-checksum-sha256": await sha256Hex(body), "x-started-at-ms": String(start), "x-ended-at-ms": String(end),
    "idempotency-key": `${streamId}:continuous-${start}`,
  },
});
console.log("archive upload:", upload.status, (await upload.text()).slice(0, 120));

for (let attempt = 0; attempt < 24; attempt++) {
  await new Promise(r => setTimeout(r, 5000));
  state = await call("query", "streams:recent", { streamId, kind: "points", limit: 500 });
  const gap = state.gaps[0];
  if (gap && gap.status !== "open") break;
}
let total = 0, after = 0;
for (;;) {
  const page = await call("query", "streams:recent", { streamId, kind: "points", after, limit: 500 });
  total += page.items.length;
  if (page.items.length < 500) break;
  after = page.items[page.items.length - 1].t;
}
console.log("after backfill: points", total, "of", seconds(start, end).length,
  "gaps:", JSON.stringify(state.gaps.map((g: any) => ({ status: g.status, restored: g.restored }))));
await call("mutation", "streams:close", { streamId });
