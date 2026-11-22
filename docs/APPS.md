# Applications on the shared DriVio platform

DriVio splits every application's data in two. All applications share one Convex
deployment (one component each); every application has its own Neon project.

| | Convex (shared deployment `grateful-parakeet-783`) | Neon (one project per application) |
| --- | --- | --- |
| Holds | Live data only: tracking sessions, current positions, nearby search, later matching | Long-term data: users and sign-in, profiles, approvals, trip archives |
| Knows about people | No. Only opaque ids from the application's tokens | Yes |
| Retention | Ended sessions are deleted after 24 hours | Kept |

Neither side copies the other's data. The phone is the bridge: live updates go to
Convex, durable records (sign-in, profile, trip archives) go to Neon. The only call
between them is a control message: Neon asks Convex to end a user's live sessions
when, for example, an approval is revoked.

| Application | Convex component | Neon project | Repository (submodule) |
| --- | --- | --- | --- |
| Taxi Xpress | `taxiXpress`, functions `taxiXpress:*` | `taxi-xpress`: database `taxi_xpress`, function `taxixpress`, archive bucket | [`apps/taxi-xpress`](https://github.com/libanxasan/Taxi-Xpress-) |

DriVio core can use its own Neon project (`drivio-platform`, empty for now) if it
needs long-term storage of its own.

## How the Convex side fits together

- `convex/convex.config.ts` mounts each application component. The root app stores nothing.
- `convex/auth.config.ts` trusts one token issuer per application: the application's
  sign-in on Neon. Tokens carry an opaque subject plus the claims live functions need
  (Taxi Xpress: `app`, `role`).
- `convex/apps.ts` registers each application's HTTP routes, such as the control route
  its Neon side calls.
- `convex/<app>.ts` re-exports the application's public live functions from the
  bindings in its repository (`host/`). Components cannot read the caller's identity or
  environment variables, so the bindings read the token and pass the caller in.

An application's tokens are only accepted by that application's functions.

## Trip archives

The DriVio upload contract (`HttpTelemetryBackendClient`, see `docs/BINARY_FORMAT.md`)
is unchanged, but archives are no longer stored in Convex. Each application's Neon
function accepts uploads and stores payloads in its own Neon Object Storage bucket,
with metadata in the DriVio archive tables (`drivio.trips`, `drivio.chunks`) of its
own database. Taxi Xpress implements this in its `neon/` folder.

## Adding an application

1. In the application repository: a Convex component with live data only (`convex/`),
   host bindings (`host/`), and a Neon function for sign-in and long-term data in the
   application's own Neon project.
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

Convex refuses to deploy while `auth.config.ts` reads a variable that is not set, so
every application's issuer variables must be set. Taxi Xpress needs
`TAXI_XPRESS_AUTH_ISSUER` (its Neon function URL plus `/api/auth`),
`TAXI_XPRESS_AUTH_JWKS` (issuer plus `/jwks`) and `TAXI_XPRESS_CONTROL_KEY` (shared with
its Neon function, 32 characters or more). Changing them takes effect without a redeploy.
