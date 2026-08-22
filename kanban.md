# Weekly Engineering Kanban Report

**Project under deep review:** `drivio` — the `driving_telemetry` Flutter package
**Report date:** 2026-08-22
**Reviewed refs:** `main` @ `3df62f4` · draft PR **#2** `claude/codebase-stability-quality-tz5e6t` @ `d4a9d76` (unchanged since 2026-07-19)
**Prepared by:** Engineering review (automated, code-aware)

> **Rotation note.** Every repository in the portfolio now carries a Kanban report on
> `main` or in an open PR, so the selection rule falls through to *oldest existing
> report*. `drivio` (report PR #3, 2026-08-03 02:04 UTC) is the oldest, edging
> `djib-dial` (2026-08-03 07:50 UTC) on the same day. Last cycle's pick
> (`Airness_next`, 2026-08-21) is excluded.
>
> **Verification limits.** No Flutter/Dart SDK is available in this environment, so
> `flutter analyze`, `flutter test` and `flutter build` could **not** be executed.
> Build claims below are derived from reading the source against the pinned
> dependency APIs, and are labelled as such. The repository has **no CI**, so no
> automated check has ever run against `main` or against PR #2 either.

---

## Executive Summary

- **Active projects:** 18 repositories in the portfolio; **1 deep-reviewed this cycle** (`drivio`).
- **Overall portfolio status:** `drivio` is a well-architected but **pre-alpha** telemetry
  *package* (not an app), version `0.1.0`. Its `main` branch does not compile. A clean,
  mergeable draft PR (#2) fixes the compile breaks plus a cluster of lifecycle and
  data-integrity bugs — and has sat untouched for **five weeks**.
- **Completed this week:** Nothing merged to `main`. No commits on any branch since
  2026-07-19. This is a **stalled** project, not a slow one.
- **Work currently in progress:** Nominally PR #2. In practice, no active work.
- **Main blockers:** (1) `main` does not compile — `sensors_plus` 7.x API + `Duration`
  comparisons inside const-constructor asserts. (2) PR #2 is still marked **draft**, so
  nothing can merge. (3) No CI exists to prove any of it.
- **Highest-risk item:** **The package cannot record in the background.** There is zero
  foreground-service, wakelock, or background-isolate code anywhere in `lib/`. A driving
  telemetry recorder that dies when the screen locks does not do its job, and no amount of
  codec polish changes that. This is a larger gap than the build break and was not
  identified in the previous report.
- **Next release target:** `0.1.1` = merge of PR #2 — the first genuinely buildable tag.
  This is an *internal* milestone, not a shippable one.
- **Key decision required:** Commit to a background-execution strategy (Android foreground
  service vs. host-app responsibility) before any further recorder work. Everything
  downstream — permissions, battery, trip resume, manifest entries — hangs off that answer.
- **Recommended focus for next week:** Promote and merge PR #2, add a two-job CI workflow,
  fix the 409-handling data-loss bug, then decide the background-execution question.

---

## Portfolio Kanban Snapshot

Counts scope the `drivio` work items surfaced by this review. Sibling projects are tracked
only by report coverage (see *Portfolio rotation status* below).

| Status | Count | Notes |
|---|---:|---|
| Inbox | 4 | Background execution · axis calibration · retention policy · trip-resume semantics |
| Ready | 3 | Add CI workflow · fix 409 handling · generate `example/` platform folders |
| In Progress | 0 | Nothing has moved in 5 weeks — PR #2 is stalled, not in progress |
| Review / Testing | 1 | PR #2 — clean, mergeable, needs draft→ready promotion |
| Blocked | 3 | `main` build (sensors_plus 7.x) · `main` build (const `Duration` asserts) · device testing (no platform folders) |
| Done | 0 | No merges to `main` this week |
| Parked | 2 | On-device verification (needs Android device + SIM/GPS) · MapTiler/OSRM production keys |

### Portfolio rotation status

| Repo | Latest Kanban report | Where |
|---|---|---|
| drivio | 2026-08-03 | PR #3 (open) — **this cycle's target** |
| djib-dial | 2026-08-03 | PR #3 (open) |
| BoutiSign | 2026-08-04 | PR #22 (open) |
| kyoto | 2026-08-05 | PR #20 (open) |
| shax_game | 2026-08-06 | PR #7 (open) |
| airness | 2026-08-07 | PR #20 (open) |
| djibVPN | 2026-08-08 | PR #14 (open) |
| PointS | 2026-08-09 | PR #13 (open) |
| pHarmaDjib_Next | 2026-08-10 | PR #11 (open) |
| red-sea-news | 2026-08-11 | PR #184 (open) |
| pHarmaDjib | 2026-08-11 | merged to `main` |
| clipaid | 2026-08-12 | PR #13 (open) |
| djibouti-motors | 2026-08-13 | merged to `main` |
| myDrive | 2026-08-17 | PR #6 (open) |
| ussd_dj | 2026-08-18 | PR #11 (open) |
| automotivate | 2026-08-19 | PR #13 (open) |
| PointS_portal | 2026-08-20 | PR #6 (open) |
| Airness_next | 2026-08-21 | PR #14 (open) — last cycle |

**Portfolio-level observation:** 16 of 18 report PRs are still open. These reports are being
produced but not consumed. Either merge them on delivery or stop opening PRs for them —
an unread queue of 16 documents is worse than none.

---

## Project Status

### 1. drivio — `driving_telemetry`

**Current state:**

A cleanly layered Flutter **package** (not an app) that collects ~25 Hz motion and ~1 Hz GPS,
condenses to one-second statistical frames, detects candidate events, retains short
high-resolution evidence windows around them, delta-encodes and gzips versioned binary chunks
(magic `DTL1`), persists them atomically with SHA-256 checksums, matches the route through
OSRM after the trip, and uploads chunks idempotently to a backend. By deliberate design it
performs **no scoring** — that is the backend's job, and the `backend_reference/` directory
ships a real Supabase edge function, SQL schema with RLS, and a Deno decoder to prove the
contract.

The architecture is genuinely good. The project is nonetheless **not usable today**, for two
independent reasons: `main` does not compile, and even once it does, the package cannot record
while the app is backgrounded.

**Completed (verified by reading the code):**

- Full domain model — `location_sample`, `raw_motion_sample`, `motion_frame`, `event_candidate`,
  `hourly_aggregate`, `telemetry_chunk`, `trip_manifest`, `trip_result`, `osrm_match_result`,
  `effective_speed_limit`, `street_context`, `axis_statistics`, `vector3_value`.
- Recorder orchestration with an explicit FSM (`idle → starting → recording → stopping → disposed`),
  a serialized write tail (`_writeTail`), time-bounded ring buffers, evidence capture, chunk
  flushing on duration or estimated byte size, and haversine distance with plausibility gating
  (`≤10 s` gap, `≤1.25×` max plausible speed).
- Codec (`telemetry_binary_codec` + `compact_binary`): varint, ZigZag, delta timestamps,
  delta lat/lng, integer quantization, gzip — documented in `docs/BINARY_FORMAT.md`.
- Storage (`file_telemetry_store`): manifest-driven, `AsyncMutex`-serialized, per-chunk SHA-256,
  and a `pending → uploading → uploaded / failed` state machine.
- Network layer: `http_backend_client` (idempotency key, bearer-token callback, request timeout,
  tolerates non-JSON error bodies), `osrm_client`, `maptiler_client`, `speed_limit_provider`
  with backend-first precedence.
- `OnlineStatistics` implements Welford's algorithm plus Chan's parallel-merge for combining
  pre-condensed statistics — numerically correct, and the strongest single file in the repo.
- **Location permissions are already handled in the package** (`GeolocatorLocationSource`
  checks `isLocationServiceEnabled`, then `checkPermission`/`requestPermission`). *This
  corrects the previous report, which listed permission handling as missing — the Dart-side
  work is done; only the platform manifest entries are absent.*
- `backend_reference/`: Supabase edge function with auth, checksum verification, storage
  upload, idempotent insert, and trip-manifest application; SQL schema with RLS policies and
  a private storage bucket.

**In progress:**

- Nothing, in practice. Draft PR #2 (865 additions / 131 deletions across 21 files) is
  `mergeable_state: clean` and has not been touched since 2026-07-19.

**Missing / left to be done:**

1. **Background execution** — no foreground service, no wakelock, no background isolate,
   no `WidgetsBindingObserver`. Verified by grep: zero matches across `lib/` and `example/`.
2. **Axis calibration** — `VehicleAxisMapping.isCalibrated` exists and gates event confidence
   (0.85 vs 0.55), but **no code path can ever set it to `true`**. There is no calibration
   routine anywhere. Every event the package will ever emit ships at the low-confidence tier.
3. **A buildable `main`** — fixed only inside unmerged PR #2.
4. **CI** — no `.github/` directory at all. Nothing runs `flutter analyze` or `flutter test`.
5. **Runnable example** — `example/` contains only `lib/` and `pubspec.yaml`. No `android/`,
   no `ios/`. It cannot be `flutter run`-ed on any device.
6. **Retention / backpressure** — `TelemetryStore` has no `deleteTrip`. Completed trips
   accumulate on disk forever, and `markFailed` increments a `retryCount` that **nothing ever
   reads**, so a permanently-rejected chunk is retried on every pass, forever.
7. **Trip resume after crash** — a trip whose `stopTrip` fails is left `status: 'recording'`
   in the manifest with no recovery path; the recorder clears `_tripId` and returns to `idle`.
8. **Test coverage of the core domain** — `candidate_event_detector.dart` is the largest file
   in the package (317 lines) and the reason the package exists. It has **zero** tests on
   `main` and PR #2 adds none. Same for both aggregators and `OnlineStatistics`.

**Blocked:**

- `main` build — `SensorMotionSource` calls `gyroscopeEvents(...)` / `userAccelerometerEvents(...)`,
  removed in `sensors_plus` 7.x in favour of `gyroscopeEventStream` / `userAccelerometerEventStream`.
  Fixed only in PR #2.
- `main` build — `TelemetryConfiguration` and `OsrmConfiguration` are `const` constructors whose
  asserts compare `Duration` values (`assert(motionSamplingPeriod > Duration.zero)`).
  `Duration.operator >` is not const-evaluable, so every `const` invocation is a compile error —
  including `example/lib/main.dart:25` (`final configuration = const TelemetryConfiguration();`)
  and the README's own integration snippet. Fixed only in PR #2.
- Device testing — blocked on the missing `example/android` and `example/ios` platform folders.

**Codebase observations:**

- **Architecture.** Excellent. `model / codec / aggregation / event / recording / storage /
  network / config / utils`, with `MotionSource`, `LocationSource`, `TelemetryStore` and
  `TelemetryBackendClient` all injected. Clean seams; the package holds no scoring logic,
  which is the right boundary.
- **File and folder structure.** Idiomatic `lib/src/**` behind a single curated barrel
  (`lib/driving_telemetry.dart`). Predictable and complete.
- **State management.** N/A at app level. Internally: an explicit recorder FSM plus a
  promise-chained write queue that serializes all disk writes and routes write failures to an
  `errors` stream rather than crashing. Sound design.
- **Routing and navigation.** N/A (package). The example is one screen.
- **UI consistency.** Only the example UI exists — minimal Material, adequate as a demo, and
  currently uncompilable.
- **Persistence logic.** Manifest-first, mutex-serialized, checksummed, gzipped. On `main`,
  `_atomicWriteString`/`_atomicWriteBytes` do **delete-then-rename**: a crash in that window
  leaves the manifest gone, which makes the entire trip's upload queue unreadable and silently
  skipped by `listPendingChunks`. PR #2 switches to rename-over-destination. The PR's
  `FileSystemException` fallback still deletes the destination before retrying, so a genuine
  I/O failure can still lose the manifest — narrow, but real, and unchanged from `main`.
- **Domain model quality.** High. Value types with explicit `toJson`, quantization boundaries
  stated in units, schema versioning (`schemaVersion` + `DTL1` magic).
- **Service layer quality.** Strong shape, one serious contract bug — see *409 handling* below.
- **Error handling.** Non-fatal source, write and route errors surface on streams; OSRM failure
  is captured as `routeProcessingError` and the trip still closes. On `main`, `stopTrip` sets
  state to `stopping` then awaits several store writes — an exception there strands the recorder
  in `stopping` permanently. PR #2 wraps the body in `try/finally` and fixes it. Note that PR #2
  also changes `errors` from `addError` to `add` for source errors: any consumer using
  `errors.listen(onError:)` silently stops receiving them. It is documented in the CHANGELOG
  and arguably the correct contract for a `Stream<Object>`, but it is a breaking change shipped
  under a patch version bump.
- **Testability.** Good seams, thin coverage: 6 tests across 4 files on `main`. PR #2 adds
  lifecycle, synchronizer and codec-edge tests. The event detector remains untested either way.
- **Build and dependency issues.** Two compile breaks on `main` (above). Dependency pins are
  current: `sensors_plus ^7.1.0`, `geolocator ^14.0.3`, `http ^1.6.0`, `crypto ^3.0.6`,
  `path_provider ^2.1.6`, `flutter_lints ^5.0.0`. `analysis_options.yaml` enables
  `public_member_api_docs`, which `main` violates (undocumented enum members) — PR #2 fixes all
  of them.
- **Performance risks.** Chunk-size estimation uses fixed per-record byte constants
  (36 / 170 / 120) — a heuristic, acceptable. Ring buffers bound memory. The real runtime risk
  is unbounded disk growth when uploads fail persistently.
- **Security and data integrity.** Per-chunk SHA-256, idempotent upload, bearer token supplied
  by callback rather than stored, no secrets in-repo, RLS on both backend tables and a private
  storage bucket. Two integrity concerns are called out under *Critical* technical debt below.

**Next actions (priority order):**

1. Promote PR #2 draft → ready and merge. It restores a buildable `main` and fixes real bugs.
2. Add `.github/workflows/ci.yml` running `flutter analyze` + `flutter test` on push and PR.
3. Fix the 409 handling in `HttpTelemetryBackendClient` (data-loss bug — see below).
4. Decide the background-execution strategy, then implement or document it.
5. Generate `example/android` and `example/ios`; add the location and sensor manifest entries.
6. Add a `deleteTrip` API and a retention policy; make `retryCount` actually cap retries.
7. Write tests for `CandidateEventDetector`, both aggregators, and `OnlineStatistics`.
8. Implement axis calibration, or delete `isCalibrated` and stop pretending it can be true.

**Risk:** **High.**
Three compounding reasons: `main` does not compile; the fix has been sitting unmerged for five
weeks with no CI to validate it; and the package is missing the background-execution capability
that its entire purpose depends on. The mitigation for the first two exists and is clean —
that is the only thing keeping this out of Critical.

**Release readiness:** **Not ready.**
`main` does not build. With PR #2 merged it reaches **Internally testable** (unit-testable,
analyzable) but *not* device-testable, because the example has no platform folders and the
recorder has no background story.

---

## Cross-Project Priorities

1. **Merge PR #2 and restore a buildable `main`**
   - **Project:** drivio
   - **Reason:** `main` fails to compile on two independent errors. Any host app pinning the
     `main` ref is broken today, and the package has been in this state since 2026-07-18.
   - **Impact:** Total — no build, no tests, no integration, no downstream consumer.
   - **Recommended action:** Promote PR #2 from draft to ready, review the codec-clamping
     semantics (see debt item C3), merge, tag `0.1.1`.

2. **Fix the HTTP 409 data-loss path**
   - **Project:** drivio
   - **Reason:** `HttpTelemetryBackendClient` treats HTTP 409 as *"already exists → accepted"*.
     The reference backend returns 409 for a **checksum conflict** — a genuine rejection — and
     returns 200 with `alreadyExisted: true` for the benign duplicate case. So the client marks
     a rejected chunk `uploaded` and, for continuous chunks (`deleteUploadedContinuousChunks`
     defaults to `true`), **deletes the local file**. The telemetry is gone and the backend
     never stored it.
   - **Impact:** Silent, permanent, unrecoverable data loss under exactly the condition the
     checksum check exists to catch.
   - **Recommended action:** Treat 409 as a failure. Rely on the documented 200 +
     `alreadyExisted: true` response for idempotent duplicates. Add a test asserting a 409
     leaves the chunk `failed` and the file on disk.

3. **Decide and implement background execution**
   - **Project:** drivio
   - **Reason:** No foreground service, wakelock, or background isolate exists. On Android,
     `geolocator` streams need a foreground service and `ACCESS_BACKGROUND_LOCATION`;
     `sensors_plus` streams stop when the app is suspended.
   - **Impact:** The package only records while the user actively stares at the screen while
     driving. That is both useless and unsafe as a product behaviour.
   - **Recommended action:** Decide the ownership boundary (see *Blockers Requiring Decision*),
     then either ship a foreground-service integration or document the host-app requirement
     explicitly in the README and provide a worked example.

---

## Blockers Requiring Decision

**1. Background execution — package responsibility or host-app responsibility?**

- **Project:** drivio
- **Decision required:** Does `driving_telemetry` own keeping the process alive during a trip,
  or does it document the requirement and leave it to the host app?
- **Options:**
  - **(a)** Package ships an Android foreground service + iOS background-location mode, with
    the notification text configurable. Heavier dependency surface, larger platform footprint.
  - **(b)** Package stays platform-thin; README documents exactly what the host must configure,
    and `example/` demonstrates it end to end.
  - **(c)** Defer — continue as a foreground-only recorder.
- **Recommended option:** **(b)**. It preserves the package's clean, injectable design and
  matches the boundary already drawn for scoring; a worked example carries most of (a)'s value
  at a fraction of the cost. Option (c) is not viable — it makes the package unfit for purpose.
- **Impact if delayed:** Every recorder change made before this decision may need reworking;
  device testing cannot begin; the package cannot be integrated by any real app.
- **Owner:** Package owner / lead engineer.
- **Deadline:** Before any further recorder work — target 2026-08-29.

**2. Axis calibration — implement or remove?**

- **Project:** drivio
- **Decision required:** `isCalibrated` gates event confidence but nothing can set it `true`.
- **Options:**
  - **(a)** Implement a calibration routine (detect gravity vector at rest, derive forward axis
    from GPS heading under sustained acceleration) and expose it as a public API.
  - **(b)** Remove `isCalibrated`, document the required mount orientation, and fix the
    confidence values at the calibrated tier.
  - **(c)** Leave as is.
- **Recommended option:** **(a)**. Without it, detection accuracy for a phone in a pocket or a
  cup holder is guesswork, and every event ships at 0.42–0.58 confidence — which pushes the
  problem onto the backend rather than solving it. (b) is an acceptable interim if scope is tight.
  (c) ships a permanently dead flag through the wire format.
- **Impact if delayed:** Event data of low and unimprovable quality; the backend cannot
  distinguish "low confidence because uncalibrated" from "low confidence because ambiguous".
- **Owner:** Package owner.
- **Deadline:** 2026-09-05.

**3. Local retention and backpressure policy**

- **Project:** drivio
- **Decision required:** What bounds on-device telemetry storage?
- **Options:** Age cap (delete trips older than N days) · size cap (evict oldest above N MB) ·
  retry cap (drop a chunk after N failed uploads, using the `retryCount` already recorded) ·
  any combination.
- **Recommended option:** All three, with defaults of 14 days / 200 MB / 10 retries, all
  configurable via `TelemetryConfiguration`. Add `TelemetryStore.deleteTrip`.
- **Impact if delayed:** A device that is offline for a long stretch fills its storage and the
  host app is blamed. A permanently-rejected chunk is retried on every pass forever.
- **Owner:** Package owner.
- **Deadline:** 2026-09-05.

**4. Trip resume semantics after a crash or failed stop**

- **Project:** drivio
- **Decision required:** What happens to a trip left `status: 'recording'` in the manifest?
- **Options:** Auto-close it on next `initialize()` and queue its chunks · expose a
  `recoverInterruptedTrips()` API for the host to call · leave it (current behaviour — orphaned
  forever).
- **Recommended option:** Auto-close on `initialize()`. Note that resuming an *existing*
  `tripId` is currently unsafe: `_nextChunkIndex()` restarts at 0, and the backend schema has
  `unique (trip_id, chunk_index)`, so resumed chunks would collide and fail permanently. Either
  persist the chunk index in the manifest or forbid resume explicitly.
- **Impact if delayed:** Silent telemetry loss on every crash mid-trip.
- **Owner:** Package owner.
- **Deadline:** 2026-09-12.

---

## Technical Debt and Refactor Candidates

### Critical

**C1 — 409 treated as success, local file deleted**
- **Project:** drivio
- **Area:** `lib/src/network/http_backend_client.dart` (upload) ↔
  `backend_reference/supabase/functions/telemetry-upload/index.ts` (checksum conflict)
- **Problem:** The client short-circuits 409 to `accepted: true`; the reference backend returns
  409 only for *"Existing idempotency key has a different checksum"*. The synchronizer then
  marks the chunk uploaded and deletes the local file. Data is lost and never reaches the backend.
- **Recommended fix:** Remove the 409 short-circuit; let it fall through to
  `TelemetryUploadException`. The benign duplicate case is already covered by 200 +
  `alreadyExisted: true`.
- **Priority:** P0 — fix alongside or immediately after PR #2.

**C2 — `main` does not compile**
- **Project:** drivio
- **Area:** `sensor_motion_source.dart`, `telemetry_configuration.dart`, `osrm_configuration.dart`
- **Problem:** Removed `sensors_plus` 7.x top-level stream getters; `Duration` comparisons in
  const-constructor asserts.
- **Recommended fix:** Merge PR #2, which fixes both correctly (stream API migration; asserts
  moved to runtime `validate()` methods called from the recorder and OSRM client constructors).
- **Priority:** P0.

**C3 — Codec clamping silently rewrites timestamps**
- **Project:** drivio
- **Area:** `lib/src/codec/telemetry_binary_codec.dart` (introduced by PR #2)
- **Problem:** PR #2 clamps negative sample-to-sample time deltas to 0 and advances the tracked
  previous timestamp by the clamped delta. The chunk decodes cleanly, but an out-of-order
  sample is silently re-stamped to its predecessor's time. For telemetry feeding backend
  infraction validation, silently altering timestamps is worse than a loud failure.
  This is still an improvement on `main`, which throws away the entire chunk.
- **Recommended fix:** Merge as is (it is strictly better than today), then follow up: sort or
  drop out-of-order samples at the recorder boundary and record a per-chunk
  `outOfOrderSampleCount` so the backend can see when it happened.
- **Priority:** P1 — follow-up to PR #2, not a merge blocker.

**C4 — No CI**
- **Project:** drivio
- **Area:** repository root — no `.github/` directory
- **Problem:** Nothing has ever run `flutter analyze` or `flutter test` automatically. `main`
  shipped two compile errors precisely because nothing checked. PR #2's CHANGELOG claims
  *"`flutter analyze` is clean"* with no evidence and no way to verify it.
- **Recommended fix:** Add a workflow running `flutter pub get`, `flutter analyze --fatal-infos`,
  and `flutter test` on push and PR, for both the package and `example/`.
- **Priority:** P0 — cheapest high-value fix in the repo.

### Important

**I1 — No retry cap; `retryCount` is written but never read**
- **Project:** drivio · **Area:** `telemetry_synchronizer.dart`, `file_telemetry_store.dart`
- **Problem:** `markFailed` increments `retryCount`; nothing consults it. A chunk the backend
  permanently rejects is retried on every pass, forever, burning battery and mobile data.
- **Recommended fix:** Skip chunks above a configurable `maximumUploadAttempts`; expose them
  through a `quarantined` status so the host can surface or discard them.
- **Priority:** P1.

**I2 — `synchronize()` has no concurrency guard**
- **Project:** drivio · **Area:** `telemetry_synchronizer.dart`
- **Problem:** Two concurrent calls (a periodic timer plus a manual trigger) both list the same
  pending chunks and upload them twice. The idempotency key protects the backend; local status
  churns and bandwidth is wasted.
- **Recommended fix:** Guard `synchronize()` with an `AsyncMutex` (already in `utils/`), or
  return the in-flight future.
- **Priority:** P1.

**I3 — No local trip deletion API**
- **Project:** drivio · **Area:** `telemetry_store.dart`
- **Problem:** `deleteChunkFile` removes one file but leaves the manifest entry; nothing ever
  removes a completed trip directory. Storage grows without bound.
- **Recommended fix:** Add `deleteTrip(String tripId)` and wire it to the retention policy from
  decision #3.
- **Priority:** P1.

**I4 — `content-encoding: gzip` on the upload request**
- **Project:** drivio · **Area:** `http_backend_client.dart`
- **Problem:** The body is gzip *content*, not a transfer encoding. If any proxy or edge runtime
  honours the header and decompresses in transit, the edge function's SHA-256 (computed over the
  compressed bytes) mismatches and **every upload returns 422**. Whether it happens is
  environment-dependent, which is exactly what makes it dangerous.
- **Recommended fix:** Drop the header — `content-type: application/octet-stream` already
  describes an opaque binary body. Verify with one real end-to-end upload against a deployed
  Supabase function.
- **Priority:** P1 — must be confirmed before any production upload path.

**I5 — `errors` stream contract changed under a patch version**
- **Project:** drivio · **Area:** `driving_telemetry_recorder.dart` (PR #2)
- **Problem:** Source errors move from `addError` to `add`. Consumers using
  `errors.listen(onError:)` silently stop receiving them.
- **Recommended fix:** Acceptable as is (no known consumers, `publish_to: none`), but document
  it in the README's stream contract, not only the CHANGELOG.
- **Priority:** P2.

**I6 — `_replace` fallback can destroy the manifest**
- **Project:** drivio · **Area:** `file_telemetry_store.dart` (PR #2)
- **Problem:** The `FileSystemException` fallback deletes the destination and retries the
  rename. If the original failure was a genuine I/O error (disk full, permissions), the retry
  fails too — and the good manifest is now gone.
- **Recommended fix:** Only fall back when the exception indicates cross-device or
  unsupported-rename; otherwise rethrow and leave the destination intact.
- **Priority:** P2 (not a regression — `main` is equally exposed).

### Optional

**O1 — Chunk size estimation is a fixed-constant heuristic**
- **Project:** drivio · **Area:** `driving_telemetry_recorder.dart:_checkChunkFlush`
- **Problem:** 36 / 170 / 120 bytes per record are magic numbers that will drift as the codec
  evolves.
- **Recommended fix:** Derive them from a measured encode of a representative chunk, or add a
  test that asserts the estimate stays within ±25% of the real encoded size.
- **Priority:** P3.

**O2 — `example/` is a single stateful widget**
- **Project:** drivio · **Area:** `example/lib/main.dart`
- **Problem:** Demonstrates start/stop only — no synchronizer, no error-stream display, no
  candidate-event display. It does not exercise the paths most likely to break.
- **Recommended fix:** Extend once platform folders exist (see missing-screens table).
- **Priority:** P3.

---

## Missing Screens, Views, and User Flows

`drivio` is a package, so "screens" means the example app and the public API surface a host
app must call.

| Project | Missing screen / flow | Current state | Required work | Priority |
|---|---|---|---|---|
| drivio | Runnable example on a device | `example/` has only `lib/` + `pubspec.yaml` — no `android/`, no `ios/` | `flutter create --platforms=android,ios .`; add location + foreground-service manifest entries and iOS usage strings | **P0** |
| drivio | Upload / sync flow in the example | `TelemetrySynchronizer` and `HttpTelemetryBackendClient` are never constructed anywhere outside tests | Wire a synchronizer with a configurable endpoint and token; add a "Sync now" action and a pending-count display | **P1** |
| drivio | Error state | `recorder.errors` is exposed but the example never listens to it | Subscribe and render the last N errors | **P1** |
| drivio | Loading / in-progress state | Button toggles text only; a slow `stopTrip` (OSRM match + writes) looks frozen | Disable the button and show progress during `starting` / `stopping` | **P2** |
| drivio | Empty state | No "no trips recorded yet" affordance | Add once a trip list exists | **P3** |
| drivio | Trip list / detail view | No way to see previously recorded trips | Add `TelemetryStore.listTrips()` and a list + detail screen in the example | **P2** |
| drivio | Calibration flow | `isCalibrated` can never become `true` | Depends on decision #2 | **P1** |
| drivio | Interrupted-trip recovery | Orphaned `recording` trips are invisible and unrecoverable | Depends on decision #4 | **P1** |
| drivio | Permissions denied path | `GeolocatorLocationSource` throws on denial; the example catches it into a status string | Surface an actionable "open settings" affordance | **P2** |

---

## Data, Persistence, and Sync Review

### drivio

**Current persistence state:**
File-based local store rooted at `<applicationSupport>/driving_telemetry/trips/<tripId>/`, with
a JSON `manifest.json` per trip and gzipped chunk files under `chunks/`. All mutations are
serialized through an `AsyncMutex`; every chunk carries a SHA-256 over its compressed bytes and
a `pending / uploading / uploaded / failed` status. Upload is idempotent, keyed on
`<tripId>:<chunkId>`. The server side (reference implementation) is Supabase Postgres +
private storage bucket, with RLS scoping both tables to `auth.uid()`.

**Main entities:** `TripManifest`, `StoredTelemetryChunk`, `TelemetryChunk` (continuous,
eventEvidence, hourlyAggregate, route, tripManifest), `LocationSample`, `RawMotionSample`,
`MotionFrame`, `TelemetryEventCandidate`, `HourlyTelemetryAggregate`.

**Missing entities:** none at the data level. Missing *operations*: `deleteTrip`, `listTrips`,
and a persisted chunk-index counter for safe trip resume.

**Issues found:**
1. **409 → local delete (C1).** The single most damaging data-integrity bug in the repo.
2. **Manifest write window.** `main` deletes before renaming; a crash there loses the manifest
   and orphans every chunk in that trip. PR #2 fixes the common path; the fallback branch (I6)
   remains exposed.
3. **Unbounded growth (I3).** No retention, no size cap, no trip deletion.
4. **Poison-pill retries (I1).** `retryCount` is recorded and ignored.
5. **Resume collides with the backend schema.** `_nextChunkIndex()` restarts at 0 per recorder
   instance while the backend enforces `unique (trip_id, chunk_index)`.
6. **Stale manifest entries.** `deleteChunkFile` removes the file but leaves the entry;
   `listPendingChunks` then silently skips it. Recoverable, but the manifest stops reflecting disk.
7. **Timestamp rewriting under clamping (C3).**

**Recommended changes:** fix C1 first; add `deleteTrip` + retention; enforce a retry cap;
persist `chunkIndex` in the manifest; mark deleted chunks in the manifest rather than leaving
them pending; add an `outOfOrderSampleCount` field to chunk metadata.

**Offline behaviour:** Good by design — recording is entirely local and never awaits the
network; uploads are a separate, resumable pass. This is the strongest part of the design.

**Backup / export:** None. There is no way to export a trip off-device other than uploading it.
Acceptable for now; worth a `exportTrip(tripId) → File` helper for support and debugging.

**Migration concerns:** `schemaVersion` is embedded in every chunk and validated on decode, and
the backend stores it per row. The forward path is sound. There is no *downgrade* path, and
`docs/BINARY_FORMAT.md` should state that explicitly.

**Risk level:** **High** — driven by C1 and the absent retention policy, not by the design,
which is otherwise above the bar for this stage.

---

## UI and Design Implementation Review

### drivio

**UI status:** Minimal by design — the package ships no UI, and `example/lib/main.dart` is a
single `StatefulWidget` with a status line, one `FilledButton`, and six `Text` rows of trip
summary. It does not currently compile (const-assert break), and it cannot run on a device
(no platform folders).

**Problems found:**
- No loading or disabled state during `starting` / `stopping`; a slow `stopTrip` looks hung.
- Errors are flattened into a status string via `error.toString()` — unreadable for a
  `TelemetryUploadException` or a permission denial.
- The matched-distance row builds a long interpolated string with a `??` fallback inline; it
  will overflow on a narrow screen (no `softWrap` / `overflow` handling, no `Flexible`).
- No theme is set — bare `MaterialApp` defaults; no dark-mode consideration.
- `recorder.errors` and `recorder.candidateEvents` are both exposed and both unused, so the
  example never demonstrates the diagnostic surface the package provides.

**Recommended fixes:** add explicit `starting` / `stopping` states with a disabled button and a
progress indicator; render errors as a typed, readable list; wrap the summary rows in a
`ListView` with proper overflow handling; subscribe to `candidateEvents` and show a live count.

**Priority:** **P2** — real, but strictly behind making the package build and run at all. The
example's job right now is to prove the package works, not to look good.

---

## Build, Dependencies, and Environment Review

| Project | Build status | Issue | Severity | Recommended fix |
|---|---|---|---|---|
| drivio (`main`) | **Fails** (by source inspection; no SDK available to confirm) | `SensorMotionSource` calls `gyroscopeEvents` / `userAccelerometerEvents`, removed in `sensors_plus` 7.x | **Critical** | Merge PR #2 (`gyroscopeEventStream` / `userAccelerometerEventStream`) |
| drivio (`main`) | **Fails** | `Duration` comparisons in const-constructor asserts — breaks every `const TelemetryConfiguration()`, including `example/lib/main.dart:25` and the README snippet | **Critical** | Merge PR #2 (runtime `validate()` methods) |
| drivio (`main`) | Analyzer errors | `public_member_api_docs` is enabled but enum members are undocumented | Medium | Merge PR #2 (all documented) |
| drivio (PR #2) | Expected clean; **unverified** | No CI; no SDK here; the "analyze is clean" claim in the CHANGELOG has never been checked by a machine | **High** | Add the CI workflow, then re-confirm |
| drivio (`example/`) | Cannot run | No `android/` or `ios/` directories | **High** | `flutter create --platforms=android,ios .` plus manifest entries |
| drivio | Runtime gap | No foreground-service / background-execution support | **Critical** | Decision #1, then implement or document |
| drivio | Config | `.gitignore` uses root-anchored `/​.dart_tool/` and `/build/`, so nested `example/` artifacts are tracked | Low | Merge PR #2 (un-anchors the patterns) |
| drivio | Dependencies | No conflicts found; all pins current | None | — |

---

## Weekly Completion Summary

| Project | Completed item | Type | Impact |
|---|---|---|---|
| drivio | — | — | **Nothing was completed this week.** No commits on any branch since 2026-07-19; no merges to `main`; PR #2 unchanged for 5 weeks. |

This row is the most important line in the report. The project is not moving slowly — it has
stopped.

---

## Current Work in Progress

| Project | Item | Status | Next action | Risk |
|---|---|---|---|---|
| drivio | PR #2 — lifecycle, codec, storage and build fixes | **Draft**, `mergeable_state: clean`, 865 (+) / 131 (−) across 21 files, stale 5 weeks | Promote draft → ready, review C3 clamping semantics, merge | High — it is the only thing standing between `main` and compiling |
| drivio | PR #3 — Kanban report (2026-08-03) | Open, unmerged | Merge or close; do not accumulate report PRs | Low |

Nothing else is in flight.

---

## Carryover Items

| Project | Item | Reason for carryover | New target |
|---|---|---|---|
| drivio | Merge PR #2 / buildable `main` | Carried from the 2026-08-03 report. PR was never promoted out of draft; no owner action recorded in 5 weeks. | 2026-08-29 |
| drivio | Tag `0.1.1` | Blocked on the above. | 2026-08-29 |
| drivio | Permissions in the example | **Partially resolved and previously misdiagnosed** — Dart-side permission handling already exists in `GeolocatorLocationSource`. The real blocker is the missing platform folders and manifest entries. | 2026-09-05 |
| drivio | Synchronizer wired into the example | Depends on platform folders. | 2026-09-05 |
| drivio | Retention / backpressure policy | Needs decision #3 before implementation. | 2026-09-05 |
| drivio | Broader unit coverage | Deprioritised behind the build fix; the event detector remains at zero coverage. | 2026-09-12 |

---

## Planned Focus for Next Week

### drivio

- **Focus item:** Merge PR #2 and add CI.
- **Reason:** `main` has not compiled for five weeks and nothing automatically checks it. These
  two changes together convert the repo from "unverifiable" to "verifiable" and unblock
  everything else.
- **Expected outcome:** `main` compiles; `flutter analyze` and `flutter test` run green on every
  push; `0.1.1` tagged.
- **Risk:** Low. PR #2 is `mergeable_state: clean` and its changes are well-reasoned. The one
  item deserving a second look before merge is the codec clamping (C3), which is an improvement
  on current behaviour regardless.
- **Definition of done:** PR #2 merged; `.github/workflows/ci.yml` green on `main`; `0.1.1`
  tagged; `CHANGELOG.md` reflects the release.

- **Focus item:** Fix the 409 data-loss path (C1).
- **Reason:** It silently and permanently destroys telemetry under precisely the condition the
  checksum was added to detect.
- **Expected outcome:** A 409 leaves the chunk `failed` with the local file intact.
- **Risk:** Low — a few lines plus a test.
- **Definition of done:** 409 no longer short-circuits to accepted; a regression test asserts
  the file survives; the README documents the client's status-code contract.

- **Focus item:** Decide the background-execution strategy (decision #1).
- **Reason:** Every other recorder change is provisional until this is settled.
- **Expected outcome:** A written decision in the README plus a tracking issue.
- **Risk:** Medium — option (a) meaningfully expands the platform surface.
- **Definition of done:** Decision recorded; if option (b), the README states exactly what the
  host app must configure, and `example/` demonstrates it.

---

## Recommended Kanban Updates

**Move to Done**

- *Nothing.* No work item completed this cycle. Recording an empty Done column honestly is more
  useful than manufacturing one.

**Move to In Progress**

- **Project:** drivio · **Item:** PR #2 promotion, review and merge ·
  **Reason:** It is the sole blocker on a buildable `main` and has been idle for five weeks;
  it needs an owner and a date, not another cycle in draft.
- **Project:** drivio · **Item:** Add `.github/workflows/ci.yml` ·
  **Reason:** Cheapest change in the repo with the highest leverage; `main` shipped two compile
  errors precisely because nothing checked.

**Move to Blocked**

- **Project:** drivio · **Item:** Any further recorder or lifecycle work ·
  **Blocker:** Decision #1 (background execution). Work done before that decision may need reworking.
- **Project:** drivio · **Item:** On-device verification ·
  **Blocker:** `example/` has no `android/` or `ios/` platform folders.
- **Project:** drivio · **Item:** Trip resume / crash recovery ·
  **Blocker:** Decision #4, plus the `unique (trip_id, chunk_index)` collision on the backend.

**Move to Ready**

- **Project:** drivio · **Item:** Fix 409 handling in `HttpTelemetryBackendClient` ·
  **Reason:** Fully specified, small, no dependencies, and it stops active data loss.
- **Project:** drivio · **Item:** Generate `example/android` and `example/ios` ·
  **Reason:** Mechanical; unblocks all device testing.
- **Project:** drivio · **Item:** Add `TelemetryStore.deleteTrip` ·
  **Reason:** Needed by the retention policy and independently useful.

**Move to Parked**

- **Project:** drivio · **Item:** Axis-calibration implementation ·
  **Reason:** Needs decision #2 and real vehicle data to validate; not startable this cycle.
- **Project:** drivio · **Item:** MapTiler / OSRM production key provisioning ·
  **Reason:** No production build target exists yet.

---

## Final Recommendations

**The most important thing to fix first:** merge PR #2. `main` has not compiled since
2026-07-18, the fix has existed since 2026-07-19, and it is clean-mergeable. Everything else in
this report is downstream of that one action. If only one thing happens this week, this is it.

**Steps to get closer to release:**

1. Promote PR #2 draft → ready; review the codec-clamping semantics (C3); merge; tag `0.1.1`.
2. Add a two-job CI workflow (`flutter analyze --fatal-infos`, `flutter test`) so the repo can
   never again sit for five weeks in an unbuildable state without anyone noticing.
3. Fix the 409 data-loss path (C1) and add its regression test.
4. Decide background execution (#1); record it in the README.
5. Generate the `example/` platform folders and wire the synchronizer in — the first point at
   which anyone can actually watch this package work.
6. Implement the retention policy and the retry cap (#3, I1).
7. Write tests for `CandidateEventDetector` — 317 lines, zero coverage, and the reason the
   package exists.

**The item carrying the highest risk:** the absent background-execution capability. The build
break is louder, but it is a known defect with a known fix sitting in a branch. The background
gap is an unacknowledged architectural hole: the package's entire purpose is recording while
someone drives, and it currently stops the moment the screen locks. No one has written it down,
scheduled it, or decided who owns it.

**The decision most urgently required:** background execution — package responsibility or host
responsibility (decision #1). It gates the permission model, the manifest entries, the battery
profile, the trip-resume design, and the shape of the example app. Recommendation: option (b),
platform-thin with an explicit contract and a worked example.

**Recommended focus for the next 7 days:** merge PR #2 → add CI → fix C1 → decide #1.
Four items, all small, all unblocking. Do not start new features until `main` builds and
something automated is watching it.
