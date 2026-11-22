/// <reference types="vite/client" />
import { convexTest } from "convex-test";
import { exportJWK, exportPKCS8, generateKeyPair } from "jose";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import geospatialTest from "@convex-dev/geospatial/test";
import batchedReplayTest from "@convex-dev/batched-replay/test";
import schema from "../convex/schema";
import { api, internal } from "../convex/_generated/api";
import taxiSchema from "../apps/taxi-xpress/convex/schema";
import { parseArchivePeriod } from "../convex/archivePeriod";
import { continuousChunk, sha256Hex, type Fix } from "./dtl1";

const modules = import.meta.glob("../convex/**/*.ts");
const taxiModules = import.meta.glob("../apps/taxi-xpress/convex/**/*.ts");
const site = "https://deployment.test.convex.site";
const taxiIssuer = "https://neon.test/api/auth";
const T0 = Date.UTC(2026, 10, 22, 8, 0, 0);
let keys: { privateKey: string; jwks: string };

function setup() {
  const t = convexTest(schema, modules);
  geospatialTest.register(t);
  batchedReplayTest.register(t);
  t.registerComponent("taxiXpress", taxiSchema, taxiModules);
  geospatialTest.register(t, "taxiXpress/liveDrivers");
  return t;
}
type T = ReturnType<typeof setup>;

async function drivioUser(t: T, session = "s1") {
  const userId = await t.run(ctx => ctx.db.insert("users", { isAnonymous: true }));
  const subject = `${userId}|${session}`;
  return { userId, as: t.withIdentity({ issuer: site, subject, tokenIdentifier: `${site}|${subject}` }) };
}
const fix = (t: number, i = 0): Fix => ({ t, latitude: 11.57 + i * 1e-4, longitude: 43.14 + i * 1e-4, speedMps: 12 });
const livePoint = (t: number, i = 0) => ({ ...fix(t, i), headingDegrees: 90, accuracyMeters: 5, isMocked: false });
const everySecond = (from: number, to: number) =>
  Array.from({ length: Math.floor((to - from) / 1000) + 1 }, (_, i) => from + i * 1000);

async function chunkRequest(userId: string, startedAt: number, endedAt: number, opts: { frames?: boolean; events?: boolean } = {}) {
  const times = everySecond(startedAt, endedAt);
  const body = continuousChunk({
    tripId: "trip-1", chunkId: `continuous-${startedAt}`, chunkIndex: 0, startedAt, endedAt,
    fixes: times.map((time, i) => fix(time, i)),
    frames: opts.frames ? times.map(time => ({ t: time, vertical: 0.5 })) : [],
    events: opts.events ? [{ id: "event-1", t: startedAt + 30_000, type: 1 }] : [],
  });
  return {
    method: "POST", body: body as unknown as BodyInit,
    headers: {
      "content-type": "application/octet-stream", "content-encoding": "gzip",
      "x-user-id": userId, "x-trip-id": "trip-1", "x-chunk-id": `continuous-${startedAt}`,
      "x-chunk-index": "0", "x-chunk-type": "continuous", "x-schema-version": "1",
      "x-payload-format": "compact-binary", "x-checksum-sha256": await sha256Hex(body),
      "x-started-at-ms": String(startedAt), "x-ended-at-ms": String(endedAt),
    },
  };
}

beforeAll(async () => {
  const pair = await generateKeyPair("RS256", { extractable: true });
  keys = {
    privateKey: (await exportPKCS8(pair.privateKey)).trimEnd().replace(/\n/g, " "),
    jwks: JSON.stringify({ keys: [{ use: "sig", ...(await exportJWK(pair.publicKey)) }] }),
  };
});
beforeEach(() => {
  vi.stubEnv("CONVEX_SITE_URL", site);
  vi.stubEnv("SITE_URL", site);
  vi.stubEnv("JWT_PRIVATE_KEY", keys.privateKey);
  vi.stubEnv("JWKS", keys.jwks);
  vi.stubEnv("TAXI_XPRESS_AUTH_ISSUER", taxiIssuer);
  vi.stubEnv("TAXI_XPRESS_AUTH_JWKS", `${taxiIssuer}/jwks`);
  vi.stubEnv("TAXI_XPRESS_CONTROL_KEY", "c".repeat(40));
});
afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

describe("DriVio's own clients", () => {
  it("sign in anonymously", async () => {
    const t = setup();
    const result = await t.action(api.auth.signIn, { provider: "anonymous" });
    expect(result.tokens?.token).toBeTruthy();
    expect(result.tokens?.refreshToken).toBeTruthy();
  });

  it("stream live data, detect a gap and backfill it from DriVio's own archive", async () => {
    vi.useFakeTimers();
    const t = setup();
    const { userId, as } = await drivioUser(t);
    const kinds = ["points", "frames", "events"] as const;
    await as.mutation(api.streams.publish, {
      streamId: "trip-1", kinds: [...kinds], points: everySecond(T0, T0 + 10_000).map(livePoint),
    });
    // Offline for 20 minutes, still recording.
    const back = T0 + 20 * 60_000;
    await as.mutation(api.streams.publish, {
      streamId: "trip-1", kinds: [...kinds], points: everySecond(back, back + 5_000).map(livePoint),
    });
    let view = await as.query(api.streams.recent, { streamId: "trip-1", kind: "points", limit: 500 });
    expect(view.gaps).toEqual([{ from: T0 + 10_000, to: back, status: "open", restored: 0 }]);
    expect(view.items).toHaveLength(17);

    // The archive arrives: one continuous chunk across the whole drive.
    const upload = await as.fetch("/v1/telemetry/chunks", await chunkRequest(userId, T0, back + 5_000, { frames: true, events: true }));
    expect(upload.status).toBe(201);
    await t.finishAllScheduledFunctions(vi.runAllTimers);

    const points = await t.run(ctx => ctx.db.query("streamPoints").collect());
    const archived = points.filter(item => item.source === "archive");
    expect(archived.length).toBe(Math.floor((back - (T0 + 10_000)) / 1000) - 1);
    expect(archived.every(item => item.t > T0 + 10_000 && item.t < back)).toBe(true);
    expect(points.filter(item => item.source === "live")).toHaveLength(17);
    view = await as.query(api.streams.recent, { streamId: "trip-1", kind: "points" });
    expect(view.gaps[0]).toMatchObject({ status: "filled", restored: expect.any(Number) });
    const frames = await t.run(ctx => ctx.db.query("streamFrames").collect());
    expect(frames.length).toBe(archived.length);
    const events = await as.query(api.streams.recent, { streamId: "trip-1", kind: "events" });
    expect(events.items).toMatchObject([{ eventId: "event-1", source: "archive" }]);
  });

  it("restore only the kinds the app streams", async () => {
    vi.useFakeTimers();
    const t = setup();
    const { userId, as } = await drivioUser(t);
    await as.mutation(api.streams.publish, { streamId: "trip-1", kinds: ["points"], points: [livePoint(T0)] });
    await as.mutation(api.streams.publish, { streamId: "trip-1", kinds: ["points"], points: [livePoint(T0 + 300_000)] });
    await as.fetch("/v1/telemetry/chunks", await chunkRequest(userId, T0, T0 + 300_000, { frames: true }));
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect((await as.query(api.streams.recent, { streamId: "trip-1", kind: "points", limit: 500 })).items.length).toBeGreaterThan(290);
    expect((await as.query(api.streams.recent, { streamId: "trip-1", kind: "frames" })).items).toEqual([]);
  });

  it("open a gap when a stream goes silent and close it when it resumes", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(T0);
    const t = setup();
    const { as } = await drivioUser(t);
    await as.mutation(api.streams.publish, { streamId: "s", kinds: ["points"], points: [livePoint(T0)] });
    vi.setSystemTime(T0 + 30_000);
    await t.mutation(internal.streams.detectSilence, {});
    expect((await as.query(api.streams.recent, { streamId: "s", kind: "points" })).gaps).toEqual([]);
    vi.setSystemTime(T0 + 3 * 60_000);
    await t.mutation(internal.streams.detectSilence, {});
    await t.mutation(internal.streams.detectSilence, {});
    expect((await as.query(api.streams.recent, { streamId: "s", kind: "points" })).gaps)
      .toEqual([{ from: T0, to: null, status: "open", restored: 0 }]);
    await as.mutation(api.streams.publish, { streamId: "s", kinds: ["points"], points: [livePoint(T0 + 3 * 60_000)] });
    expect((await as.query(api.streams.recent, { streamId: "s", kind: "points" })).gaps)
      .toEqual([{ from: T0, to: T0 + 3 * 60_000, status: "open", restored: 0 }]);
  });

  it("keep application users out of DriVio's own stream and archive", async () => {
    const t = setup();
    const taxi = t.withIdentity({ issuer: taxiIssuer, subject: "user-a", tokenIdentifier: `${taxiIssuer}|user-a`, app: "taxi-xpress", role: "driver" });
    await expect(taxi.mutation(api.streams.publish, { streamId: "s", kinds: ["points"], points: [] })).rejects.toThrow("Sign in");
    expect((await taxi.fetch("/v1/telemetry/chunks", await chunkRequest("user-a", T0, T0 + 1000))).status).toBe(403);
  });
});

describe("Taxi Xpress stream", () => {
  it("records accepted positions and backfills a gap from the Neon archive", async () => {
    vi.stubEnv("TAXI_XPRESS_ARCHIVE_URL", "https://neon.test");
    vi.stubEnv("TAXI_XPRESS_ARCHIVE_KEY", "k".repeat(40));
    const t = setup();
    const driver = t.withIdentity({ issuer: taxiIssuer, subject: "user-a", tokenIdentifier: `${taxiIssuer}|user-a`, app: "taxi-xpress", role: "driver" });
    const sessionId = await driver.mutation(api.taxiXpress.begin, { requestId: "request-0000000001" });
    const now = Date.now();
    const position = (t: number) => ({ latitude: 11.57, longitude: 43.14, capturedAt: t, accuracyMeters: 8, speedMps: 10, headingDegrees: 90, isMocked: false });
    expect(await driver.mutation(api.taxiXpress.publish, { sessionId, sequence: 0, position: position(now - 20 * 60_000), fixAgeMs: 0 }))
      .toMatchObject({ accepted: true });
    expect(await driver.mutation(api.taxiXpress.publish, { sessionId, sequence: 1, position: position(now), fixAgeMs: 0 }))
      .toMatchObject({ accepted: true });

    const body = continuousChunk({
      tripId: "trip-9", chunkId: "continuous-0", chunkIndex: 0, startedAt: now - 20 * 60_000, endedAt: now,
      fixes: everySecond(now - 20 * 60_000, now).map((time, i) => fix(time, i)),
    });
    const calls: string[] = [];
    vi.stubGlobal("fetch", vi.fn(async (input: string, init?: RequestInit) => {
      calls.push(String(input));
      if (String(input).startsWith("https://neon.test/v1/archive/chunks")) {
        expect(new Headers(init?.headers).get("authorization")).toBe(`Bearer ${"k".repeat(40)}`);
        expect(new URL(String(input)).searchParams.get("owner")).toBe("user-a");
        return Response.json({ chunks: [{
          tripId: "trip-9", chunkId: "continuous-0", chunkIndex: 0, type: "continuous",
          startedAtMs: now - 20 * 60_000, endedAtMs: now, checksumSha256: await sha256Hex(body),
          sizeBytes: body.byteLength, url: "https://storage.test/signed",
        }] });
      }
      if (String(input) === "https://storage.test/signed") return new Response(body);
      throw new Error(`Unexpected fetch ${input}`);
    }));
    // The gap is due a minute after it was seen; make it due now.
    await t.run(async ctx => {
      for (const gap of await ctx.db.query("streamGaps").collect()) await ctx.db.patch(gap._id, { nextAttemptAt: 0 });
    });
    await t.action(internal.backfill.run, {});
    expect(calls).toHaveLength(2);
    const rows = await t.run(ctx => ctx.db.query("streamPoints").collect());
    expect(rows.filter(r => r.source === "live")).toHaveLength(2);
    expect(rows.filter(r => r.source === "archive").length).toBe(20 * 60 - 1);
    expect(rows.every(r => r.owner === `${taxiIssuer}|user-a`)).toBe(true);
    const [gap] = await t.run(ctx => ctx.db.query("streamGaps").collect());
    expect(gap).toMatchObject({ status: "filled", app: "taxi-xpress" });
  });
});

describe("ARCHIVE_PERIOD", () => {
  it("parses periods and ignores invalid values", () => {
    expect(parseArchivePeriod(undefined)).toBeNull();
    expect(parseArchivePeriod("")).toBeNull();
    expect(parseArchivePeriod("30d")).toBe(30 * 86_400_000);
    expect(parseArchivePeriod("12h")).toBe(12 * 3_600_000);
    expect(parseArchivePeriod("90000")).toBe(90_000);
    expect(parseArchivePeriod("one year")).toBeNull();
    expect(parseArchivePeriod("-5d")).toBeNull();
  });

  it("deletes nothing when unset and only older telemetry when set", async () => {
    const t = setup();
    const { as } = await drivioUser(t);
    const old = Date.now() - 40 * 86_400_000;
    await as.mutation(api.streams.publish, { streamId: "old", kinds: ["points"], points: [livePoint(old)] });
    await as.mutation(api.streams.publish, { streamId: "new", kinds: ["points"], points: [livePoint(Date.now())] });
    expect(await t.mutation(internal.retention.purge, {})).toEqual({ deleted: 0, cutoff: null });
    vi.stubEnv("ARCHIVE_PERIOD", "not a period");
    expect(await t.mutation(internal.retention.purge, {})).toEqual({ deleted: 0, cutoff: null });
    vi.stubEnv("ARCHIVE_PERIOD", "30d");
    const result = await t.mutation(internal.retention.purge, {});
    expect(result.deleted).toBe(1);
    const left = await t.run(ctx => ctx.db.query("streamPoints").collect());
    expect(left.map(p => p.t)).toHaveLength(1);
    expect(left[0].t).toBeGreaterThan(old);
  });
});
