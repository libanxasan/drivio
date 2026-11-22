# DriVio Convex backend

The Convex backend accepts the Flutter package's gzip upload contract. It stores accepted chunks in Convex File Storage and uses the authenticated user's issuer and subject to scope trips, duplicate receipts and component queries. Existing hosts opt in by setting their upload endpoint.

DriVio's own clients sign in anonymously with [Convex Auth](https://labs.convex.dev/auth) (`auth:signIn` with `provider: "anonymous"`). The token subject is `<userId>|<sessionId>`; uploads send the user id part as `X-User-Id`. Live streams, gaps, backfill and retention are described in [`APPS.md`](APPS.md).

## Install and register

Use Node.js 22 or later and run commands from the repository root. Both components and the Convex CLI are pinned in `package.json` and `package-lock.json`. On this branch install the locked dependencies with `npm ci`.

| Component | Upstream install command | Official documentation |
| --- | --- | --- |
| Geospatial 0.2.1 | `npm install @convex-dev/geospatial` | [Markdown](https://www.convex.dev/components/geospatial/geospatial.md), [llms.txt](https://www.convex.dev/components/geospatial/llms.txt), [Skill](https://www.convex.dev/components/geospatial/SKILL.md) |
| Batched Replay 0.1.1 | `npm install @convex-dev/batched-replay` | [Markdown](https://www.convex.dev/components/batched-replay/batched-replay.md), [llms.txt](https://www.convex.dev/components/batched-replay/llms.txt), [Skill](https://www.convex.dev/components/batched-replay/SKILL.md) |

### Geospatial checklist

1. Install the package and register its `convex.config.js` export with `app.use(geospatial)` in `convex/convex.config.ts`.
2. Generate bindings for `components.geospatial` with `npx convex dev --once`. `convex/telemetry.ts` passes those bindings to `GeospatialIndex`.
3. Upload a continuous DTL1 chunk with GPS samples to `/v1/telemetry/chunks` on the HTTP Actions URL. The ingest mutation inserts or replaces the trip's latest valid, non-mocked location and indexes it by owner. An older chunk can arrive later without moving the location backwards.
4. Call `telemetry:nearby` on the deployment URL with a user JWT and `latitude`, `longitude`, `radiusMeters`, and optional `limit`. The radius is in meters and can be up to 100,000. The limit defaults to 20 and can be up to 50. Check that a smaller radius excludes a farther point and that another user cannot see it.

### Batched Replay checklist

1. Install the package and register its `convex.config.js` export with `app.use(batchedReplay)` in `convex/convex.config.ts`.
2. Generate bindings for `components.batchedReplay` with `npx convex dev --once`. `convex/telemetry.ts` uses the server-side `BatchedReplay` class, with one room per trip and one stream per accepted continuous chunk.
3. Upload a continuous DTL1 chunk with GPS samples. Replay is populated in the same mutation that records the upload receipt. The component retains each batch for seven days from ingestion, with its scheduled cleanup. A retry with the same chunk ID and checksum does not append again.
4. Call `telemetry:history` on the deployment URL with the same user's JWT and `tripId`. Pass `nextChunkIndex` as `afterChunkIndex` until it is `null`. `limit` defaults to four chunks and can be up to eight. Results are ordered by chunk index regardless of arrival order. A page can have no samples and still have a cursor if batches have expired. Restart from the first page after synchronization if you began paging while uploads were still arriving.
5. Drive playback timing from `samples[].recordedAtMillis`. The component timestamps batches on ingestion. DriVio keeps capture timestamps in the sample values and preserves them across late uploads. A chunk with more than 2,000 valid points is evenly sampled for replay. The compressed archive contains the full original payload.

## Environment variables

Neither component requires an API key or component-specific environment variable.

| Variable | Where | Required or default |
| --- | --- | --- |
| `JWT_PRIVATE_KEY`, `JWKS` | Convex deployment | Required. Convex Auth's RS256 signing key (PKCS#8, newlines replaced by spaces) and its public JWKS. Generate them as in the [Convex Auth manual setup](https://labs.convex.dev/auth/setup/manual). |
| `SITE_URL` | Convex deployment | Required by Convex Auth. The deployment's `.convex.site` URL is enough for anonymous sign-in. |
| `ARCHIVE_PERIOD` | Convex deployment | Optional retention (`30d`, `12h`, `90m` or milliseconds). Unset keeps everything. |
| Application variables | Convex deployment | See [`APPS.md`](APPS.md), for example `TAXI_XPRESS_AUTH_ISSUER`. |
| `GEOSPATIAL_LOG_LEVEL` | Convex deployment | Optional. Geospatial defaults to `INFO`. |
| `CONVEX_DEPLOY_KEY` | CI or deploy shell | Required for noninteractive cloud deployments without a CLI login. |
| `CONVEX_DEPLOYMENT` | Local CLI `.env.local` | Set by Convex when selecting or creating a development deployment. |
| `CONVEX_SITE_URL` | Flutter host configuration | HTTP Actions base URL for uploads, typically `https://<deployment>.convex.site`. |
| `CONVEX_URL` | Client configuration | Deployment base URL for `/api/query`, `/api/mutation` and `/api/action`, typically `https://<deployment>.convex.cloud`. |
| `CONVEX_AGENT_MODE` | Local CLI shell | Set to `anonymous` for the disposable local verification below. |
| `CONVEX_SELF_HOSTED_URL` | Local smoke-test shell | Optional. Point to a disposable self-hosted backend on loopback. |
| `DRIVIO_SMOKE_REMOTE` | Smoke-test shell | Set to `1` to run `npm run test:convex` against a cloud deployment. It writes test trips there. |

Convex validates bearer tokens with the configured public keys. The `X-User-Id` header must equal the user id in the token subject.

## Verify locally

Run in a fresh checkout for a disposable deployment with synthetic trips. The first Convex CLI run downloads the local backend.

```bash
npm ci
CONVEX_AGENT_MODE=anonymous npx convex dev --once
npm run check
# set JWT_PRIVATE_KEY, JWKS and SITE_URL on the local deployment (Convex Auth manual setup)
CONVEX_AGENT_MODE=anonymous npm run dev
```

Leave `npm run dev` running. In a second terminal at the repository root run `npm run test:convex`. It sends gzip DTL1 and JSON chunks to the real HTTP action and checks authentication, owner isolation, checksums, duplicate and conflicting uploads, radius filtering, replay pagination and out-of-order arrival. For the Flutter regression suite, run `flutter analyze` and `flutter test` at the root, then `flutter test` in `example/`.

For a disposable self-hosted Convex backend on loopback, export its `CONVEX_SELF_HOSTED_URL`, `CONVEX_SELF_HOSTED_ADMIN_KEY` and `CONVEX_SITE_URL`. Set the Convex Auth variables, run `npx convex deploy --yes --typecheck enable`, and `npm run test:convex` against that backend. [Convex self-hosting](https://docs.convex.dev/self-hosting)

## Deploy and verify a cloud deployment

1. Set the variables above on the deployment, then run `npm ci`, `npm run check` and `npx convex dev --once` (dev) or `npx convex deploy` (prod).
2. Run `DRIVIO_SMOKE_REMOTE=1 npm run test:convex` and `npx tsx scripts/stream-smoke.ts` from the repository root. The first checks the upload contract with two anonymous users; the second streams with a 20 minute gap, uploads the archive and checks that backfill restores it.
3. Run the example app with `--dart-define=DRIVIO_CONVEX_URL=<CONVEX_URL>`. It signs in anonymously, streams and uploads; see [`example/README.md`](../example/README.md).

```bash
curl -fsS "$CONVEX_URL/api/query" \
  -H "Authorization: Bearer $ACCESS_TOKEN" -H 'Content-Type: application/json' \
  --data '{"path":"telemetry:history","args":{"tripId":"your-test-trip-id"},"format":"json"}'
```
