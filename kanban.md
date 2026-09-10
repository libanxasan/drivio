# Weekly Engineering Kanban Report

**Project under deep review:** `drivio` — the `driving_telemetry` Flutter package
**Report date:** 2026-09-10
**Reviewed refs:** `main` @ `3df62f4` · draft PR **#2** `claude/codebase-stability-quality-tz5e6t` @ `d4a9d76`
**Prepared by:** Engineering review (automated, code-aware)

> **Rotation note.** Every repository in the portfolio now carries a Kanban report on its
> default branch or in an open PR, so the selection rule falls through to *oldest existing
> report*. `drivio`'s newest report is **2026-08-22** (PR #4) — the oldest in the portfolio,
> ahead of `djib-dial` (2026-08-23) and `BoutiSign` (2026-08-24). Last cycle's pick
> (`Airness_next`, 2026-09-09) is excluded.
>
> **Verification limits — read these before trusting any build claim.** No Flutter or Dart
> SDK exists in this environment: `flutter analyze`, `flutter test` and `flutter build`
> could **not** be run. Every statement below is derived from reading the source against
> the pinned dependency APIs and is labelled as such. The repository has **no CI**, so no
> automated check has ever run against `main` or against PR #2 — not once, in the
> project's entire history.

---

## Executive Summary

- **Active projects:** 18 repositories in the portfolio; **1 deep-reviewed this cycle** (`drivio`).
- **Overall portfolio status:** `drivio` is an architecturally strong but **pre-alpha**
  Flutter *package* (not an app), version `0.1.0`, ~4.7k lines of Dart across 45 files
  (40 of them under `lib/`).
  Its `main` branch does not compile. A clean, mergeable draft PR (#2) fixes the compile
  breaks plus a cluster of silent data-loss bugs, and has now sat untouched for
  **seven and a half weeks**.
- **Completed this week:** **Nothing.** No commit exists on any branch since 2026-07-19.
  Three weeks have passed since the last report and the tree is byte-identical.
  This project is not moving slowly — it is stopped.
- **Work currently in progress:** Nominally PR #2. In practice, zero activity.
- **Main blockers:** (1) `main` does not compile — `sensors_plus` 7.x renamed the stream
  APIs, and const-constructor asserts compare `Duration`s, which Dart rejects as
  non-constant. (2) PR #2 is still marked **draft**, so nothing can merge. (3) No CI
  exists to prove any of it, and `example/` has no `android/`/`ios/` folders, so the
  package cannot be built onto a phone at all.
- **Highest-risk item:** **The package cannot record while the app is backgrounded.**
  A `grep` across `lib/` finds no foreground service, no wakelock, no background isolate,
  and no trip-resume path. A driving telemetry recorder that stops when the screen locks
  does not do its job, and no amount of codec polish changes that. Unchanged since it was
  first raised on 2026-08-22.
- **Next release target:** `0.1.1` = merge of PR #2 — the first genuinely buildable tag.
  An *internal* milestone, not a shippable one.
- **Key decision required:** Commit to a background-execution strategy (Android foreground
  service owned by the package vs. explicitly host-app responsibility). Permissions,
  battery budget, trip resume and manifest lifecycle all hang off that one answer, and
  three cycles have now passed without it being made.
- **Recommended focus for next week:** Promote and merge PR #2 → fix the 409 data-loss bug
  it does *not* cover → add a two-job CI workflow → generate `example/` platform folders →
  then decide the background-execution question.

---

## Portfolio Kanban Snapshot

Counts scope the `drivio` work items surfaced by this review. Sibling projects are tracked
only by report coverage (see *Portfolio rotation status*).

| Status | Count | Notes |
|---|---:|---|
| Inbox | 5 | Background execution · axis calibration · retention/purge policy · trip-resume semantics · error-stream semantics |
| Ready | 4 | Add CI workflow · fix 409 handling · generate `example/` platform folders · cap upload retries |
| In Progress | 0 | Nothing has moved in 7.5 weeks — PR #2 is stalled, not in progress |
| Review / Testing | 1 | PR #2 — clean, mergeable, needs draft→ready promotion |
| Blocked | 3 | `main` build (sensors_plus 7.x) · `main` build (const `Duration` asserts) · device testing (no platform folders) |
| Done | 0 | No merges to `main` this week or in either of the two preceding cycles |
| Parked | 2 | On-device verification (needs Android device + GPS) · MapTiler/OSRM production keys |

### Portfolio rotation status

| Repo | Latest Kanban report | Where |
|---|---|---|
| **drivio** | **2026-08-22** | **PR #4 (open) — this cycle's target** |
| djib-dial | 2026-08-23 | open PR |
| BoutiSign | 2026-08-24 | open PR |
| kyoto | 2026-08-25 | open PR |
| shax_game | 2026-08-26 | open PR |
| airness | 2026-08-27 | merged to `main` |
| djibVPN | 2026-08-28 | merged to `main` |
| PointS | 2026-08-29 | merged to `main` |
| pHarmaDjib_Next | 2026-08-30 | merged to `main` |
| red-sea-news | 2026-09-01 | open PR |
| clipaid | 2026-09-02 | open PR |
| djibouti-motors | 2026-09-03 | merged to `main` |
| myDrive | 2026-09-04 | merged to `main` |
| pHarmaDjib | 2026-09-05 | merged to `main` |
| ussd_dj | 2026-09-06 | open PR |
| automotivate | 2026-09-07 | open PR |
| PointS_portal | 2026-09-08 | open PR |
| Airness_next | 2026-09-09 | merged to `main` — last cycle |

**Portfolio-level observation.** 8 of 18 projects now merge their report into the default
branch; 10 still leave it in an open PR. `drivio` is the worst case: three report PRs
(#3 2026-08-03, #4 2026-08-22, and this one) will now be open simultaneously against a
repository where nothing else has moved. Either merge reports on delivery or stop opening
PRs for them — a stack of unread review documents on a stalled repo is pure overhead.

---

## Project Status

### 1. drivio — `driving_telemetry`

**Current state:**

A cleanly layered Flutter **package** (not an app) that collects ~25 Hz motion and ~1 Hz
GPS, condenses to one-second statistical frames, detects candidate events, retains short
high-resolution evidence windows around them, delta-encodes and gzips versioned binary
chunks (magic `DTL1`, schema version 1), persists them atomically with SHA-256 checksums,
matches the route through OSRM after the trip, and uploads chunks idempotently to a
backend. By deliberate design it performs **no scoring** — that is the backend's job, and
`backend_reference/` ships a real Supabase edge function (229 lines), a SQL schema with
RLS, and a Deno decoder (245 lines) that proves the contract end to end.

The layering is genuinely good, the domain model is complete, and the binary format is
documented (`docs/BINARY_FORMAT.md`). The project is nonetheless **not usable today** for
three independent reasons: `main` does not compile; even once it does, the package cannot
record while backgrounded; and there is no way to build it onto a device to find out.

**Completed (verified by reading the code):**

- Full domain model — `location_sample`, `raw_motion_sample`, `motion_frame`,
  `event_candidate`, `hourly_aggregate`, `telemetry_chunk`, `trip_manifest`, `trip_result`,
  `osrm_match_result`, `effective_speed_limit`, `street_context`, `axis_statistics`,
  `vector3_value`.
- Recorder orchestration with an explicit FSM (`idle → starting → recording → stopping →
  disposed`), a serialized write tail (`_writeTail`), time-bounded ring buffers, evidence
  capture, chunk flushing on duration *or* estimated byte size
  (`driving_telemetry_recorder.dart:448-462`), and haversine distance with plausibility
  gating (`:531-545`).
- Candidate detection with sustained-threshold state machines, per-type cooldowns and
  confidence scoring (`candidate_event_detector.dart`, 317 lines).
- Streaming statistics — Welford-style online mean/variance in `online_statistics.dart`,
  fed by `motion_frame_aggregator` and `hourly_aggregator`.
- `DTL1` codec — varuint, ZigZag, delta timestamps, delta lat/lon, integer quantization,
  gzip, SHA-256 (`telemetry_binary_codec.dart`, 415 lines).
- Atomic file store with a global `AsyncMutex`, per-trip manifests, upload status, retry
  counts and last error (`file_telemetry_store.dart`, 326 lines).
- Idempotent HTTP upload with `Idempotency-Key`, bearer-token provider and a documented
  header contract (`http_backend_client.dart`).
- OSRM Match with overlapping request windows, MapTiler style URL + reverse geocoding,
  OSM `maxspeed` parsing with a backend-first precedence chain.
- Reference backend: RLS-scoped tables, checksum verification server-side, storage upload
  with rollback on insert failure, and trip closure driven by the `tripManifest` chunk.
- 4 test files on `main` (257 lines) covering the codec round trip, the store, the speed
  limit provider and a basic recorder path.

**In progress:**

- Nothing. PR #2 is the only open code work and it has not been touched since 2026-07-19.

**Missing / left to be done:**

1. **Background execution.** No foreground service, wakelock, background isolate, or
   platform channel anywhere in `lib/`. The README documents geolocator's
   `foregroundNotificationConfig` as a *host-app* concern, but `SensorMotionSource` runs on
   the Dart main isolate and will be suspended with the app regardless.
2. **Trip recovery after process death.** `startTrip` throws unless the recorder is `idle`
   (`driving_telemetry_recorder.dart:127-129`) and `closeTrip` is only ever called from
   `stopTrip`. If the OS kills the app mid-trip, the local manifest stays `status:
   "recording"` forever and the backend row stays `'recording'` too, because the edge
   function only closes a trip when it receives a `tripManifest` chunk
   (`index.ts:210-212`). Chunks already written still upload — `listPendingChunks` scans
   every trip directory — but the trip never closes and no `TelemetryTripResult` is ever
   produced. There is no `recoverInterruptedTrips()` API.
3. **Retention and purge.** `TelemetryStore` exposes no `deleteTrip`. Event evidence is
   retained after upload by default (`deleteUploadedEventEvidence = false`) and route +
   manifest artifacts are never deleted (`_shouldDelete` returns false for them,
   `telemetry_synchronizer.dart:88-96`). On-device storage grows without bound for the
   life of the install.
4. **Retry cap and backoff.** `retryCount` is incremented and persisted
   (`file_telemetry_store.dart:249-259`) but never read by anything. A permanently
   poisoned chunk — say one the backend 422s on checksum — is retried on every pass,
   forever, with no delay.
5. **`example/` platform folders.** `example/` contains only `lib/main.dart` and
   `pubspec.yaml`. No `android/`, no `ios/`. `flutter run` cannot execute, which is why
   nothing in this package has ever been validated against real sensors.
6. **CI.** No `.github/` directory at all.
7. **Cross-language codec conformance.** The Dart encoder and the Deno decoder are two
   independent implementations of `DTL1` with no shared fixture. Both hardcode schema
   version 1 (`telemetry_binary_codec.dart:17`, `telemetry_decoder.ts:98`) and nothing
   catches drift between them.
8. **Axis calibration.** `VehicleAxisMapping` defaults to `isCalibrated: false` and the
   package offers no calibration routine — only the ability to accept a mapping the host
   computed some other way.

**Blocked:**

- **`main` compile break #1 — sensors_plus API.** `sensor_motion_source.dart:34,43` calls
  `gyroscopeEvents(...)` and `userAccelerometerEvents(...)`. The deprecated getter-style
  APIs were removed in `sensors_plus` 6.0; the pinned `^7.1.0` exposes
  `gyroscopeEventStream()` / `userAccelerometerEventStream()`. PR #2 makes exactly this
  rename. *(Derived from the pinned constraint plus the shape of the PR-#2 fix; not
  verified by a compiler in this environment.)*
- **`main` compile break #2 — const asserts on `Duration`.**
  `telemetry_configuration.dart:78-96` and `osrm_configuration.dart:9-10` compare
  `Duration` values inside const-constructor initializer asserts. `Duration.operator>` is a
  user-defined method and is not a potentially-constant expression, so every `const
  TelemetryConfiguration()` — including the default parameter value in the recorder's own
  constructor (`driving_telemetry_recorder.dart:37`) — fails to compile. PR #2 moves these
  to a runtime `validate()`.
- **Lint gate.** `analysis_options.yaml` enables `public_member_api_docs: true`, and `main`
  has undocumented enum members in at least five files. `flutter analyze` would fail on
  `main` independently of the two compile errors. PR #2 documents every one of them.
- **Device testing.** Blocked on the missing `example/` platform folders.

**Codebase observations:**

*Architecture.* Textbook clean layering: `model/` → `codec/`, `aggregation/`, `event/` →
`recording/`, `storage/`, `network/`, with `config/` cross-cutting. Every I/O boundary sits
behind an interface (`TelemetryStore`, `MotionSource`, `LocationSource`,
`TelemetryBackendClient`), which is why PR #2 could add 472 lines of tests with fakes and
no mocking framework. One public barrel file (`lib/driving_telemetry.dart`) with everything
else under `lib/src/`. This is the strongest part of the project and should not be
disturbed.

*Domain model.* Good. Immutable value objects, explicit `E7` integer fields for lat/lon
alongside the doubles, `copyWith` where mutation is needed. Timestamps are consistently
UTC epoch integers — millis for location/frames, micros for raw motion — which is the right
call for a delta codec, though the constant `~/ 1000` conversions in the recorder are a
readability tax.

*State management.* Not a Flutter-state problem — the recorder is a plain object with an
explicit FSM plus two broadcast streams (`candidateEvents`, `errors`). Correct for a
package. The serialized `_writeTail` (`:513-517`) is a neat way to keep chunk writes in
order without blocking the sensor callbacks. **But it swallows every write error into a
`catchError`**, which is how the varuint bug below becomes silent (see *Data integrity*).

*Routing and navigation.* Not applicable — this is a package with a one-screen example. The
example screen is a single stateful widget with a status string and a start/stop button;
adequate as a harness, and not a product surface.

*Persistence.* Manifest-per-trip JSON plus gzipped chunk files, guarded by a single
`AsyncMutex`. The mutex is coarse (one lock for the whole store) but at these write rates —
a chunk per minute — that is the right trade. On `main`, `initialize()` and
`deleteChunkFile()` sit *outside* the mutex (`file_telemetry_store.dart:32-38, 276-282`)
and `_atomicWrite*` does delete-then-rename (`:313-325`), which is **not** atomic: a crash
in that window leaves the manifest missing entirely, losing the index for every chunk in
the trip. PR #2 fixes all three.

*Service layer.* `TelemetrySynchronizer` is small and correct in shape: mark-uploading →
read → upload → mark-uploaded → conditional delete, with per-chunk failure isolation. Two
gaps: on `main` a failing `markFailed` aborts the whole pass (PR #2 wraps it), and there is
no retry cap or backoff at all (neither fixes).

*Error handling.* Two-tier and mostly deliberate: fatal errors throw, non-fatal ones go to
the `errors` stream. The weak point is that `_enqueueWrite`'s `catchError` turns *encoding*
failures into a lost chunk with no other signal than a stream event nobody is required to
listen to. Note also that PR #2 changes source errors from `addError` to `add`
(`_reportError`), so a consumer using `stream.listen(onError:)` would silently stop seeing
them — a small API-semantics decision that should be made consciously before merge.

*Testability.* High, by construction. PR #2's `_FlakyStore`, `_FakeMotionSource` and
`_ScriptedBackend` are written against the existing interfaces with no framework — proof
the seams are in the right places. Coverage on `main` is thin (257 lines) and skips the
recorder lifecycle, the synchronizer and every failure path; PR #2 roughly triples it.

*Build and dependencies.* `sdk: >=3.4.0 <4.0.0`, `flutter: >=3.22.0`, five runtime
dependencies (`crypto`, `geolocator`, `http`, `path_provider`, `sensors_plus`), all pinned
with caret constraints and none conflicting. `pubspec.lock` is gitignored (correct for a
package). The build breaks are source-level, not dependency-resolution-level.

*Performance.* Per motion sample (~25 Hz) the recorder iterates `_activeEvidence`, runs the
aggregator, runs the detector, then scans `_activeEvidence` again for completion
(`:305-322`). All small-N loops; fine. The real cost is `_completeLocationTrace`, which
retains every valid fix for the whole trip to feed OSRM — ~3,600 objects/hour, acceptable
for normal trips but unbounded for a multi-day one. Chunk flush estimates size with
hardcoded per-record byte constants (`:452-454`), which will drift from the codec's actual
output over time.

*Security and data integrity.* Sound at the boundaries: TLS is assumed, tokens come from a
callback rather than storage, the edge function verifies the SHA-256 server-side and
enforces `x-user-id == auth.uid()` before touching storage, and RLS scopes reads. Nothing
is encrypted at rest on-device — the README says so explicitly, which is an honest
deferral rather than an oversight. The two integrity defects are the 409 mis-handling and
the varuint crash, both below.

**Next actions (priority order):**

1. Promote PR #2 out of draft and merge it. It is the only thing standing between this
   repo and a build.
2. Fix the 409 data-loss path in `http_backend_client.dart:66-71`.
3. Add `.github/workflows/ci.yml` — `flutter analyze` + `flutter test` on push and PR.
4. `flutter create --platforms=android,ios .` inside `example/` and commit the result.
5. Decide the background-execution question and write it down in the README.
6. Add `recoverInterruptedTrips()` to close trips orphaned by process death.
7. Add `deleteTrip()` and a retention policy; cap upload retries.

**Risk:** **High.**

Not because the code is bad — it is well above average — but because none of it has ever
been executed. Two compile errors, zero CI runs, no runnable example, and a recorder whose
central premise (record a whole drive) is unproven against the platform's background
policy. Seven and a half weeks of zero commits on a repo in this state means the risk is
compounding, not static.

**Release readiness:** **Not ready.**

`main` does not compile. Post-merge of PR #2 it becomes *internally testable* — and only
once `example/` can actually run on a phone.

---

## Cross-Project Priorities

1. **Merge PR #2 (`Fix lifecycle and reliability issues in telemetry recorder`)**
   - **Project:** drivio
   - **Reason:** It fixes both compile errors, the non-atomic manifest write, the unlocked
     store methods, and — most importantly — the negative-delta varuint crash that silently
     discards whole chunks. It also adds 472 lines of tests. It has been review-ready and
     untouched for 7.5 weeks while still marked draft.
   - **Impact:** Without it there is no buildable artifact, so no other drivio work can be
     validated. With it, the package compiles and has meaningful test coverage for the
     first time.
   - **Recommended action:** Mark ready for review, run `flutter analyze` and
     `flutter test` locally once, merge to `main`, tag `0.1.1`.

2. **Fix the HTTP 409 data-loss path**
   - **Project:** drivio
   - **Reason:** `http_backend_client.dart:66-71` treats *any* 409 as
     `accepted: true, alreadyExisted: true`. The project's own reference backend returns 409
     for exactly one condition: an existing idempotency key whose **checksum does not
     match** (`index.ts:161-167`). So the one chunk whose bytes disagree with the server is
     marked uploaded and — for continuous chunks, deleted by default — permanently lost,
     locally and remotely.
   - **Impact:** Silent, unrecoverable telemetry loss precisely where the data is already
     suspect. Not covered by PR #2.
   - **Recommended action:** Treat 409 as a hard failure that keeps the local file and
     surfaces the conflict; reserve the already-exists acknowledgement for the 200 response
     carrying `alreadyExisted: true`, which the backend already sends (`index.ts:171-175`).

3. **Add CI**
   - **Project:** drivio
   - **Reason:** No `.github/` directory. Two compile errors have survived on `main` since
     July precisely because nothing ever checks.
   - **Impact:** Every future change is unverifiable, and the repo can regress into
     non-compiling state again the moment PR #2 lands.
   - **Recommended action:** One workflow, two jobs — `flutter analyze --fatal-infos` and
     `flutter test` — on push and pull_request. Ten minutes of work.

4. **Decide background execution**
   - **Project:** drivio
   - **Reason:** The package's entire value proposition is recording a full drive. Nothing
     in `lib/` keeps it alive when the app backgrounds.
   - **Impact:** Determines whether the package needs a platform channel and foreground
     service (weeks) or a documented host-app contract (days). Blocks any credible
     roadmap.
   - **Recommended action:** Make the call this cycle; see *Blockers Requiring Decision*.

5. **Merge or stop opening report PRs across the portfolio**
   - **Project:** portfolio-wide
   - **Reason:** 10 of 18 projects leave their Kanban report in an open PR; drivio will now
     have three.
   - **Impact:** Review queue noise that hides real code PRs — drivio's PR #2 is currently
     outnumbered 2:1 by report PRs in its own repo.
   - **Recommended action:** Merge report PRs on delivery, as `airness`, `djibVPN`,
     `PointS`, `myDrive`, `pHarmaDjib*`, `djibouti-motors` and `Airness_next` already do.

---

## Blockers Requiring Decision

**1. Background execution strategy**

- **Project:** drivio
- **Decision required:** Does the package own background recording, or does the host app?
- **Options:**
  - **(a) Package owns it.** Add an Android foreground service + platform channel, a
    wakelock, and iOS background-location plumbing inside the package.
  - **(b) Host app owns it.** The package documents an explicit contract: the host supplies
    `AndroidSettings` with `foregroundNotificationConfig`, requests background-location
    permission, and accepts iOS suspension of the motion stream.
  - **(c) Hybrid.** Package ships the Android foreground service; iOS remains
    location-only, with motion frames explicitly documented as best-effort.
- **Recommended option:** **(c).** Android is the realistic target market for a Djibouti
  fleet-telemetry product, and it is where a foreground service actually delivers
  continuous sensor access. iOS suspends third-party motion processing regardless of what
  the package does, so promising parity there would be dishonest.
- **Impact if delayed:** Every recorder change risks rework, permissions and battery
  budget stay unspecified, and the package cannot be integrated into any real app. Already
  delayed three cycles.
- **Owner:** Project lead
- **Deadline:** 2026-09-17 (before any further recorder work)

**2. Trip lifecycle after process death**

- **Project:** drivio
- **Decision required:** What happens to a trip whose process was killed mid-recording?
- **Options:** (a) auto-close on next `initialize()` using the last chunk's `endedAtMillis`;
  (b) expose `recoverInterruptedTrips()` and let the host decide; (c) resume the trip if
  restarted within a grace window.
- **Recommended option:** **(a) plus (b)** — auto-close on startup, but expose the list so
  the host can surface "your last trip ended unexpectedly". Resume-in-place (c) is not
  worth the complexity when chunks are already independently uploadable.
- **Impact if delayed:** Orphaned trips stay `'recording'` in the backend forever and no
  `TelemetryTripResult` is ever produced for them, so scoring never runs on real-world
  crash cases — which, for a background recorder, is the common case.
- **Owner:** Backend + mobile
- **Deadline:** 2026-09-24

**3. Retention policy**

- **Project:** drivio
- **Decision required:** How long does telemetry stay on the device after upload?
- **Options:** (a) delete on ack for everything; (b) keep evidence N days then purge;
  (c) size-capped LRU purge.
- **Recommended option:** **(b) with a 7-day default and a size cap** — evidence is the
  data most worth re-uploading after a backend bug, and 7 days covers a realistic
  reprocessing window.
- **Impact if delayed:** Unbounded disk growth; eventual write failures on low-end devices,
  which is exactly the target hardware.
- **Owner:** Project lead
- **Deadline:** 2026-10-01

**4. Error-stream semantics (small, but decide before merging PR #2)**

- **Project:** drivio
- **Decision required:** Are non-fatal errors data events or error events on
  `recorder.errors`?
- **Options:** (a) all as data events (PR #2's behaviour); (b) all as `addError`;
  (c) split streams.
- **Recommended option:** **(a)** — consistent, and it stops a stray `addError` from
  killing a consumer's subscription. Document it on the `errors` getter so nobody writes
  an `onError` handler that never fires.
- **Impact if delayed:** Trivial, but it silently changes behaviour for anyone who
  integrated against `main`.
- **Owner:** Package maintainer
- **Deadline:** With PR #2 merge

---

## Technical Debt and Refactor Candidates

### Critical

- **Project:** drivio · **Area:** `lib/src/codec/compact_binary.dart:16` +
  `driving_telemetry_recorder.dart:513-517`
  **Problem:** `writeVarUint` throws `ArgumentError` on a negative value. On `main`, chunk
  start times are taken from `locations.first` / `frames.first` on the assumption that list
  order matches time order (`:482-493`), and evidence chunk starts are clamped only against
  `_startedAtMillis` (`:413-421`). A single out-of-order GPS fix — a cached first fix, a
  clock adjustment — makes a delta negative, `encode` throws, and `_enqueueWrite`'s
  `catchError` swallows it. **The entire chunk is silently dropped.**
  **Recommended fix:** Merge PR #2, which clamps every delta with `math.max(0, …)` and
  scans all elements for true min/max instead of trusting list order.
  **Priority:** P0

- **Project:** drivio · **Area:** `lib/src/network/http_backend_client.dart:66-71`
  **Problem:** All 409s treated as success; the reference backend uses 409 exclusively for
  checksum conflict. Chunk marked uploaded and deleted locally → permanent loss.
  **Recommended fix:** Throw `TelemetryUploadException` on 409 and keep the file; rely on
  the 200 + `alreadyExisted: true` response for genuine idempotent replays.
  **Priority:** P0

- **Project:** drivio · **Area:** `lib/src/storage/file_telemetry_store.dart:313-325`
  **Problem:** `_atomicWriteString` / `_atomicWriteBytes` delete the destination before
  renaming. A crash in that window destroys `manifest.json`, orphaning every chunk in the
  trip.
  **Recommended fix:** Merge PR #2 — it renames over the destination and only falls back to
  delete-then-rename on `FileSystemException`.
  **Priority:** P0

- **Project:** drivio · **Area:** repository root
  **Problem:** No CI. Two compile errors have lived on `main` for eight weeks.
  **Recommended fix:** Add the two-job workflow.
  **Priority:** P0

### Important

- **Project:** drivio · **Area:** `telemetry_synchronizer.dart` + `file_telemetry_store.dart:249-259`
  **Problem:** `retryCount` is persisted but never read. No cap, no backoff. A poisoned
  chunk retries forever on every pass.
  **Recommended fix:** Skip chunks past a `maximumRetries` threshold, expose them as
  `quarantined`, and add exponential backoff keyed off the manifest's last-attempt time.
  **Priority:** P1

- **Project:** drivio · **Area:** `TelemetryStore` interface
  **Problem:** No `deleteTrip`; route and manifest artifacts are never removed
  (`_shouldDelete` returns false for them). Storage grows for the life of the install.
  **Recommended fix:** Add `deleteTrip(tripId)` plus an age/size purge invoked after a
  successful sync pass.
  **Priority:** P1

- **Project:** drivio · **Area:** `lib/src/codec/` ↔ `backend_reference/telemetry_decoder.ts`
  **Problem:** Two hand-written implementations of `DTL1`, both hardcoding schema version 1,
  with no shared fixtures. Any encoder change can silently break the decoder.
  **Recommended fix:** Commit a golden-fixture directory (a handful of `.dtl.gz` files plus
  expected JSON) and assert against it from both the Dart tests and a Deno test.
  **Priority:** P1

- **Project:** drivio · **Area:** `driving_telemetry_recorder.dart:452-454`
  **Problem:** Chunk-size estimation uses hardcoded per-record byte constants (36/170/120)
  that have no relationship to what the codec actually emits.
  **Recommended fix:** Derive them from a codec-provided estimate, or flush on record count
  and let compression handle the rest.
  **Priority:** P2

- **Project:** drivio · **Area:** `example/`
  **Problem:** No platform folders — the example cannot run, so no sensor code in this
  package has ever been exercised on hardware.
  **Recommended fix:** `flutter create --platforms=android,ios .` and commit, including the
  permission entries the README already documents.
  **Priority:** P1

### Optional

- **Project:** drivio · **Area:** recorder timestamp handling
  **Problem:** `sample.timestampMicros ~/ 1000` is repeated at five call sites.
  **Recommended fix:** A `timestampMillis` getter on `RawMotionSample`.
  **Priority:** P3

- **Project:** drivio · **Area:** `candidate_event_detector.dart:106`
  **Problem:** The GPS-quality-loss minimum duration is a hardcoded `Duration(seconds: 5)`
  while every sibling threshold is configurable.
  **Recommended fix:** Move it to `TelemetryConfiguration`.
  **Priority:** P3

- **Project:** drivio · **Area:** `file_telemetry_store.dart`
  **Problem:** One global mutex serializes all store I/O across all trips.
  **Recommended fix:** Leave it. Revisit only if profiling shows contention — at one chunk
  per minute it will not.
  **Priority:** P3

---

## Missing Screens, Views, and User Flows

`drivio` is a package, not an application, so "screens" here means the public API surface
and the example harness that stands in for a host app.

| Project | Missing screen / flow | Current state | Required work | Priority |
|---|---|---|---|---|
| drivio | Background recording flow | Absent from `lib/` entirely | Foreground service + platform channel (Android), documented iOS limits | P0 |
| drivio | Interrupted-trip recovery flow | No API; orphaned trips stay `"recording"` | `recoverInterruptedTrips()` + auto-close on `initialize()` | P1 |
| drivio | Permission request flow | `GeolocatorLocationSource.start()` checks and throws; nothing requests | Explicit request/rationale API, or a documented host contract | P1 |
| drivio | Example: sync/upload screen | Example only starts/stops a trip | Wire `synchronizePendingData()` with pending count and per-chunk status | P1 |
| drivio | Example: error state | Errors collapse into one `_status` string; `errors` stream unused | Subscribe to `recorder.errors`, render a list | P2 |
| drivio | Example: loading state | No indicator during `stopTrip()` (which awaits OSRM over the network) | Progress indicator around the async gap | P2 |
| drivio | Example: empty state | No "no trips recorded yet" affordance | Trip list backed by the store | P3 |
| drivio | Trip history / detail view | No store API to list closed trips | `listTrips()` + example screen | P2 |
| drivio | Axis calibration flow | `isCalibrated: false` default; no routine | Guided stationary + acceleration calibration | P2 |
| drivio | Settings / configuration view | Config is code-only | Example screen exposing thresholds for field tuning | P3 |
| drivio | Data deletion (user-facing) | No `deleteTrip`; README promises "allow users to delete trips" | Store API + example action | P1 |

---

## Data, Persistence, and Sync Review

### drivio

**Current persistence state:**

- **Storage method:** Local filesystem under `getApplicationSupportDirectory()/driving_telemetry/`,
  one directory per trip, `manifest.json` plus gzipped chunk files. No database, no
  encryption at rest.
- **Main entities:** `TripManifest` (trip id, user id, start/end, schema version, status,
  metadata, chunk list) and `StoredTelemetryChunk` (id, index, type, time range, payload
  format, byte size, SHA-256, relative path, upload status, retry count, last error).
  Backend mirror: `driving_telemetry_trips` + `driving_telemetry_chunks` with RLS.
- **Missing entities:** No device/session record (so a trip cannot be attributed to a
  phone), no calibration record, no local upload-attempt log beyond a single `lastError`
  string.

**Issues found:**

1. **Non-atomic manifest replacement** (`:313-325`) — crash window destroys the trip index.
   *Fixed by PR #2.*
2. **Unsynchronized `initialize()` and `deleteChunkFile()`** — two concurrent calls can race
   the root directory or read a manifest mid-write. *Fixed by PR #2.*
3. **409 mis-classification** — see Critical debt. Marks a conflicting chunk uploaded and
   deletes it. *Not fixed by PR #2.*
4. **No retention or purge** — nothing ever deletes a trip directory.
5. **No retry ceiling** — a permanently failing chunk is retried on every pass forever.
6. **`markUploading` before the request** — correct for crash detection (the chunk is picked
   up again because `listPendingChunks` includes `uploading`), but it means an interrupted
   upload is indistinguishable from an in-flight one; concurrent sync passes would double
   upload. The idempotency key makes that safe on the server, not on the wire.
7. **Manifest rewritten on every status transition** — three full JSON rewrites per chunk
   (uploading → uploaded → post-delete). Cheap now; quadratic-ish as `chunks` grows on a
   long trip.

**Recommended changes:**

- Merge PR #2 (fixes 1 and 2).
- Fix the 409 path (3) — highest-value single change in the repo.
- Add `deleteTrip()` + an age/size purge after each successful sync (4).
- Add `maximumRetries` + backoff, and a `quarantined` status (5).
- Add a `syncInProgress` guard on the synchronizer (6).
- Consider an append-only status journal if manifest rewrite cost ever shows up (7).

**Offline behaviour:** Good by design — recording is entirely local, upload is a separate,
resumable pass. Chunks survive app restarts and upload later. This is the part of the
design that is genuinely production-shaped.

**Sync requirements:** One-way, device → backend, idempotent by `{tripId}:{chunkId}`.
No down-sync, no conflict resolution needed. Correct scope.

**Backup / export:** None. No export API, no way for a user to retrieve their own raw
telemetry from the device.

**Risk level:** **High** — until the 409 fix lands, the sync layer can destroy exactly the
data it is meant to protect.

---

## UI and Design Implementation Review

### drivio

**UI status:** Minimal by design. One example screen (`example/lib/main.dart`, 107 lines):
an `AppBar`, a status `Text`, a `FilledButton` toggle, and six result lines. Material 3
defaults, no custom theme, no design system. For a package example that is defensible —
but it cannot currently run, since `example/` has no platform folders.

**Problems found:**

1. **Cannot run.** No `android/` or `ios/` in `example/`. Everything below is therefore
   unverified by rendering.
2. **Text overflow risk.** The matched-distance line
   (`main.dart:95-98`) concatenates a label and a formatted double in one unconstrained
   `Text` inside a stretched `Column` — on a narrow device it will overflow rather than
   wrap or ellipsize.
3. **No loading state.** `stopTrip()` awaits an OSRM network call; the button stays live and
   the status shows "Finalizing telemetry" with no spinner and no disabled state, so a
   double-tap during the gap hits `startTrip` on a recorder that is still `stopping` and
   throws a `StateError` into the status line.
4. **Errors rendered as raw `toString()`** (`main.dart:64`) — users see Dart exception text.
5. **`recorder.errors` never consumed** — non-fatal errors are invisible in the example, so
   the example fails to demonstrate the package's own error contract.
6. **No accessibility work** — no semantics labels, no minimum tap-target sizing beyond
   `FilledButton` defaults, no dynamic-type check.
7. **Fixed 24px padding / 24px gaps** with no responsive breakpoints; fine on a phone,
   unconsidered elsewhere.

**Recommended fixes:**

- Generate the platform folders (unblocks everything else here).
- Disable the button while `state` is `starting`/`stopping`; add a progress indicator.
- Wrap result lines in `Flexible`/`softWrap` or `Expanded` rows.
- Subscribe to `recorder.errors` and render a dismissible list.
- Map known exceptions to human strings before display.

**Priority:** P2 overall — but the platform-folder item is P1, because it blocks all
on-device validation of the package itself, not just the UI.

---

## Build, Dependencies, and Environment Review

| Project | Build status | Issue | Severity | Recommended fix |
|---|---|---|---|---|
| drivio (`main`) | **Broken** (by inspection) | `sensor_motion_source.dart:34,43` calls `gyroscopeEvents` / `userAccelerometerEvents`, removed in `sensors_plus` 6.0; pinned `^7.1.0` | Critical | Merge PR #2 (`gyroscopeEventStream` / `userAccelerometerEventStream`) |
| drivio (`main`) | **Broken** (by inspection) | `Duration` comparisons in const-constructor asserts (`telemetry_configuration.dart:78-96`, `osrm_configuration.dart:9-10`) | Critical | Merge PR #2 (runtime `validate()`) |
| drivio (`main`) | **Analyze fails** | `public_member_api_docs: true` vs. undocumented enum members in ≥5 files | High | Merge PR #2 (docs added throughout) |
| drivio | No CI | `.github/` absent; nothing has ever run | Critical | Add `flutter analyze` + `flutter test` workflow |
| drivio | Cannot run on device | `example/` has no `android/` or `ios/` | High | `flutter create --platforms=android,ios .` in `example/` |
| drivio | Dependency risk | `geolocator ^14.0.3` and `sensors_plus ^7.1.0` both move fast and both broke APIs in recent majors | Medium | Pin tighter for the app that consumes this, and let CI catch drift |
| drivio | Config risk | OSRM defaults to the public demo server (`router.project-osrm.org`); MapTiler key must be host-supplied | Medium | Self-host OSRM before any real usage; document key provisioning |
| drivio (PR #2) | **Expected to build** (by inspection) | Fixes both compile errors and the lint gate; adds 472 lines of tests | — | Merge, then let CI confirm |

*No build was executed. The environment has no Flutter or Dart SDK; these are
source-level conclusions.*

---

## Weekly Completion Summary

| Project | Completed item | Type | Impact |
|---|---|---|---|
| drivio | *(nothing)* | — | No commits on any branch since 2026-07-19 |

Three consecutive cycles with an empty Done column. That is the single most important fact
in this report.

---

## Current Work in Progress

| Project | Item | Status | Next action | Risk |
|---|---|---|---|---|
| drivio | PR #2 — lifecycle and reliability fixes | Draft, unchanged 7.5 weeks | Promote to ready, merge | High — the only path to a buildable `main` |
| drivio | PR #3 — Kanban report 2026-08-03 | Open | Merge or close | Low |
| drivio | PR #4 — Kanban report 2026-08-22 | Open | Merge or close | Low |
| drivio | 409 data-loss fix | Not started | Implement on top of PR #2 | High — silent telemetry loss |
| drivio | CI workflow | Not started | Add two-job workflow | High — nothing is verified |
| drivio | Background execution decision | Not started, 3 cycles old | Decide (see recommendation) | High — blocks the roadmap |

---

## Carryover Items

| Project | Item | Reason for carryover | New target |
|---|---|---|---|
| drivio | Merge PR #2 | Still marked draft; nobody promoted it. Carried from 2026-08-03 and 2026-08-22 | 2026-09-12 |
| drivio | Add CI | Never started | 2026-09-12 |
| drivio | Fix 409 handling | Never started; not covered by PR #2 | 2026-09-15 |
| drivio | `example/` platform folders | Never started | 2026-09-15 |
| drivio | Background-execution decision | No owner has made the call in three cycles | 2026-09-17 |
| drivio | Trip-resume semantics | Blocked behind the background decision | 2026-09-24 |
| drivio | Retention policy | Not started | 2026-10-01 |

Every item on this list is a carryover. Nothing new entered the board this week because
nothing left it.

---

## Planned Focus for Next Week

### drivio

- **Focus item:** Merge PR #2 and land the 409 fix on top of it.
- **Reason:** PR #2 is the only thing between this repository and a compiling build, and
  the 409 bug is the one remaining path that destroys user data outright.
- **Expected outcome:** `main` compiles, `flutter analyze` is clean, ~730 lines of tests
  pass, `0.1.1` tagged, and a conflicting chunk is retained rather than deleted.
- **Risk:** Low. PR #2 is additive and defensive; the 409 change is ~10 lines plus a test.
- **Definition of done:** CI green on `main`; a test asserts that a 409 response leaves the
  chunk file on disk and its status non-uploaded.

- **Focus item:** CI workflow + `example/` platform folders.
- **Reason:** Without these, nothing is ever verified and nothing ever runs on hardware.
- **Expected outcome:** Every push runs `flutter analyze` and `flutter test`; `flutter run`
  works in `example/` on an Android device.
- **Risk:** Low.
- **Definition of done:** A green CI badge on `main` and a recorded trip from a real phone.

- **Focus item:** Decide background execution; write it into the README.
- **Reason:** Three cycles of deferral. Every recorder change is provisional until it is
  settled.
- **Expected outcome:** A one-paragraph decision in the README plus a tracked task for the
  implementation path chosen.
- **Risk:** Medium — option (a) or (c) implies real platform-channel work.
- **Definition of done:** Decision written down and an issue opened for the implementation.

---

## Recommended Kanban Updates

**Move to Done**

- *(none)* — nothing completed this cycle.

**Move to In Progress**

- **Project:** drivio · **Item:** PR #2 promotion and merge
  **Reason:** It is finished work sitting in draft; promoting it is the single highest-value
  action available in this repository.
- **Project:** drivio · **Item:** 409 data-loss fix (`http_backend_client.dart:66-71`)
  **Reason:** Confirmed contract mismatch against the repo's own reference backend; causes
  permanent data loss.
- **Project:** drivio · **Item:** CI workflow
  **Reason:** Small, unblocked, and prerequisite to trusting anything else.

**Move to Blocked**

- **Project:** drivio · **Item:** Any further recorder feature work
  **Blocker:** Background-execution decision (see Blockers #1).
- **Project:** drivio · **Item:** On-device validation
  **Blocker:** `example/` has no platform folders.
- **Project:** drivio · **Item:** Trip-resume implementation
  **Blocker:** Depends on Blockers #1 and #2.

**Move to Ready**

- **Project:** drivio · **Item:** Generate `example/` platform folders
  **Reason:** One command; unblocks all hardware validation.
- **Project:** drivio · **Item:** Retry cap + backoff in `TelemetrySynchronizer`
  **Reason:** Self-contained; `retryCount` is already persisted and merely unread.
- **Project:** drivio · **Item:** `deleteTrip()` + retention purge
  **Reason:** Store interface change is well understood; only the policy needs the decision.
- **Project:** drivio · **Item:** Codec golden-fixture conformance tests
  **Reason:** Prevents Dart/Deno drift; can be written today.

**Move to Parked**

- **Project:** drivio · **Item:** Axis-calibration routine
  **Reason:** Needs on-device iteration, which is blocked on platform folders and the
  background decision. Uncalibrated candidates already carry reduced confidence.
- **Project:** drivio · **Item:** Self-hosted OSRM + MapTiler production keys
  **Reason:** Infrastructure spend that should not precede a working build.

---

## Final Recommendations

**The most important thing to fix first:** Promote PR #2 out of draft and merge it. It is
completed, reviewed-quality work that fixes two compile errors, a non-atomic manifest
write, two unlocked store methods, and a negative-delta varuint crash that silently
discards entire telemetry chunks — and it adds 472 lines of tests. It has been sitting one
click away from mergeable for seven and a half weeks. Nothing else in this repository can
be validated until it lands.

**Steps to get the project closer to release:**

1. Merge PR #2 → `main` compiles for the first time. Tag `0.1.1`.
2. Add the CI workflow → `analyze` + `test` on every push, so it stays compiling.
3. Fix the 409 path → the sync layer stops destroying the data it is meant to protect.
4. Generate `example/` platform folders → the package can finally run on a phone.
5. Record one real trip on an Android device and decode its chunks with
   `backend_reference/telemetry_decoder.ts` → first end-to-end proof the format works.
6. Decide background execution and implement the chosen path.
7. Add trip recovery, a retention purge, and a retry ceiling → the persistence layer
   becomes safe to leave running unattended.

**The item carrying the highest risk:** Background execution. Everything else on this list
is a bounded, well-understood fix. This one is an unanswered question at the centre of the
product's premise, and until it is answered the package's core promise — capture a whole
drive — is unproven. It is also the only item that could invalidate design decisions
already made in the recorder.

**The decision most urgently required:** The same one. Android foreground service owned by
the package, or an explicit host-app contract. Recommendation: hybrid — the package ships
the Android foreground service, iOS stays location-only with motion frames documented as
best-effort. Make the call by 2026-09-17.

**The recommended focus for the next 7 days:** Merge PR #2, add CI, fix the 409 bug,
generate the example platform folders, and record one real trip on real hardware. That
sequence turns `drivio` from a repository nobody can build into an internally testable
package with a verified end-to-end data path — and it is a week of work, not a quarter of
it. The gap between this project's architectural quality and its zero executions is the
whole problem; closing it does not require new design, only follow-through.
