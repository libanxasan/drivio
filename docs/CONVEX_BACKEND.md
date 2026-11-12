# DriVio Convex backend

The Convex backend accepts the Flutter package's gzip upload contract. It stores accepted chunks in Convex File Storage and uses the authenticated user's issuer and subject to scope trips, duplicate receipts and component queries. Existing hosts opt in by setting their upload endpoint.

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
4. Call `telemetry:history` on the deployment URL with the same user's JWT and `tripId`. Pass `nextChunkIndex` as `afterChunkIndex` until it is `null`. `limit` defaults to four chunks and can be up to eight. Results are ordered by chunk index regardless of arrival order. A page can have no samples and still have a cursor if batches have expired.
5. Drive playback timing from `samples[].recordedAtMillis`. The component timestamps batches on ingestion. DriVio keeps capture timestamps in the sample values and preserves them across late uploads. A chunk with more than 2,000 valid points is evenly sampled for replay. The compressed archive contains the full original payload.

## Environment variables

Neither component requires an API key or component-specific environment variable.

| Variable | Where | Required or default |
| --- | --- | --- |
| `DRIVIO_AUTH_ISSUER` | Convex deployment | Required for authenticated uploads and queries. Use the access token's exact `iss`, for example `https://<project-ref>.supabase.co/auth/v1`. Without an issuer the backend deploys with no accepted JWT provider. |
| `DRIVIO_AUTH_ALGORITHM` | Convex deployment | Defaults to `ES256`. Set `RS256` when the issuer signs with RS256. Supabase's legacy HS256 signing does not work with this Convex custom JWT provider. |
| `DRIVIO_AUTH_AUDIENCE` | Convex deployment | Defaults to `authenticated`. Set it to the actual access token audience if different. |
| `DRIVIO_AUTH_JWKS` | Convex deployment | Defaults to the issuer URL plus `/.well-known/jwks.json`. Set it if the issuer publishes its public keys elsewhere. |
| `GEOSPATIAL_LOG_LEVEL` | Convex deployment | Optional. Geospatial defaults to `INFO`. |
| `CONVEX_DEPLOY_KEY` | CI or deploy shell | Required for noninteractive cloud deployments without a CLI login. Use a preview key for preview deployment and the correct production key for production. |
| `CONVEX_DEPLOYMENT` | Local CLI `.env.local` | Set by Convex when selecting or creating a development deployment. |
| `CONVEX_SITE_URL` | Flutter host configuration | HTTP Actions base URL for uploads, typically `https://<deployment>.convex.site`. The local smoke test reads this from `.env.local` when present. |
| `CONVEX_URL` | Client configuration | Deployment base URL for `POST /api/query`, typically `https://<deployment>.convex.cloud`. The local smoke test reads this from `.env.local`. |
| `CONVEX_AGENT_MODE` | Local CLI shell | Set to `anonymous` for the disposable local verification below. |

Convex validates bearer tokens with the configured public keys. The token subject must equal the Flutter recorder's `userId` and the `X-User-Id` request header. With an existing Supabase host, use the current user's ID and current session access token. [Convex custom JWT configuration](https://docs.convex.dev/auth/advanced/custom-jwt) · [Supabase JWT verification](https://supabase.com/docs/guides/auth/jwts)

## Verify locally

Run in a fresh checkout for a disposable deployment with synthetic trips. The first Convex CLI run downloads the local backend. `--prepare` creates a test-only key and environment file under `.convex/`.

```bash
npm ci
CONVEX_AGENT_MODE=anonymous npx convex dev --once
npm run check
npm run test:convex -- --prepare
CONVEX_AGENT_MODE=anonymous npx convex env set --from-file .convex/drivio-smoke-auth.env
CONVEX_AGENT_MODE=anonymous npm run dev
```

Leave `npm run dev` running. In a second terminal at the repository root run `npm run test:convex`. It sends gzip DTL1 and JSON chunks to the real HTTP action and checks authentication, owner isolation, checksums, duplicate and conflicting uploads, radius filtering, replay pagination and out-of-order arrival. For the Flutter regression suite, run `flutter analyze` and `flutter test` at the root, then `flutter test` in `example/`.

## Deploy and verify a cloud preview

1. In the intended Convex project, set the preview environment variables above for your auth provider in **Project Settings > Environment Variables**. Use a test issuer or test user with an asymmetric signing key.
2. Set `CONVEX_DEPLOY_KEY` from the project's preview deploy key in the shell or CI secret store. Run `npm ci`, `npm run check`, then `npx convex deploy --preview-name drivio-convex-components`. Retrieve the two URLs from that preview deployment's settings. [Convex preview deployments](https://docs.convex.dev/production/multiple-deployments#using-preview-deployments)
3. Set the Flutter `HttpTelemetryBackendClient.endpoint` to `<CONVEX_SITE_URL>/v1/telemetry/chunks` and supply the existing token callback. Record and stop a short test trip, then call `synchronizePendingData()`. Check for successful upload receipts and retry the same test payload to confirm the duplicate response. The endpoint accepts up to 4 MiB compressed and 8 MiB decompressed per chunk.
4. With the same access token, call each read function using the deployment URL. Replace the sample coordinates and trip ID with the test trip's values. Verify the location and GPS timestamps, then repeat the calls with a second test user's token and check that the original trip is absent. [Convex HTTP API](https://docs.convex.dev/http-api/)

```bash
curl -fsS "$CONVEX_URL/api/query" \
  -H "Authorization: Bearer $ACCESS_TOKEN" -H 'Content-Type: application/json' \
  --data '{"path":"telemetry:nearby","args":{"latitude":11.5729,"longitude":43.1456,"radiusMeters":1000},"format":"json"}'

curl -fsS "$CONVEX_URL/api/query" \
  -H "Authorization: Bearer $ACCESS_TOKEN" -H 'Content-Type: application/json' \
  --data '{"path":"telemetry:history","args":{"tripId":"your-test-trip-id"},"format":"json"}'
```

For production, set the auth variables on the production deployment and use its deploy key or a logged-in CLI with `npx convex deploy`. Switch a host's upload endpoint after verifying the intended deployment. Historical uploads from another backend require a separate migration.
