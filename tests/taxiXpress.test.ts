/// <reference types="vite/client" />
import { convexTest } from "convex-test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import geospatialTest from "@convex-dev/geospatial/test";
import schema from "../convex/schema";
import { api } from "../convex/_generated/api";
import taxiSchema from "../apps/taxi-xpress/convex/schema";

const modules = import.meta.glob("../convex/**/*.ts");
const taxiModules = import.meta.glob("../apps/taxi-xpress/convex/**/*.ts");

const issuer = "https://br-test-taxixpress.compute.neon.test/api/auth";
const controlKey = "c".repeat(40);

function setup() {
  const t = convexTest(schema, modules);
  t.registerComponent("taxiXpress", taxiSchema, taxiModules);
  geospatialTest.register(t, "taxiXpress/liveDrivers");
  return t;
}
type T = ReturnType<typeof setup>;

/** A driver as Convex sees a Neon token: opaque subject plus app and role claims. */
function driver(t: T, subject = "user-a", role = "driver", claims: Record<string, unknown> = {}) {
  return t.withIdentity({ issuer, subject, tokenIdentifier: `${issuer}|${subject}`, app: "taxi-xpress", role, ...claims });
}
const fix = () => ({
  latitude: 11.57, longitude: 43.14, capturedAt: Date.now(), accuracyMeters: 8,
  speedMps: 2, headingDegrees: 90, isMocked: false,
});
const endSessions = (t: T, body: unknown, key = controlKey) => t.fetch("/apps/taxi-xpress/control/end-sessions", {
  method: "POST", headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
  body: JSON.stringify(body),
});

beforeEach(() => {
  vi.stubEnv("TAXI_XPRESS_AUTH_ISSUER", issuer);
  vi.stubEnv("TAXI_XPRESS_AUTH_JWKS", `${issuer}/jwks`);
  vi.stubEnv("TAXI_XPRESS_CONTROL_KEY", controlKey);
});
afterEach(() => vi.unstubAllEnvs());

describe("Taxi Xpress live data on the shared deployment", () => {
  it("accepts only Taxi Xpress tokens", async () => {
    const t = setup();
    await expect(t.query(api.taxiXpress.mine, {})).rejects.toThrow("Sign in");
    await expect(driver(t, "user-a", "driver", { app: "other-app" }).query(api.taxiXpress.mine, {}))
      .rejects.toThrow("Sign in");
    await expect(driver(t, "user-a", "driver", { issuer: "https://elsewhere.test" }).query(api.taxiXpress.mine, {}))
      .rejects.toThrow("Sign in");
    expect(await driver(t).query(api.taxiXpress.mine, {})).toBeNull();
  });

  it("runs the live flow with approval taken from the token", async () => {
    const t = setup();
    await expect(driver(t, "user-a", "pending").mutation(api.taxiXpress.begin, { requestId: "request-0000000001" }))
      .rejects.toThrow("approval");
    const sessionId = await driver(t).mutation(api.taxiXpress.begin, { requestId: "request-0000000001" });
    expect(await driver(t).mutation(api.taxiXpress.publish, { sessionId, sequence: 0, position: fix(), fixAgeMs: 500 }))
      .toMatchObject({ accepted: true });
    expect(await driver(t).mutation(api.taxiXpress.heartbeat, { sessionId })).toEqual({ active: true });
    expect(await driver(t).query(api.taxiXpress.mine, {})).toMatchObject({ id: sessionId, active: true, fresh: true });
    expect(await t.mutation(api.taxiXpress.publish, { sessionId, sequence: 1, position: fix() }))
      .toMatchObject({ accepted: false, reason: "sign_in_required" });
    // A token issued after revocation says pending: publishing stops even before the control call.
    expect(await driver(t, "user-a", "pending").mutation(api.taxiXpress.publish, { sessionId, sequence: 2, position: fix() }))
      .toMatchObject({ accepted: false, reason: "session_ended" });
    await driver(t).mutation(api.taxiXpress.end, { sessionId });
    expect(await driver(t).query(api.taxiXpress.mine, {})).toMatchObject({ active: false, endedReason: "ended" });
  });

  it("lets Neon end a driver's live sessions with the control key only", async () => {
    const t = setup();
    await driver(t).mutation(api.taxiXpress.begin, { requestId: "request-0000000001" });
    expect((await endSessions(t, { subject: "user-a" }, "x".repeat(40))).status).toBe(401);
    expect((await endSessions(t, { subject: "not/valid" })).status).toBe(400);
    const response = await endSessions(t, { subject: "user-a", reason: "approval_revoked" });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ended: true });
    expect(await driver(t).query(api.taxiXpress.mine, {})).toMatchObject({ active: false, endedReason: "approval_revoked" });
    expect(await (await endSessions(t, { subject: "user-a" })).json()).toEqual({ ended: false });
  });
});
