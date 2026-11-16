## 0.2.0

Reliability, performance and battery improvements.

- Background recording: `BackgroundLocationOptions` runs location updates in an Android foreground service with a wake lock, and enables iOS background updates with automatic pausing turned off.
- Kill recovery: `recorder.recoverInterruptedTrips()` and `TelemetryTripRecovery` close trips left open by a killed process. Buffered samples are flushed at least every `checkpointInterval` (30 s), and `recorder.checkpoint()` flushes on demand.
- `SqliteTelemetryStore`: WAL-mode SQLite storage with atomic writes, indexed pending queries, safe access from several isolates, and `importFileStore` for existing data. `TelemetryStore` gains `listTrips()`.
- Compression and checksums run outside the store lock and in a background isolate for payloads of 16 KiB or more (`PayloadCompressor`).
- Uploads: `UploadRetryPolicy` adds per-chunk exponential backoff with jitter, a pass stops after network errors, timeouts, 429 or 503, and `synchronize` accepts a `timeBudget`. `TelemetrySyncScheduler` runs foreground passes with backoff and connectivity triggers, and `runBackgroundTelemetrySync` serves WorkManager and BGTaskScheduler tasks.
- Battery: motion sensors pause while the vehicle is stationary and resume on movement (`pauseMotionWhenStationary`).
- Requires Dart 3.10 and Flutter 3.38 or later (for `sqlite3` 3.x).

## 0.1.1

Stability and reliability fixes.

- Fixed compile errors: `Duration` comparisons in const constructor asserts
  (`TelemetryConfiguration`, `OsrmConfiguration`), the return type of
  `DrivingTelemetryRecorder.synchronizePendingData`, and the sensors_plus 7.x
  stream API usage in `SensorMotionSource`.
- Duration settings are now validated at runtime via
  `TelemetryConfiguration.validate` and `OsrmConfiguration.validate`, called by
  `DrivingTelemetryRecorder` and `OsrmClient`.
- A failed `startTrip` now stops any source it had already started, and a
  failed `stopTrip` returns the recorder to `idle` instead of leaving it stuck
  in `stopping`. Source teardown errors are reported through the `errors`
  stream so buffered telemetry can still be persisted.
- Chunk time ranges are computed from every contained element, so an event
  that started before other buffered data or an out-of-order GPS timestamp no
  longer aborts a chunk write.
- The binary encoder clamps time deltas, event durations, and speed fields
  instead of throwing, so a single irregular value cannot lose a whole chunk.
  The decoder rejects unknown chunk and event type indexes with a
  `FormatException` instead of a `RangeError`.
- Manifest writes now rename over the destination for a smaller crash window,
  and `FileTelemetryStore.initialize` is serialized against concurrent calls.
- A failure while recording an upload error no longer aborts the remaining
  chunks in a `TelemetrySynchronizer` pass.
- All source errors are delivered as data events on the recorder `errors`
  stream, matching its documented contract.
- All public enum members are documented; `flutter analyze` is clean.

## 0.1.0

- Initial compact telemetry recorder.
- One-second motion statistics.
- Delta-encoded binary chunks with Gzip compression.
- Local file persistence and resumable upload queue.
- Significant event evidence windows.
- OSRM Match integration.
- MapTiler map and reverse-geocoding helpers.
- OpenStreetMap maxspeed parsing with backend override support.
