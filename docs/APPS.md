# Applications on the shared DriVio deployment

One Convex deployment serves DriVio core and every application built on it. DriVio
core is the root app; each application is a Convex component with its own tables,
scheduled jobs and indexes, and stores its trip archives in the shared DriVio
archive.

| Application | Component | Repository (submodule) | Functions | Archive upload route |
| --- | --- | --- | --- | --- |
| Taxi Xpress | `taxiXpress` | [`apps/taxi-xpress`](https://github.com/libanxasan/Taxi-Xpress-) | `taxiXpress:*` | `/apps/taxi-xpress/v1/telemetry/chunks` |

## How it fits together

- `convex/convex.config.ts` mounts each application component with `app.use(...)`.
- `convex/auth.ts` runs [Convex Auth](https://labs.convex.dev/auth) for every application.
  Each application brings its sign-in providers; `convex/identity.ts` maps each provider
  to its application, runs the application's check before a user is created, and tags
  the user with the application name. Accounts are never linked across applications, so
  the same phone number gives one user per application.
- `convex/auth.config.ts` trusts Convex Auth's own tokens and DriVio core's tokens.
- `convex/apps.ts` registers each application: its upload admission check and any extra
  HTTP routes (webhooks). `convex/http.ts` gives each one an upload route that runs that
  check, then the shared chunk validation and storage, and serves Convex Auth's JWKS.
- `convex/<app>.ts` re-exports the application's public functions from the bindings
  in its repository (`host/`). Components cannot read the signed-in user, environment
  variables or serve HTTP, so the bindings read `ctx.auth` and pass the caller in.

Users are kept apart: an application's users are accepted only by that application's
functions and upload route, and the core upload route (`/v1/telemetry/chunks`) refuses
them. Convex Auth subjects are `<userId>|<sessionId>`, so archives are owned by
`<issuer>|<userId>` (`principal()` in `convex/identity.ts`) and stay with the user
across sessions. DriVio core tokens keep their token identifier.

## Adding an application

1. In the application repository, make `convex/` a component
   (`defineComponent("<name>")`) whose functions take the caller as an argument, and
   add `host/` bindings modelled on Taxi Xpress (`host/auth.ts`, `host/index.ts`).
2. Here: `git submodule add -b <branch> <repo url> apps/<name>`.
3. `app.use(...)` it in `convex/convex.config.ts`, add its providers to
   `convex/auth.config.ts`, register it in `convex/apps.ts`, and re-export its
   functions from `convex/<name>.ts`.
4. Add an integration test in `tests/` and run `npm test`.
5. Set its environment variables on the deployment, then `npx convex dev --once`
   (dev) or `npx convex deploy` (prod). This also regenerates the component's
   `convex/_generated`, which is committed in the application repository.

## Deploying

```sh
git submodule update --init apps/taxi-xpress   # not recursive
npm ci
npm run check && npm test
npx convex dev --once                           # dev deployment grateful-parakeet-783
```

Convex refuses to deploy while `auth.config.ts` reads a variable that is not set on
the deployment, even one with a default in code, so `DRIVIO_AUTH_ISSUER`,
`DRIVIO_AUTH_ALGORITHM`, `DRIVIO_AUTH_AUDIENCE` and `DRIVIO_AUTH_JWKS` must all be set.
The dev deployment holds placeholders for DriVio core
(`https://drivio-auth-not-configured.invalid`), so no core token is accepted yet.

Convex Auth needs `JWT_PRIVATE_KEY`, `JWKS` and `SITE_URL` (any URL; phone sign-in does
not use it). They are set on the dev deployment. To rotate the keys, generate a new
RS256 pair as in the [Convex Auth manual setup](https://labs.convex.dev/auth/setup/manual)
and set both; existing sessions then have to sign in again.

Taxi Xpress also needs `TAXI_XPRESS_TELEGRAM_BOT_TOKEN`, `TAXI_XPRESS_TELEGRAM_BOT_USERNAME`,
`TAXI_XPRESS_TELEGRAM_WEBHOOK_SECRET`, `TAXI_XPRESS_PHONE_KEY_SECRET` and, for approvals,
`TAXI_XPRESS_OPERATOR_SUBJECTS` (see its `docs/DRIVER_SETUP.md`). Changing a variable
takes effect without a redeploy.
