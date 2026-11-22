/// <reference types="vite/client" />
import { gzip } from "pako";
import { convexTest } from "convex-test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import geospatialTest from "@convex-dev/geospatial/test";
import batchedReplayTest from "@convex-dev/batched-replay/test";
import schema from "../convex/schema";
import { api } from "../convex/_generated/api";
import taxiSchema from "../apps/taxi-xpress/convex/schema";

const modules = import.meta.glob("../convex/**/*.ts");
const taxiModules = import.meta.glob("../apps/taxi-xpress/convex/**/*.ts");

const taxiIssuer = "https://auth.taxi.test/api/auth";
const driverA = { subject: "driver-a", issuer: taxiIssuer, tokenIdentifier: `${taxiIssuer}|driver-a` };
const operatorA = { subject: "operator-a", issuer: taxiIssuer, tokenIdentifier: `${taxiIssuer}|operator-a` };
const coreUser = { subject: "core-1", issuer: "https://auth.drivio.test", tokenIdentifier: "https://auth.drivio.test|core-1" };

function setup() {
  const t = convexTest(schema, modules);
  geospatialTest.register(t);
  batchedReplayTest.register(t);
  t.registerComponent("taxiXpress", taxiSchema, taxiModules);
  geospatialTest.register(t, "taxiXpress/liveDrivers");
  return t;
}
const fix = () => ({
  latitude: 11.57, longitude: 43.14, capturedAt: Date.now(), accuracyMeters: 8,
  speedMps: 2, headingDegrees: 90, isMocked: false,
});

async function approvedDriver(t: ReturnType<typeof setup>) {
  const driver = t.withIdentity(driverA);
  const operator = t.withIdentity(operatorA);
  const driverId = await driver.mutation(api.taxiXpress.enroll, { name: "Driver A" });
  await operator.mutation(api.taxiXpress.setApprovalByOperator, { driverId, approved: true });
  return { driver, operator, driverId };
}

async function routeChunk(subject: string) {
  const body = new Uint8Array(gzip(JSON.stringify({ totalDistanceMeters: 35 }))).buffer;
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", body));
  const checksum = Array.from(digest, byte => byte.toString(16).padStart(2, "0")).join("");
  return {
    method: "POST", body,
    headers: {
      "content-type": "application/octet-stream", "content-encoding": "gzip",
      "idempotency-key": "trip-test:route-0", "x-user-id": subject, "x-trip-id": "trip-test",
      "x-chunk-id": "route-0", "x-chunk-index": "0", "x-chunk-type": "route",
      "x-schema-version": "1", "x-payload-format": "json", "x-checksum-sha256": checksum,
      "x-started-at-ms": "1000", "x-ended-at-ms": "2000",
    },
  };
}

beforeEach(() => {
  vi.stubEnv("TAXI_XPRESS_AUTH_ISSUER", taxiIssuer);
  vi.stubEnv("TAXI_XPRESS_OPERATOR_SUBJECTS", "operator-a");
});
afterEach(() => vi.unstubAllEnvs());

describe("Taxi Xpress component on the shared deployment", () => {
  it("accepts only Taxi Xpress identities", async () => {
    const t = setup();
    await expect(t.query(api.taxiXpress.mine, {})).rejects.toThrow("Sign in");
    await expect(t.withIdentity(coreUser).mutation(api.taxiXpress.enroll, { name: "Core" }))
      .rejects.toThrow("Sign in");
    expect(await t.withIdentity(driverA).query(api.taxiXpress.mine, {})).toBeNull();
    vi.stubEnv("TAXI_XPRESS_AUTH_ISSUER", "");
    await expect(t.withIdentity(driverA).query(api.taxiXpress.mine, {})).rejects.toThrow("Sign in");
  });

  it("runs the driver flow through the host functions", async () => {
    const t = setup();
    const { driver } = await approvedDriver(t);
    const sessionId = await driver.mutation(api.taxiXpress.begin, { requestId: "request-0000000001" });
    expect(await driver.mutation(api.taxiXpress.publish, { sessionId, sequence: 0, position: fix(), fixAgeMs: 500 }))
      .toMatchObject({ accepted: true });
    expect(await driver.mutation(api.taxiXpress.heartbeat, { sessionId })).toEqual({ active: true });
    expect(await driver.query(api.taxiXpress.mine, {})).toMatchObject({
      approved: true, session: { id: sessionId, active: true, fresh: true },
    });
    const signedOut = await t.mutation(api.taxiXpress.publish, { sessionId, sequence: 1, position: fix() });
    expect(signedOut).toMatchObject({ accepted: false, reason: "sign_in_required" });
    await driver.mutation(api.taxiXpress.end, { sessionId });
    expect(await driver.query(api.taxiXpress.mine, {})).toMatchObject({ session: { active: false, endedReason: "ended" } });
  });

  it("lets only listed operators approve or revoke drivers", async () => {
    const t = setup();
    const driver = t.withIdentity(driverA);
    const operator = t.withIdentity(operatorA);
    const driverId = await driver.mutation(api.taxiXpress.enroll, { name: "Driver A" });
    expect(await driver.query(api.taxiXpress.canManage, {})).toBe(false);
    await expect(driver.mutation(api.taxiXpress.setApprovalByOperator, { driverId, approved: true }))
      .rejects.toThrow("Operator access");
    expect(await operator.query(api.taxiXpress.canManage, {})).toBe(true);
    const pending = await operator.query(api.taxiXpress.listForApproval, {
      approved: false, paginationOpts: { numItems: 25, cursor: null },
    });
    expect(pending.page).toEqual([{ driverId, name: "Driver A" }]);
    await operator.mutation(api.taxiXpress.setApprovalByOperator, { driverId, approved: true });
    await driver.mutation(api.taxiXpress.begin, { requestId: "request-0000000001" });
    await operator.mutation(api.taxiXpress.setApprovalByOperator, { driverId, approved: false });
    expect(await driver.query(api.taxiXpress.mine, {})).toMatchObject({
      approved: false, session: { active: false, endedReason: "approval_revoked" },
    });
    // An operator listed by subject but signed in elsewhere is not an operator.
    const lookalike = t.withIdentity({ ...coreUser, subject: "operator-a" });
    expect(await lookalike.query(api.taxiXpress.canManage, {})).toBe(false);
  });

  it("keeps each upload route to its own identities", async () => {
    const t = setup();
    const taxiPath = "/apps/taxi-xpress/v1/telemetry/chunks";
    const driver = t.withIdentity(driverA);
    expect((await driver.fetch("/v1/telemetry/chunks", await routeChunk("driver-a"))).status).toBe(403);
    expect((await t.withIdentity(coreUser).fetch(taxiPath, await routeChunk("core-1"))).status).toBe(403);
    expect((await driver.fetch(taxiPath, await routeChunk("driver-a"))).status).toBe(403);
    const core = await t.withIdentity(coreUser).fetch("/v1/telemetry/chunks", await routeChunk("core-1"));
    expect(core.status).toBe(201);
  });

  it("stores an approved driver's archive in the shared DriVio archive", async () => {
    const t = setup();
    const { driver, operator, driverId } = await approvedDriver(t);
    const taxiPath = "/apps/taxi-xpress/v1/telemetry/chunks";
    const created = await driver.fetch(taxiPath, await routeChunk("driver-a"));
    expect(created.status).toBe(201);
    const stored = await created.json();
    const retried = await driver.fetch(taxiPath, await routeChunk("driver-a"));
    expect(retried.status).toBe(200);
    expect(await retried.json()).toEqual({ ...stored, alreadyExisted: true });
    const owners = await t.run(async ctx => (await ctx.db.query("trips").collect()).map(trip => trip.owner));
    expect(owners).toEqual([driverA.tokenIdentifier]);
    await operator.mutation(api.taxiXpress.setApprovalByOperator, { driverId, approved: false });
    expect((await driver.fetch(taxiPath, await routeChunk("driver-a"))).status).toBe(403);
  });
});
