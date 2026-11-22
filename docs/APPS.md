# Applications on the shared DriVio platform

Every application keeps everything about itself in its own Neon project. Telemetry
lives on one shared Convex deployment (`grateful-parakeet-783`), where each
application is a component.

| | Convex (shared deployment) | Neon (one project per application) |
| --- | --- | --- |
| Holds | Telemetry: live streams (points, motion frames, events), live sessions and positions, nearby search, DriVio's own trip archives | Everything about the application: users and sign-in, profiles, approvals, its own trip archives |
| Knows about people | No. Only opaque ids from tokens | Yes |
| Retention | Until `ARCHIVE_PERIOD` (see below). Unset means nothing is deleted | Kept |

The Flutter app decides what it records and where it sends it: it can stream to
Convex, archive to its Neon function, both, or neither. An application's requirements
never restrict another application or DriVio itself.

| Application | Convex component | Archives | Repository (submodule) |
| --- | --- | --- | --- |
| DriVio (example app and SDK clients) | root app (`streams:*`, `telemetry:*`) | On Convex (`/v1/telemetry/chunks`) | this repository |
| Taxi Xpress | `taxiXpress`, functions `taxiXpress:*` | Neon project `taxi-xpress`: database `taxi_xpress`, function `taxixpress`, bucket `taxi-xpress-archive` | [`apps/taxi-xpress`](https://github.com/libanxasan/Taxi-Xpress-) |

## Live streams and backfill

A stream is one recording session of one owner. Each stream declares the kinds it
carries (`points`, `frames`, `events`); backfill restores only those kinds.

1. The phone streams live items (DriVio: `streams:publish` every 5 seconds; Taxi
   Xpress: each accepted position from `taxiXpress:publish`).
2. When the phone goes offline but keeps recording, Convex opens a gap: either the
   next item arrives more than 60 seconds after the previous one, or the silence
   check (every minute) finds the stream quiet.
3. The phone uploads its archive chunks when it is back online. DriVio clients
   upload to Convex, which wakes backfill at once. Taxi Xpress uploads to its Neon
   function, and Convex queries it (`GET /v1/archive/chunks`) every 5 minutes.
4. Backfill downloads the continuous chunks overlapping the gap, verifies their
   checksums, decodes them and inserts the missing items, skipping duplicates. The
   gap becomes `filled`, `partial` (retried with backoff) or, after 48 hours,
   `unrecoverable`.

Example: a driver streams to Convex, loses signal for 20 minutes and keeps driving.
Once the phone uploads its archive, those 20 minutes appear in the stream tables.

## Retention

`ARCHIVE_PERIOD` on the Convex deployment sets how long telemetry is kept for
analytics, model training, review and inspection: `30d`, `12h`, `90m`, or a number
of milliseconds. An hourly job deletes stream items, gaps, ended streams, trips,
archived chunks and ended Taxi Xpress sessions older than that. When it is unset or
invalid, nothing is deleted.

## How the Convex side fits together

- `convex/convex.config.ts` mounts each application component.
- `convex/auth.config.ts` trusts Convex Auth (anonymous sign-in for DriVio's own
  clients) and one token issuer per application (Taxi Xpress: its Better Auth on Neon).
- `convex/identity.ts` maps a token to `{ app, owner, subject }`. An application's
  tokens are accepted only by that application's functions.
- `convex/apps.ts` registers each application's HTTP routes and, when its archives
  live elsewhere, its archive source.
- `convex/<app>.ts` re-exports the application's live functions from the bindings in
  its repository (`host/`). Components cannot read the caller's identity or
  environment variables, so the bindings read the token and pass the caller in.
- `convex/streams.ts`, `convex/backfill.ts` and `convex/retention.ts` hold the stream
  store, backfill and retention; `convex/crons.ts` schedules them.

## Adding an application

1. In the application repository: a Convex component (`convex/`), host bindings
   (`host/`), and a Neon function for sign-in and everything else in the
   application's own Neon project. To have its streams backfilled, expose an archive
   query like Taxi Xpress's `GET /v1/archive/chunks`.
2. Here: `git submodule add -b <branch> <repo url> apps/<name>`, `app.use(...)` it in
   `convex/convex.config.ts`, add its providers to `convex/auth.config.ts`, register it
   in `convex/apps.ts`, and re-export its functions from `convex/<name>.ts`.
3. Add an integration test in `tests/` and run `npm test`.
4. Set its variables on the deployment, then `npx convex dev --once` (dev) or
   `npx convex deploy` (prod).

## Deploying

```sh
git submodule update --init apps/taxi-xpress   # not recursive
npm ci
npm run check && npm test
npx convex dev --once                           # dev deployment grateful-parakeet-783
```

Convex refuses to deploy while `auth.config.ts` reads a variable that is not set.

| Variable | Purpose |
| --- | --- |
| `JWT_PRIVATE_KEY`, `JWKS`, `SITE_URL` | Convex Auth signing keys and site URL, for anonymous sign-in |
| `TAXI_XPRESS_AUTH_ISSUER` | Taxi Xpress Neon function URL plus `/api/auth` |
| `TAXI_XPRESS_AUTH_JWKS` | Issuer plus `/jwks` |
| `TAXI_XPRESS_CONTROL_KEY` | Shared with the Taxi Xpress Neon function, 32 characters or more |
| `TAXI_XPRESS_ARCHIVE_URL`, `TAXI_XPRESS_ARCHIVE_KEY` | Optional. Default to the issuer's function URL and a key derived from the control key, which the Neon function derives the same way |
| `ARCHIVE_PERIOD` | Optional retention, see above |

Checks against a deployment:

```sh
npx convex run backfill:checkArchive '{"app":"taxi-xpress"}'   # Convex can read the Taxi Xpress archive
npx tsx scripts/stream-smoke.ts                                # stream, 20 minute gap, archive upload, backfill
DRIVIO_SMOKE_REMOTE=1 npm run test:convex                      # upload contract, owner isolation, replay
```
