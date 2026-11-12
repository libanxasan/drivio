import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, randomUUID, sign } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { parseEnv } from "node:util";
import { gzipSync } from "node:zlib";

const issuer = "https://auth.drivio.test";
const keyPath = ".convex/drivio-smoke-private.pem";
const keyId = "drivio-local-smoke";

if (process.argv.includes("--prepare")) {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwks = { keys: [{ ...publicKey.export({ format: "jwk" }), kid: keyId, alg: "ES256", use: "sig" }] };
  const data = Buffer.from(JSON.stringify(jwks)).toString("base64");
  await mkdir(".convex", { recursive: true });
  await writeFile(keyPath, privateKey.export({ type: "pkcs8", format: "pem" }), { mode: 0o600 });
  await writeFile(".convex/drivio-smoke-auth.env", [
    `DRIVIO_AUTH_ISSUER=${issuer}`,
    "DRIVIO_AUTH_ALGORITHM=ES256",
    "DRIVIO_AUTH_AUDIENCE=authenticated",
    `DRIVIO_AUTH_JWKS=data:text/plain;charset=utf-8;base64,${data}`,
    "",
  ].join("\n"));
  console.log("Created local smoke-test auth configuration.");
  process.exit(0);
}

const env = parseEnv(await readFile(".env.local", "utf8"));
assert.match(env.CONVEX_DEPLOYMENT ?? "", /^anonymous[:-]/, "Use a disposable anonymous Convex deployment");
const cloud = new URL(env.CONVEX_URL);
const site = new URL(env.CONVEX_SITE_URL ?? `http://127.0.0.1:${Number(cloud.port) + 1}`);
for (const url of [cloud, site]) {
  assert.ok(["127.0.0.1", "localhost", "[::1]"].includes(url.hostname), "Use local URLs for smoke data");
}
const privateKey = await readFile(keyPath, "utf8");
const owner = randomUUID();
const other = randomUUID();
const tripId = `smoke-${randomUUID()}`;
const startedAt = Date.UTC(2024, 0, 1);
const origin = { latitude: 11.5729, longitude: 43.1456 };

function token(subject) {
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  const now = Math.floor(Date.now() / 1_000);
  const data = `${encode({ alg: "ES256", typ: "JWT", kid: keyId })}.${encode({
    iss: issuer, sub: subject, aud: "authenticated", iat: now, exp: now + 600,
  })}`;
  const signature = sign("sha256", Buffer.from(data), { key: privateKey, dsaEncoding: "ieee-p1363" });
  return `${data}.${signature.toString("base64url")}`;
}

function continuousChunk(index, points, chunkId = `chunk-${index}`) {
  const bytes = [...Buffer.from("DTL1")];
  function uint(number) {
    while (number >= 128) {
      bytes.push((number % 128) | 128);
      number = Math.floor(number / 128);
    }
    bytes.push(number);
  }
  function integer(number) {
    uint(number < 0 ? -number * 2 - 1 : number * 2);
  }
  function string(value) {
    const encoded = Buffer.from(value);
    uint(encoded.length);
    bytes.push(...encoded);
  }
  uint(1); // Schema version.
  uint(0); // Continuous chunk type.
  string(tripId);
  string(chunkId);
  uint(index);
  const start = points[0].time;
  const end = points.at(-1).time;
  uint(start);
  uint(end - start);
  uint(points.length);
  let previousTime = start;
  let previousLatitude = 0;
  let previousLongitude = 0;
  for (const { latitude, longitude, time, mocked } of points) {
    const latitudeE7 = Math.round(latitude * 1e7);
    const longitudeE7 = Math.round(longitude * 1e7);
    uint(time - previousTime);
    integer(latitudeE7 - previousLatitude);
    integer(longitudeE7 - previousLongitude);
    uint(1_250); // Speed, cm/s.
    uint(9_000); // Heading, centidegrees.
    uint(30); // Accuracy, decimeters.
    integer(10); // Altitude, decimeters.
    uint(0);
    uint(0);
    uint(mocked ? 1 : 0);
    previousTime = time;
    previousLatitude = latitudeE7;
    previousLongitude = longitudeE7;
  }
  bytes.push(0, 0, 0, 0); // No motion frames, raw motion, events or hourly aggregate.
  return { chunkId, index, start, end, type: "continuous", format: "compact-binary", payload: gzipSync(Buffer.from(bytes)) };
}

function jsonChunk(index, type, value) {
  return {
    chunkId: `${type}-${index}`, index, start: startedAt, end: startedAt + 5_000,
    type, format: "json", payload: gzipSync(JSON.stringify(value)),
  };
}

async function upload(chunk, { subject = owner, headerUser = subject, checksum } = {}) {
  const response = await fetch(new URL("/v1/telemetry/chunks", site), {
    method: "POST",
    headers: {
      ...(subject ? { authorization: `Bearer ${token(subject)}` } : {}),
      "content-type": "application/octet-stream",
      "content-encoding": "gzip",
      "idempotency-key": `${tripId}:${chunk.chunkId}`,
      "x-user-id": headerUser,
      "x-trip-id": tripId,
      "x-chunk-id": chunk.chunkId,
      "x-chunk-index": String(chunk.index),
      "x-chunk-type": chunk.type,
      "x-schema-version": "1",
      "x-payload-format": chunk.format,
      "x-checksum-sha256": checksum ?? createHash("sha256").update(chunk.payload).digest("hex"),
      "x-started-at-ms": String(chunk.start),
      "x-ended-at-ms": String(chunk.end),
    },
    body: chunk.payload,
  });
  return { code: response.status, body: await response.json() };
}

async function query(name, args, subject = owner) {
  const response = await fetch(new URL("/api/query", cloud), {
    method: "POST",
    headers: {
      ...(subject ? { authorization: `Bearer ${token(subject)}` } : {}),
      "content-type": "application/json",
    },
    body: JSON.stringify({ path: `telemetry:${name}`, args, format: "json" }),
  });
  return response.json();
}

const nearArgs = { ...origin, radiusMeters: 100, limit: 50 };
const earlierPoints = [{ ...origin, time: startedAt }, { ...origin, time: startedAt + 1_000 }];
const earlier = continuousChunk(0, earlierPoints);
const laterPoint = { ...origin, longitude: 43.1458, time: startedAt + 3_000 };
const later = continuousChunk(1, [
  { ...origin, time: startedAt + 2_000 }, laterPoint,
  { ...origin, time: startedAt + 4_000, mocked: true },
]);
const route = jsonChunk(2, "route", { totalDistanceMeters: 35 });
const manifest = jsonChunk(3, "tripManifest", {
  tripId, schemaVersion: 1, status: "closed", startedAtMillis: startedAt, endedAtMillis: startedAt + 5_000,
});

assert.equal((await upload(earlier, { subject: null, headerUser: owner })).code, 401);
assert.equal((await upload(earlier, { subject: other, headerUser: owner })).code, 403);
assert.equal((await upload(earlier, { checksum: "0".repeat(64) })).code, 422);
assert.equal((await upload({ ...earlier, end: earlier.end + 1 })).code, 422);
assert.equal((await query("nearby", nearArgs, null)).status, "error");
assert.equal((await query("history", { tripId }, null)).status, "error");

const saved = await upload(later);
assert.equal(saved.code, 201, JSON.stringify(saved));
assert.equal(saved.body.accepted, true);
assert.equal(saved.body.alreadyExisted, false);
assert.equal((await upload(route)).code, 201);
assert.equal((await upload(manifest)).code, 201);
assert.equal((await upload(manifest)).body.alreadyExisted, true);

const attempts = await Promise.all([upload(earlier), upload(earlier)]);
assert.deepEqual(attempts.map(({ code }) => code).sort(), [200, 201]);
assert.equal(attempts[0].body.chunkId, attempts[1].body.chunkId);
assert.equal(attempts.find(({ code }) => code === 200).body.alreadyExisted, true);
const changed = continuousChunk(0, [{ ...origin, time: startedAt, longitude: 43.1455 }]);
const conflict = await upload(changed);
assert.equal(conflict.code, 409);
assert.equal(conflict.body.alreadyExisted, undefined);
assert.equal((await upload(continuousChunk(0, earlierPoints, "same-index"))).code, 409);

const ownerNearby = (await query("nearby", nearArgs)).value.find((point) => point.tripId === tripId);
assert.equal(ownerNearby.longitude, laterPoint.longitude);
assert.equal(ownerNearby.recordedAtMillis, laterPoint.time);
assert.ok(ownerNearby.distanceMeters > 0 && ownerNearby.distanceMeters < 100);
assert.ok(!(await query("nearby", { ...nearArgs, radiusMeters: 1 })).value.some((point) => point.tripId === tripId));
assert.deepEqual((await query("nearby", nearArgs, other)).value, []);
assert.deepEqual((await query("history", { tripId }, other)).value, { chunks: [], nextChunkIndex: null });

const first = (await query("history", { tripId, limit: 1 })).value;
assert.equal(first.nextChunkIndex, 0);
assert.deepEqual(first.chunks.map((chunk) => chunk.chunkIndex), [0]);
assert.deepEqual(first.chunks[0].samples.map((point) => point.recordedAtMillis), earlierPoints.map((point) => point.time));
const second = (await query("history", { tripId, afterChunkIndex: first.nextChunkIndex, limit: 1 })).value;
assert.equal(second.nextChunkIndex, null);
assert.deepEqual(second.chunks.map((chunk) => chunk.chunkIndex), [1]);
assert.deepEqual(second.chunks[0].samples.map((point) => point.recordedAtMillis), [startedAt + 2_000, startedAt + 3_000]);

assert.equal((await upload(earlier, { subject: other })).code, 201);
assert.equal((await query("history", { tripId }, other)).value.chunks.length, 1);
assert.equal((await query("history", { tripId })).value.chunks.length, 2);
console.log("Convex smoke test passed for authenticated upload, retries, Geospatial and Batched Replay.");
