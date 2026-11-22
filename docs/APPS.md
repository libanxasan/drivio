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
- `convex/auth.config.ts` adds each application's auth provider next to DriVio's own.
- `convex/apps.ts` registers each application: which identities it owns and its
  upload admission check. `convex/http.ts` gives each one an upload route that runs
  that check, then the shared chunk validation and storage.
- `convex/<app>.ts` re-exports the application's public functions from the bindings
  in its repository (`host/`). Components cannot read the signed-in user, environment
  variables or serve HTTP, so the bindings read `ctx.auth` and pass the caller in.

Identities are kept apart: an application's identity is accepted only by that
application's functions and upload route, and the core upload route
(`/v1/telemetry/chunks`) refuses identities that belong to an application. Archive
records are keyed by the token identifier, which includes the issuer, so owners
never collide across applications.

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

Taxi Xpress needs `TAXI_XPRESS_AUTH_ISSUER` (and optionally `TAXI_XPRESS_AUTH_AUDIENCE`,
`TAXI_XPRESS_AUTH_JWKS`, `TAXI_XPRESS_OPERATOR_SUBJECTS`) on the deployment. Until the
issuer is set, its functions treat every caller as signed out.
