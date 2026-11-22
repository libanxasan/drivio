/// <reference types="vite/client" />
import { gzip } from "pako";
import { convexTest } from "convex-test";
import { exportJWK, exportPKCS8, generateKeyPair } from "jose";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import geospatialTest from "@convex-dev/geospatial/test";
import batchedReplayTest from "@convex-dev/batched-replay/test";
import schema from "../convex/schema";
import { api } from "../convex/_generated/api";
import taxiSchema from "../apps/taxi-xpress/convex/schema";

const modules = import.meta.glob("../convex/**/*.ts");
const taxiModules = import.meta.glob("../apps/taxi-xpress/convex/**/*.ts");

const site = "https://deployment.test.convex.site";
const coreUser = { subject: "core-1", issuer: "https://auth.drivio.test", tokenIdentifier: "https://auth.drivio.test|core-1" };
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

/** A signed-in Convex Auth user of `app`, as Convex sees their access token. */
async function userOf(t: T, app: string | undefined, phone = "+25377123456") {
  const userId = await t.run(ctx => ctx.db.insert("users", { app, phone }));
  const subject = `${userId}|session-1`;
  return { userId, as: t.withIdentity({ subject, issuer: site, tokenIdentifier: `${site}|${subject}` }) };
}

const fix = () => ({
  latitude: 11.57, longitude: 43.14, capturedAt: Date.now(), accuracyMeters: 8,
  speedMps: 2, headingDegrees: 90, isMocked: false,
});

async function approvedDriver(t: T) {
  const driver = await userOf(t, "taxi-xpress");
  const operator = await userOf(t, "taxi-xpress", "+25377000000");
  vi.stubEnv("TAXI_XPRESS_OPERATOR_SUBJECTS", operator.userId);
  const driverId = await driver.as.mutation(api.taxiXpress.enroll, { name: "Driver A" });
  await operator.as.mutation(api.taxiXpress.setApprovalByOperator, { driverId, approved: true });
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
  vi.stubEnv("TAXI_XPRESS_TELEGRAM_BOT_TOKEN", "123:test");
  vi.stubEnv("TAXI_XPRESS_TELEGRAM_BOT_USERNAME", "TaxiXpressBot");
  vi.stubEnv("TAXI_XPRESS_TELEGRAM_WEBHOOK_SECRET", "w".repeat(32));
  vi.stubEnv("TAXI_XPRESS_PHONE_KEY_SECRET", "k".repeat(32));
});
afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

/** Captures Telegram API calls instead of sending them. */
function fakeTelegram(status = 200) {
  const sent: { method: string; body: Record<string, unknown> }[] = [];
  vi.stubGlobal("fetch", vi.fn(async (url: string, init: RequestInit) => {
    expect(String(url)).toMatch(/^https:\/\/api\.telegram\.org\/bot123:test\//);
    sent.push({ method: String(url).split("/").at(-1)!, body: JSON.parse(String(init.body)) });
    return new Response("{}", { status });
  }));
  return sent;
}

const contact = (phone: string, userId = 7, fromId = 7) => ({
  method: "POST",
  headers: { "x-telegram-bot-api-secret-token": "w".repeat(32), "content-type": "application/json" },
  body: JSON.stringify({ message: { chat: { id: 42, type: "private" }, from: { id: fromId }, contact: { phone_number: phone, user_id: userId } } }),
});

describe("Taxi Xpress sign-in with Convex Auth and Telegram", () => {
  it("links a phone through the bot, sends the code to Telegram and signs in", async () => {
    const t = setup();
    const sent = fakeTelegram();
    const phone = "+25377123456";
    await expect(t.action(api.auth.signIn, { provider: "taxi-xpress-phone", params: { phone } }))
      .rejects.toMatchObject({ data: { code: "TELEGRAM_NOT_LINKED", botUrl: "https://t.me/TaxiXpressBot" } });

    const path = "/apps/taxi-xpress/telegram/webhook";
    expect((await t.fetch(path, { ...contact("25377123456"), headers: {} })).status).toBe(401);
    await t.fetch(path, contact("25377123456", 8, 7));
    await t.fetch(path, contact("25377123456"));
    // The unlinked attempt and the foreign contact left no users behind.
    expect(await t.run(ctx => ctx.db.query("users").collect())).toHaveLength(0);
    sent.length = 0;

    expect(await t.action(api.auth.signIn, { provider: "taxi-xpress-phone", params: { phone } }))
      .toEqual({ started: true });
    expect(sent).toHaveLength(1);
    expect(sent[0].body).toMatchObject({ chat_id: "42", protect_content: true });
    const code = /code is (\d{6})/.exec(String(sent[0].body.text))![1];

    await expect(t.action(api.auth.signIn, { provider: "taxi-xpress-phone", params: { phone, code: "000000" } }))
      .rejects.toThrow("Could not verify code");
    const signedIn = await t.action(api.auth.signIn, { provider: "taxi-xpress-phone", params: { phone, code } });
    expect(signedIn.tokens?.token).toBeTruthy();
    expect(signedIn.tokens?.refreshToken).toBeTruthy();

    const users = await t.run(ctx => ctx.db.query("users").collect());
    expect(users).toHaveLength(1);
    expect(users[0]).toMatchObject({ app: "taxi-xpress", phone });
    expect(users[0].phoneVerificationTime).toBeTypeOf("number");

    const refreshed = await t.action(api.auth.signIn, { refreshToken: signedIn.tokens!.refreshToken });
    expect(refreshed.tokens?.refreshToken).toBeTruthy();
  });

  it("refuses unsupported numbers and limits codes per number", async () => {
    const t = setup();
    const sent = fakeTelegram();
    await expect(t.action(api.auth.signIn, { provider: "taxi-xpress-phone", params: { phone: "+33612345678" } }))
      .rejects.toMatchObject({ data: { code: "UNSUPPORTED_PHONE" } });
    await t.fetch("/apps/taxi-xpress/telegram/webhook", contact("25377123456"));
    const params = { phone: "+25377123456" };
    for (let i = 0; i < 3; i++) await t.action(api.auth.signIn, { provider: "taxi-xpress-phone", params });
    await expect(t.action(api.auth.signIn, { provider: "taxi-xpress-phone", params }))
      .rejects.toMatchObject({ data: { code: "RATE_LIMITED" } });
    expect(sent.filter(call => String(call.body.text).includes("code is"))).toHaveLength(3);
  });

  it("forgets the link when the driver blocked the bot", async () => {
    const t = setup();
    fakeTelegram();
    await t.fetch("/apps/taxi-xpress/telegram/webhook", contact("25377123456"));
    fakeTelegram(403);
    await expect(t.action(api.auth.signIn, { provider: "taxi-xpress-phone", params: { phone: "+25377123456" } }))
      .rejects.toMatchObject({ data: { code: "TELEGRAM_NOT_LINKED" } });
    await expect(t.action(api.auth.signIn, { provider: "taxi-xpress-phone", params: { phone: "+25377123456" } }))
      .rejects.toMatchObject({ data: { code: "TELEGRAM_NOT_LINKED" } });
  });
});

describe("Taxi Xpress component on the shared deployment", () => {
  it("accepts only Taxi Xpress users", async () => {
    const t = setup();
    await expect(t.query(api.taxiXpress.mine, {})).rejects.toThrow("Sign in");
    await expect(t.withIdentity(coreUser).mutation(api.taxiXpress.enroll, { name: "Core" })).rejects.toThrow("Sign in");
    const other = await userOf(t, "other-app");
    await expect(other.as.query(api.taxiXpress.mine, {})).rejects.toThrow("Sign in");
    const driver = await userOf(t, "taxi-xpress");
    expect(await driver.as.query(api.taxiXpress.mine, {})).toBeNull();
  });

  it("runs the driver flow through the host functions", async () => {
    const t = setup();
    const { driver } = await approvedDriver(t);
    const sessionId = await driver.as.mutation(api.taxiXpress.begin, { requestId: "request-0000000001" });
    expect(await driver.as.mutation(api.taxiXpress.publish, { sessionId, sequence: 0, position: fix(), fixAgeMs: 500 }))
      .toMatchObject({ accepted: true });
    expect(await driver.as.mutation(api.taxiXpress.heartbeat, { sessionId })).toEqual({ active: true });
    expect(await driver.as.query(api.taxiXpress.mine, {})).toMatchObject({
      approved: true, session: { id: sessionId, active: true, fresh: true },
    });
    expect(await t.mutation(api.taxiXpress.publish, { sessionId, sequence: 1, position: fix() }))
      .toMatchObject({ accepted: false, reason: "sign_in_required" });
    await driver.as.mutation(api.taxiXpress.end, { sessionId });
    expect(await driver.as.query(api.taxiXpress.mine, {})).toMatchObject({ session: { active: false, endedReason: "ended" } });
  });

  it("keeps one driver across sessions of the same user", async () => {
    const t = setup();
    const driver = await userOf(t, "taxi-xpress");
    await driver.as.mutation(api.taxiXpress.enroll, { name: "Driver A" });
    const subject = `${driver.userId}|session-2`;
    const later = t.withIdentity({ subject, issuer: site, tokenIdentifier: `${site}|${subject}` });
    expect(await later.query(api.taxiXpress.mine, {})).toMatchObject({ name: "Driver A" });
  });

  it("lets only listed operators approve or revoke drivers", async () => {
    const t = setup();
    const driver = await userOf(t, "taxi-xpress");
    const operator = await userOf(t, "taxi-xpress", "+25377000000");
    vi.stubEnv("TAXI_XPRESS_OPERATOR_SUBJECTS", operator.userId);
    const driverId = await driver.as.mutation(api.taxiXpress.enroll, { name: "Driver A" });
    expect(await driver.as.query(api.taxiXpress.canManage, {})).toBe(false);
    await expect(driver.as.mutation(api.taxiXpress.setApprovalByOperator, { driverId, approved: true }))
      .rejects.toThrow("Operator access");
    expect(await operator.as.query(api.taxiXpress.canManage, {})).toBe(true);
    const pending = await operator.as.query(api.taxiXpress.listForApproval, {
      approved: false, paginationOpts: { numItems: 25, cursor: null },
    });
    expect(pending.page).toEqual([{ driverId, name: "Driver A" }]);
    await operator.as.mutation(api.taxiXpress.setApprovalByOperator, { driverId, approved: true });
    await driver.as.mutation(api.taxiXpress.begin, { requestId: "request-0000000001" });
    await operator.as.mutation(api.taxiXpress.setApprovalByOperator, { driverId, approved: false });
    expect(await driver.as.query(api.taxiXpress.mine, {})).toMatchObject({
      approved: false, session: { active: false, endedReason: "approval_revoked" },
    });
    // The same user id signed in for another application is not an operator.
    await t.run(ctx => ctx.db.patch(operator.userId, { app: "other-app" }));
    expect(await operator.as.query(api.taxiXpress.canManage, {})).toBe(false);
  });

  it("keeps each upload route to its own users", async () => {
    const t = setup();
    const taxiPath = "/apps/taxi-xpress/v1/telemetry/chunks";
    const driver = await userOf(t, "taxi-xpress");
    expect((await driver.as.fetch("/v1/telemetry/chunks", await routeChunk(driver.userId))).status).toBe(403);
    expect((await t.withIdentity(coreUser).fetch(taxiPath, await routeChunk("core-1"))).status).toBe(403);
    expect((await driver.as.fetch(taxiPath, await routeChunk(driver.userId))).status).toBe(403);
    expect((await t.withIdentity(coreUser).fetch("/v1/telemetry/chunks", await routeChunk("core-1"))).status).toBe(201);
  });

  it("stores an approved driver's archive under the user, not the session", async () => {
    const t = setup();
    const { driver, operator, driverId } = await approvedDriver(t);
    const taxiPath = "/apps/taxi-xpress/v1/telemetry/chunks";
    const created = await driver.as.fetch(taxiPath, await routeChunk(driver.userId));
    expect(created.status).toBe(201);
    const stored = await created.json();
    const subject = `${driver.userId}|session-2`;
    const later = t.withIdentity({ subject, issuer: site, tokenIdentifier: `${site}|${subject}` });
    const retried = await later.fetch(taxiPath, await routeChunk(driver.userId));
    expect(retried.status).toBe(200);
    expect(await retried.json()).toEqual({ ...stored, alreadyExisted: true });
    const owners = await t.run(async ctx => (await ctx.db.query("trips").collect()).map(trip => trip.owner));
    expect(owners).toEqual([`${site}|${driver.userId}`]);
    await operator.as.mutation(api.taxiXpress.setApprovalByOperator, { driverId, approved: false });
    expect((await driver.as.fetch(taxiPath, await routeChunk(driver.userId))).status).toBe(403);
  });
});
