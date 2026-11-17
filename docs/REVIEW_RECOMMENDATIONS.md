# Review recommendations for the open PR stack

Review date: 17 November 2026. Reviewed head: `c8afc078` (tip of PR #32).

This document records recommendations only. Nothing here is implemented yet. Each item names the PR it belongs to so it can be picked up separately. Shared requirements derived from this review live in [wadaag_docs](https://github.com/libanxasan/wadaag_docs) under `mobility/docs/GENERIC_TRACKING_REQUIREMENTS.md` (DRI-005 and DRI-009 in particular).

## Current state

`main` has not changed since 19 July 2026 and does not compile (`sensors_plus` 7.x API, `Duration` comparisons in const constructor asserts). All work is in six stacked draft PRs:

```
main <- #2 <- #28 <- #29 <- #30 <- #31 <- #32
```

| PR | Scope | Size | Recommendation |
| --- | --- | --- | --- |
| #2 | Compile fixes, recorder lifecycle, codec robustness, atomic manifest | +865 / -131 | Merge first |
| #28 | Recorder state machine, save retry | +684 / -202 | Merge after #2 |
| #29 | 409 conflict handling, serialized sync, cleanup failures | +253 / -73 | Merge after #28 |
| #30 | Optional Convex backend, geospatial index, GPS replay | +2283 / -15 | Hold for the backend decision (R4) |
| #31 | SQLite store, kill recovery, backoff, scheduler, battery | +2358 / -45 | Split, then add R6 and R7 |
| #32 | Example app with Android and iOS projects, WorkManager, Codemagic | +3061 / -206 | Device gate (R9) before merge |
| #5 | Kanban report of 10 September 2026 | +825 | Close; findings are superseded |

No PR has had an automated check run against it. Test counts in the PR descriptions (23, then 62) were reported from local runs. Android and iOS builds and on-device runs have not been done.

## Recommendations

### Process

**R1. Merge #2, #28 and #29 now.** They are small, focused and fix real defects: `main` not compiling and HTTP 409 data loss. Take them out of draft and merge them in order into `main`, then retarget #30 to `main`.

**R2. Move CI to its own PR on `main`.** `codemagic.yaml` currently arrives only in the last commit of #32, so no PR below it is checked. Extract the `tests` workflow into a separate PR merged right after R1, so every remaining PR gets analyzer and test runs.

**R3. Run analyzer and tests on Linux.** The `tests` workflow uses `mac_mini_m2`. Analyzer and unit tests need no macOS. Use a Linux instance for `tests` and `android-debug`, and keep macOS for `ios-testflight` only. This lowers build minutes and queue time.

**R4. Decide the backend before merging #30.** Record whether Convex is the reference backend or one optional adapter, and whether it runs on Convex Cloud or self-hosted on Neon. If optional, move it under `backends/convex/` so the Flutter package stays backend neutral. The decision table is in the wadaag_docs requirements, section "Open decision: backend hosting".

**R5. Split #31.** It mixes four independent changes. Proposed order, each a separate PR:
1. `SqliteTelemetryStore`, `importFileStore` and `listTrips()`
2. Kill recovery and checkpoint timer
3. `UploadRetryPolicy`, early stop, time budget and `TelemetrySyncScheduler`
4. Stationary motion pause

Each part can then be reviewed and reverted on its own.

### Correctness and security

**R6. Credential refresh and background tokens (wadaag DRI-005).** `HttpBackendClient` already accepts `authorizationTokenProvider` (`lib/src/network/http_backend_client.dart:24`), but:
- The example passes a token fixed at build time through `DRIVIO_AUTH_TOKEN` (`example/lib/src/example_config.dart:58`). The Convex backend validates expiring custom JWTs, so uploads fail with 401 once that token expires, including background passes. The token is also embedded in the APK and IPA.
- A 401 is treated like any other failure. Request a fresh token once and retry the request once before reporting an authentication failure.
- `runBackgroundTelemetrySync` runs in a WorkManager or BGTaskScheduler isolate without the UI. Document and provide a hook for it to obtain a valid token, for example from secure storage refreshed by the host app.
- `additionalHeaders` is spread after `authorization`, so it can silently replace the bearer header. Apply it before the computed headers, or reject reserved names.

**R7. Retry limits, terminal state and retention (wadaag DRI-009).** Since #29, a chunk rejected with a checksum conflict stays queued forever, retried with backoff capped at one hour. There is no attempt limit, no terminal state and no purge anywhere in `lib/`. Add:
- A per-chunk limit by attempts and age (proposed: 20 attempts or 7 days), not counting authentication failures.
- A terminal `rejected` state for exhausted chunks and permanent 4xx responses, exposed in `TelemetrySyncResult`.
- Retention: delete local payloads after acknowledgement (proposed: 24 hours) and unsent or rejected data after a maximum age (proposed: 30 days).
- Deletion of all local data for an owner on request.

### Release

**R8. Document the breaking changes before tagging 0.2.0.** #31 adds `listTrips()` to `TelemetryStore`, raises the minimum to Dart 3.10 and Flutter 3.38, and changes retry behavior (failed chunks wait for backoff; 503 ends a pass). Add these to `CHANGELOG.md` with migration notes for third-party stores, then tag `v0.2.0` after the stack is merged.

**R9. Device validation before merging #32.** Build the debug APK with Codemagic and complete the checklist in `example/README.md` on one Android device: locked screen recording, kill and relaunch recovery, airplane mode upload, stationary sensor pause. Record device model, OS version and observed results in the PR. Run the iOS TestFlight flow afterwards.

### Shared docs

**R10. Add the wadaag_docs submodule.** Once the wadaag_docs `mobility` group is merged, add it at `docs/shared` in this repository and in Taxi-Xpress-, so both build against the same requirements.

## Suggested order

1. R1 (merge #2, #28, #29), then R2 and R3 (CI on Linux)
2. R4 (backend decision), then rebase and merge #30
3. R5 (split #31), adding R6 and R7 to the relevant parts
4. R9 (device gate), then merge #32
5. R8 (changelog and tag), R10 (submodule)
6. Close #5
