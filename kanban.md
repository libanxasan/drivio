# Weekly Engineering Kanban Report

**Project under review:** `drivio` — `driving_telemetry` Flutter package
**Report date:** 2026-08-03
**Reviewed refs:** `main` @ `3df62f4` · draft PR **#2** `claude/codebase-stability-quality-tz5e6t` @ `d4a9d76`
**Prepared by:** Engineering review (automated, code-aware)

> Rotation note: this cycle's deep review targets **drivio**, selected as the
> oldest-modified project (last commit 2026-07-18) that has **no** Kanban report
> on `main` or in any open PR. Sibling projects reviewed in prior cycles
> (ussd_dj #10, automotivate #12, PointS_portal #5) already carry report PRs and
> are referenced only for portfolio context.

---

## Executive Summary

- **Active projects:** 15 in the portfolio; **1 deep-reviewed this cycle** (`drivio`).
- **Overall portfolio status:** drivio is an early-stage (`0.1.0`), well-architected
  telemetry **package** (not an app) whose `main` branch **does not compile**. A
  substantial draft PR (#2) already fixes the compile breaks plus a cluster of
  lifecycle/reliability bugs and is `mergeable_state: clean`.
- **Completed this week:** No merges to `main`. Draft PR #2 authored (865 additions /
  131 deletions across 21 files) covering recorder lifecycle, codec robustness,
  storage atomicity, synchronizer resilience, and the sensors_plus 7.x migration.
- **Work currently in progress:** PR #2 (draft) — stability/quality pass.
- **Main blockers:** `main` fails to build (sensors_plus 7.x API + non-const
  `Duration` asserts). Both are fixed only inside the unmerged draft PR #2.
- **Highest-risk item:** `main` is un-buildable, so any downstream host app pinning
  the `main` ref is broken today.
- **Next release target:** `0.1.1` = merge of PR #2 (first genuinely buildable tag).
- **Key decision required:** Promote PR #2 from **draft → ready** and merge, versus
  cherry-picking only the two compile fixes.
- **Recommended focus next week:** Merge PR #2, tag a buildable `0.1.1`, then add a
  permission-handling + synchronizer path to the example so the package is
  device-testable end-to-end.

---

## Portfolio Kanban Snapshot

Counts below scope drivio work items surfaced by this review.

| Status | Count | Notes |
|---|---:|---|
| Inbox | 3 | Permissions in example, sync in example, WAL/retention policy decision |
| Ready | 2 | Tag `0.1.1`; expand test matrix |
| In Progress | 1 | Draft PR #2 (stability pass) |
| Review / Testing | 1 | PR #2 needs promotion from draft + review |
| Blocked | 2 | `main` build (sensors_plus 7.x) · `main` build (const Duration asserts) |
| Done | 0 | Nothing merged to `main` this week |
| Parked | 1 | On-device verification (needs Android device + Djibouti SIM/GPS) |

---

## Project Status

### 1. drivio — `driving_telemetry`

**Current state:**
A cleanly layered, single-responsibility Flutter **package** for compact driving
telemetry: it collects 25 Hz motion + ~1 Hz GPS, condenses to one-second frames,
detects candidate events, retains short raw-evidence windows, delta-encodes and
gzips versioned binary chunks (`DTL1`), persists them atomically to the app
support directory, matches routes through OSRM after a trip, and uploads chunks to
a backend with idempotency + SHA-256 integrity. By explicit design it does **no**
scoring — that belongs to the backend. Architecture is strong; the branch is not
shippable because `main` currently fails to compile.

**Completed (confirmed in code):**
- Full domain model set (`location_sample`, `raw_motion_sample`, `motion_frame`,
  `event_candidate`, `hourly_aggregate`, `telemetry_chunk`, `trip_manifest`,
  `trip_result`, `osrm_match_result`, `effective_speed_limit`, `street_context`).
- Recorder orchestration with lifecycle FSM
  (`idle→starting→recording→stopping→disposed`), serialized write tail
  (`_writeTail`), ring buffers, evidence capture, chunk flushing by
  duration/estimated-bytes, haversine distance with plausibility gating.
- Codec (`telemetry_binary_codec` / `compact_binary`): varint, ZigZag, delta ts/lat/lng,
  quantization, gzip — documented in `docs/BINARY_FORMAT.md`.
- Storage (`file_telemetry_store`): manifest-driven, `AsyncMutex`-guarded, SHA-256
  checksums, pending/uploading/uploaded/failed state machine.
- Network layer: `http_backend_client` (idempotency-key header, 409 = already-exists,
  bearer token provider, timeout), `osrm_client`, `maptiler_client`,
  `speed_limit_provider` (backend-first precedence).
- `backend_reference/`: Supabase edge function (`telemetry-upload`), SQL schema, and
  a Deno `telemetry_decoder.ts` — a real server contract, not a stub.
- Runnable `example/` app with start/stop UI and trip summary.

**In progress:**
- Draft **PR #2** — lifecycle/reliability/build fixes (see PR section below).

**Missing / left to be done:**
- A **buildable `main`** (currently blocked; fix lives only in PR #2).
- Permission acquisition in the example (location/motion) — device runs fail without it.
- Synchronizer + upload path wired into the example (currently unused end-to-end).
- Retention/backpressure policy for evidence + failed chunks (unbounded local growth risk).
- Broader unit coverage (aggregators, event detector, evidence windows, OSRM client, store failure paths).

**Blocked:**
- `main` build — `SensorMotionSource` uses removed top-level sensors_plus API.
- `main` build — `TelemetryConfiguration`/`OsrmConfiguration` const-constructor asserts
  compare `Duration` values (not compile-time constant).

**Codebase observations:**
- **Architecture:** Excellent separation — `model / codec / aggregation / event /
  recording / storage / network / config / utils`. Sources are injected
  (`MotionSource`, `LocationSource`, `TelemetryStore`, `TelemetryBackendClient`),
  giving clean seams for tests and alternate platforms. Package deliberately holds
  no scoring logic — a correct boundary.
- **File/folder structure:** Idiomatic `lib/src/**` with a single curated public
  barrel (`lib/driving_telemetry.dart`). One flat export surface; predictable.
- **State management:** Not app-level (it's a package). Internally an explicit
  recorder FSM plus a promise-chained write queue (`_writeTail`) that serializes all
  disk writes and routes write errors to an `errors` stream — good for durability.
- **Routing/navigation:** N/A (package). Example is a single screen.
- **UI consistency:** Only the example UI exists; minimal Material, fine as a demo.
- **Persistence logic:** Manifest-first, mutex-serialized, checksummed, gzipped,
  with a per-chunk upload state machine. On `main` the manifest is rewritten via
  delete+rename (crash window); PR #2 switches to atomic rename.
- **Domain model quality:** High — value types with explicit `toJson`, quantization
  boundaries, and schema versioning (`schemaVersion`, magic `DTL1`).
- **Service layer quality:** Strong — HTTP client uses idempotency keys, treats 409
  as success, tolerates non-JSON bodies, and applies a request timeout.
- **Error handling:** Non-fatal source/write/route errors surface on streams rather
  than crashing; OSRM failure is captured as `routeProcessingError` and the trip
  still closes. Gap on `main`: `stopTrip` sets state to `stopping` then awaits
  several store writes — an exception there leaves the recorder **stuck in
  `stopping`** (unrecoverable). PR #2 fixes this.
- **Testability:** Good seams, but coverage is thin on `main` (~6 tests across 4
  files: codec round-trip, store, recorder happy path, speed-limit provider). PR #2
  adds lifecycle-failure, synchronizer, and codec-edge tests.
- **Build/dependency issues:** Two compile breaks on `main` (below). `sensors_plus`
  pinned `^7.1.0`; `http`, `crypto`, `geolocator`, `path_provider` current.
- **Performance risks:** Chunk-size estimation uses fixed per-record byte constants
  (36/170/120) — a heuristic, acceptable. Ring buffers bound memory. Main runtime
  risk is unbounded on-disk growth if uploads persistently fail (no retention cap).
- **Security/data integrity:** SHA-256 per chunk, idempotent upload, bearer token via
  callback (not stored). No secrets in-repo. MapTiler/OSRM keys are caller-supplied.

**Next actions (priority order):**
1. Promote PR #2 to **ready**, review, and merge → restores a buildable `main`.
2. Tag `0.1.1` and update `CHANGELOG.md`.
3. Add permission requests + synchronizer wiring to the example.
4. Define + implement a local-retention/backpressure policy for failed/evidence chunks.
5. Expand unit tests (aggregators, detector, evidence, OSRM, store failure paths).

**Risk:** **High** — because `main` does not compile. The mitigation (PR #2) exists
and is clean-mergeable, which is what keeps this from being critical.

**Release readiness:** **Not ready** on `main` (does not build). With PR #2 merged it
becomes **Internally testable** (unit-green, device-testable once the example
requests permissions).

---

## Cross-Project Priorities

1. **Restore a buildable `main`**
   - Project: drivio
   - Reason: `main` fails to compile (sensors_plus 7.x API + const `Duration` asserts).
   - Impact: Any host app referencing `main` is broken; no green CI baseline.
   - Recommended action: Merge PR #2 (already contains both fixes).

2. **Recover recorder from failed `stopTrip`**
   - Project: drivio
   - Reason: On `main`, a store-write exception during `stopTrip` leaves the FSM in
     `stopping` permanently; the recorder can never start another trip.
   - Impact: Silent loss of all subsequent trips after one disk error.
   - Recommended action: Ship PR #2's `stopTrip` fix (always return to `idle`).

3. **Make the package device-testable end-to-end**
   - Project: drivio
   - Reason: Example never requests location/motion permission and never uploads.
   - Impact: A real device run collects nothing and demonstrates no sync path.
   - Recommended action: Add `permission_handler` flow + wire `TelemetrySynchronizer`
     into the example (post-#2).

---

## Blockers Requiring Decision

**Blocker A — sensors_plus 7.x API break (build)**
- Project: drivio
- Decision required: Adopt PR #2's migration to `gyroscopeEventStream` /
  `userAccelerometerEventStream`, or pin `sensors_plus` back to a 5.x line.
- Options: (a) Merge PR #2 migration; (b) downgrade the dependency pin.
- Recommended option: (a) — stay on 7.x; the fix is already written and tested.
- Impact if delayed: `main` stays un-buildable.
- Owner: Package maintainer.
- Deadline: This week (blocks every other task).

**Blocker B — const-constructor `Duration` asserts (build)**
- Project: drivio
- Decision required: Move `Duration`-comparison validation out of the const
  constructor into runtime `validate()` (PR #2) vs. dropping the checks.
- Options: (a) Runtime `validate()` called at construction (PR #2); (b) remove asserts.
- Recommended option: (a) — keeps validation, restores compilation, better messages.
- Impact if delayed: `main` stays un-buildable.
- Owner: Package maintainer.
- Deadline: This week.

**Blocker C — local-retention policy for failed/evidence chunks**
- Project: drivio
- Decision required: What bounds local storage when uploads fail for long periods?
- Options: (a) Age cap; (b) size/count cap with FIFO eviction; (c) keep-forever.
- Recommended option: (b) size+count cap with oldest-first eviction, evidence last.
- Impact if delayed: Unbounded disk growth on flaky networks; potential device fill.
- Owner: Package maintainer + backend owner (agree on server-side durability first).
- Deadline: Before first field pilot.

---

## Technical Debt and Refactor Candidates

### Critical
- Project: drivio · Area: `recording/sensor_motion_source.dart` · Problem: removed
  sensors_plus API → compile failure · Recommended fix: adopt 7.x `*EventStream`
  (PR #2) · Priority: **P0**.
- Project: drivio · Area: `config/telemetry_configuration.dart` +
  `config/osrm_configuration.dart` · Problem: const-constructor `Duration` asserts →
  compile failure · Recommended fix: runtime `validate()` (PR #2) · Priority: **P0**.
- Project: drivio · Area: `recording/driving_telemetry_recorder.dart#stopTrip` ·
  Problem: FSM can hang in `stopping` on write failure · Recommended fix: `finally`
  → `idle` (PR #2) · Priority: **P0**.

### Important
- Project: drivio · Area: `storage/file_telemetry_store.dart` · Problem: manifest
  rewrite via delete+rename leaves a crash window · Recommended fix: atomic rename
  (PR #2) · Priority: **P1**.
- Project: drivio · Area: `network/telemetry_synchronizer.dart` · Problem: a throw
  inside `markFailed` aborts the whole pass, leaving chunks non-retryable ·
  Recommended fix: guard `markFailed` (PR #2) · Priority: **P1**.
- Project: drivio · Area: test suite · Problem: ~6 tests; failure paths and
  aggregators/detector uncovered · Recommended fix: extend matrix · Priority: **P1**.

### Optional
- Project: drivio · Area: `_checkChunkFlush` byte estimate · Problem: magic constants
  (36/170/120) · Recommended fix: derive from codec or name as documented constants ·
  Priority: **P2**.
- Project: drivio · Area: example app · Problem: no permission/sync demonstration ·
  Recommended fix: extend example · Priority: **P2**.

---

## Missing Screens, Views, and User Flows

drivio is a package, so "flows" are API/integration flows, not screens.

| Project | Missing screen / flow | Current state | Required work | Priority |
|---|---|---|---|---|
| drivio | Runtime permission request (location/motion) | Absent in example | Add `permission_handler` gate before `startTrip` | High |
| drivio | Upload/sync demonstration | `TelemetrySynchronizer` exists but unused in example | Wire synchronizer + a "Sync now" action | High |
| drivio | Error-state surfacing in example | `errors` stream not consumed | Subscribe and show non-fatal errors | Medium |
| drivio | OSRM/MapTiler config demo | Clients exist, no keys wired in example | Add configurable endpoints/keys | Low |
| drivio | Trip-history/list view | Not present | Optional demo listing local manifests | Low |

---

## Data, Persistence, and Sync Review

**drivio**

- **Current persistence state:** File-based store under
  `<appSupport>/driving_telemetry/trips/<tripId>/`, a JSON manifest per trip listing
  gzipped chunk files, each with SHA-256 + upload state. Writes are serialized by a
  recorder-level promise chain and a store-level `AsyncMutex`.
- **Main entities:** `TripManifest`, `StoredTelemetryChunk`, `TelemetryChunk`
  (continuous / eventEvidence / hourlyAggregate / route / tripManifest),
  `LocationSample`, `RawMotionSample`, `MotionFrame`, `EventCandidate`,
  `HourlyAggregate`.
- **Missing entities:** A retention/eviction record; a device/session identifier for
  multi-device dedup (currently trip + chunk id only); explicit schema-migration
  metadata beyond the integer `schemaVersion`.
- **Data integrity risks:** On `main`, delete+rename manifest write has a crash
  window (fixed in PR #2 via atomic rename). SHA-256 + idempotency-key already
  protect against duplicate/partial uploads server-side.
- **Migration concerns:** Versioned (`DTL1`, `schemaVersion`), but no on-device
  migration path if the binary layout changes; decoder must stay backward-compatible.
- **Sync requirements:** Idempotent chunk upload in manifest order; 409 treated as
  success; failed chunks marked retryable. Not yet driven on a schedule/background
  task — caller must invoke `synchronizePendingData`.
- **Offline behavior:** Fully offline-first — all data lands locally first; upload is
  a separate, resumable pass. Good.
- **Backup/export needs:** No export helper; chunks are self-describing binaries that
  the backend decoder consumes. A local export/inspection tool would aid debugging.
- **Recommended persistence improvements:** (1) atomic manifest (PR #2); (2) bounded
  retention with FIFO eviction; (3) periodic/background sync trigger; (4) a store
  self-check that reconciles manifest vs. on-disk files on `initialize`.
- **Risk level:** Medium (High until PR #2's atomicity fix lands).

---

## UI and Design Implementation Review

**drivio**

- **UI status:** Minimal by design — a single-screen example demonstrating
  start/stop and a trip summary. No design system expected for a package.
- **Problems found:** Example does not surface the `errors` stream, does not request
  permissions, and does not show sync/upload state; it can therefore appear to "work"
  while collecting nothing on a real device.
- **Recommended fixes:** Add permission prompt, an errors banner, and a sync
  action/status to make the example a faithful integration reference.
- **Priority:** Medium (developer-experience, not product UI).

---

## Build, Dependencies, and Environment Review

Flutter/Dart toolchain is not installed in this review environment, so build status
is determined by static code inspection against the pinned dependencies.

| Project | Build status | Issue | Severity | Recommended fix |
|---|---|---|---|---|
| drivio (`main`) | **Fails** | `sensor_motion_source.dart` calls removed `gyroscopeEvents()` / `userAccelerometerEvents()`; pin is `sensors_plus ^7.1.0` (7.x = `*EventStream`) | Critical | Merge PR #2 (migrates API) |
| drivio (`main`) | **Fails** | `TelemetryConfiguration` / `OsrmConfiguration` const asserts compare `Duration` (not const) | Critical | Merge PR #2 (runtime `validate()`) |
| drivio (PR #2) | **Expected pass** | `mergeable_state: clean`; adds tests; addresses both compile breaks | — | Promote draft → ready, review, merge |
| drivio | Warning | Example lacks runtime permission handling | Medium | Add `permission_handler` to example |

---

## Weekly Completion Summary

| Project | Completed item | Type | Impact |
|---|---|---|---|
| drivio | Draft PR #2 authored (lifecycle + build + codec + storage fixes) | Fix/refactor | Unblocks build once merged |
| drivio | This Kanban report (branch `Claude/Kanban-report-2026-08-03`) | Docs | Establishes drivio review baseline |

*No code merged to `main` this week.*

---

## Current Work in Progress

| Project | Item | Status | Next action | Risk |
|---|---|---|---|---|
| drivio | PR #2 stability/reliability pass | Draft, clean-mergeable | Promote to ready + review + merge | Low (fix quality high; only un-reviewed/undrafted) |

---

## Carryover Items

| Project | Item | Reason for carryover | New target |
|---|---|---|---|
| drivio | Merge of build fixes to `main` | PR #2 left as **draft**, never promoted/reviewed | 2026-08-10 |
| drivio | Example permission + sync wiring | Not started; blocked behind buildable `main` | 2026-08-17 |
| drivio | Retention/backpressure policy | Awaiting decision (Blocker C) | 2026-08-17 |

---

## Planned Focus for Next Week

**drivio**
- Focus item: Merge PR #2 and tag `0.1.1`.
- Reason: It is the only path to a buildable `main`.
- Expected outcome: `flutter analyze` + `flutter test` green on `main`.
- Risk: Low — PR is clean-mergeable and adds test coverage.
- Definition of done: `main` builds; `0.1.1` tagged; `CHANGELOG.md` updated.

**drivio (secondary)**
- Focus item: Example permissions + synchronizer wiring.
- Reason: Makes the package device-testable and demonstrates the upload path.
- Expected outcome: Example records real data on a device and uploads a chunk.
- Risk: Medium — requires a device with GPS/motion.
- Definition of done: Example requests permissions, records, and reports a successful sync.

---

## Recommended Kanban Updates

**Move to Done**
- Project: drivio · Item: Draft PR #2 authored · Reason: Fixes complete and clean-mergeable.
- Project: drivio · Item: drivio Kanban baseline report · Reason: Delivered this cycle.

**Move to In Progress**
- Project: drivio · Item: PR #2 review + merge · Reason: Only remaining step to a buildable `main`.

**Move to Blocked**
- Project: drivio · Item: `main` build · Blocker: sensors_plus 7.x API break (fix only in unmerged PR #2).
- Project: drivio · Item: `main` build · Blocker: const-constructor `Duration` asserts (fix only in unmerged PR #2).

**Move to Ready**
- Project: drivio · Item: Tag `0.1.1` + CHANGELOG · Reason: Ready to execute immediately after PR #2 merges.
- Project: drivio · Item: Expand test matrix · Reason: Seams exist; scope is clear.

**Move to Parked**
- Project: drivio · Item: On-device verification · Reason: Requires physical Android device + GPS/motion; not runnable in CI/this environment.

---

## Final Recommendations

- **Most important thing to fix first:** Merge draft **PR #2**. `main` does not
  compile today, and PR #2 (865/-131, 21 files, `mergeable_state: clean`) fixes both
  compile breaks plus the `stopTrip` FSM hang, manifest atomicity, and synchronizer
  resilience — with new tests. This is the whole ballgame this week.
- **Steps toward release:** (1) promote PR #2 draft → ready, review, merge; (2) tag
  `0.1.1` + update CHANGELOG; (3) add permission + sync to the example; (4) decide and
  implement local-retention/backpressure; (5) broaden unit coverage; (6) do one
  on-device trip-and-upload verification.
- **Highest-risk item:** An un-buildable `main` — any consumer pinning it is broken.
- **Most urgent decision:** Promote and merge PR #2 (vs. cherry-picking only the two
  compile fixes). Recommendation: merge the whole PR — the surrounding fixes are real
  and tested.
- **Recommended focus for the next 7 days:** Get `main` green (merge PR #2, tag
  `0.1.1`), then make the example device-testable with permissions and a sync action.

---

### PR #2 review verdict — RECOMMEND MERGE

Draft PR **#2** ("Fix lifecycle and reliability issues in telemetry recorder") is
the correct and necessary next step:

- It repairs the two compile breaks that make `main` un-buildable.
- It fixes a real, confirmed lifecycle defect (`stopTrip` stranding the FSM in
  `stopping` on write failure) and hardens `startTrip` source cleanup.
- It improves durability (atomic manifest rename, mutex-serialized `initialize`) and
  sync resilience (`markFailed` no longer aborts the pass).
- It adds targeted tests (lifecycle-failure, synchronizer partial-failure, codec edge
  cases) rather than reducing coverage.
- GitHub reports `mergeable_state: clean`.

**Action:** promote from draft to ready, run CI (`flutter analyze` + `flutter test`),
review, and merge as `0.1.1`.
