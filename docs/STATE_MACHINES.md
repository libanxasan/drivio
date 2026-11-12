# Drivio state machines

Drivio contains the `driving_telemetry` Flutter package, one example screen, and an optional Supabase ingestion reference. The host app owns navigation, automatic trip detection, and mobile background execution. Backend processing after ingestion belongs to a separate worker.

## State ownership

| Owner | States and transitions | Boundary or failure to watch |
| --- | --- | --- |
| [Example screen](../example/lib/main.dart) | Ready → starting → recording → saving → saved or retryable failure. The widget keeps the last result and action error. The recorder supplies the lifecycle. | Disable the action during startup and finalization, and cancel the UI subscription when the widget leaves the tree. |
| [Recorder](../lib/src/recording/driving_telemetry_recorder.dart) | Idle → starting → recording → stopping → idle. Failed startup tears down sources and returns to idle. Disposal waits for in-flight work before publishing disposed. | A failed save has a retryable checkpoint. Only one trip can own the recorder and its buffers. |
| [Trip save](../lib/src/recording/driving_telemetry_recorder.dart) | Stop collection → flush buffers → write chunks → attempt route matching → write summary artifact → close the local manifest → read the result. | Resume at the unfinished step using the same chunk IDs and indexes. The retry checkpoint lives in memory. |
| [Location source](../lib/src/recording/geolocator_location_source.dart) | Stopped → service check → permission check or prompt → subscribed → stopped or disposed. | A disabled service or unavailable permission fails startup. A standalone caller can race `stop` against the permission prompt. The recorder stays in `recording` if the source stream completes. |
| [Motion source](../lib/src/recording/sensor_motion_source.dart) | Stopped → gyroscope and accelerometer subscribed → stopped or disposed. Accelerometer readings use the last gyroscope reading. | A source can fail while opening its second subscription. The gyroscope cache can survive a stop and feed the first reading of the next trip. |
| [Local store and trip manifest](../lib/src/storage/file_telemetry_store.dart) | Uninitialized → directories ready. Per trip, absent → `recording` → `closed`. Payload file writes precede manifest updates. | Interrupted startup or process death can leave an open manifest. Reusing a caller-supplied trip ID can replace the existing manifest. |
| [Continuous chunk buffer](../lib/src/recording/driving_telemetry_recorder.dart) | Empty → collecting → flushed by duration, size, or stop → queued → written or retained for retry. | Samples from different streams can arrive out of timestamp order. Keep chunk identity stable across save retries. |
| [Threshold detectors](../lib/src/event/candidate_event_detector.dart) | Acceleration, braking, swerving, lane change, speeding, phone movement, and GPS quality loss each move from clear → active → discarded or emitted. Emission starts a cooldown. Stop also closes active intervals. | GPS quality and phone movement use different duration rules at normal completion and at stop. Speeding also depends on the current effective speed limit. |
| [Speed-limit and GPS context](../lib/src/event/candidate_event_detector.dart) | Speed limit unknown → supplied → replaced or reset. Location updates replace the latest fix used for candidate context. The recorder separately tracks the last valid fix for distance. | An active speeding interval can finish after the effective limit changes. The [provider chain](../lib/src/network/speed_limit_provider.dart) resolves backend, OSM, and statutory values per request. |
| [Evidence capture](../lib/src/event/event_evidence_capture.dart) | A candidate seeds a capture from recent samples → post-event samples accumulate → capture is queued at the deadline or when the trip ends. | The completion watermark comes from arriving samples. A late sample from the other source can arrive after the capture closes. The [ring buffer](../lib/src/event/time_ring_buffer.dart) evicts old data as samples arrive. |
| [Motion frames](../lib/src/aggregation/motion_frame_aggregator.dart) and [hourly aggregates](../lib/src/aggregation/hourly_aggregator.dart) | Empty → accumulate within a window → emit and rotate on a boundary, or flush on stop. Statistics reset between windows. | A delayed frame or event can move the hourly accumulator back into an earlier hour. Test timestamp ordering before changing aggregation rules. |
| [Route matching](../lib/src/network/osrm_client.dart) | Skipped for an insufficient trace, or matching overlapping batches → matched or failed. A matched route can then be stored as a JSON artifact. | A route failure is reported independently of the local trip save. Each batch has a request timeout. |
| [Chunk synchronization](../lib/src/network/telemetry_synchronizer.dart) | A pass initializes the store and selects pending work. Each chunk goes `pending`, `failed`, or interrupted `uploading` → `uploading` → `uploaded` or `failed`. Acknowledgement can trigger local cleanup. | Passes for the same store instance run in order. Cleanup failure leaves the upload acknowledged. A missing payload can still count as pending while queue enumeration skips it. |
| [HTTP upload receipt](../lib/src/network/http_backend_client.dart) | Request → accepted, duplicate acknowledgement, rejection, or transport failure. The receipt controls whether the synchronizer can acknowledge the chunk. | The bundled server sends 2xx for a matching duplicate and a JSON 409 for a checksum conflict. An empty 409 remains a legacy acknowledgement. A populated 409 requires an explicit duplicate receipt. |
| [Reference ingestion](../backend_reference/supabase/functions/telemetry-upload/index.ts) | Validate request and checksum → look up an existing chunk → acknowledge a duplicate, reject a conflict, or store bytes and insert metadata. Apply a final trip manifest when present. | Storage, the chunk insert, and manifest application span separate operations. Retry and ownership checks need to cover the whole sequence. |
| [Reference trip and processing records](../backend_reference/supabase_schema.sql) | A trip is created as `recording` and closed by the final manifest. Ingested chunks start with `processing_status = 'pending'`. | The reference upsert can reset a closed trip when another chunk arrives. Processing completion and failure fields are present for a future worker. |

The binary reader and writer maintain a cursor and delta bases for a single payload. MapTiler and the speed-limit providers resolve requests without retaining a workflow across calls. Model enums such as chunk type and travel direction describe input or output values.

## Recorder integration

Read `recorder.state` for the initial value and listen to `recorder.states` for subsequent transitions. On an idle state, check `recorder.canRetryTripSave` before offering a new trip. When it is true, call `stopTrip()` again to finish the same trip. A retry preserves the original end time and skips completed steps. A successful stop returns the usual `TelemetryTripResult` and permits another trip.

Call and await `dispose()` from the recorder owner. Disposal during startup or saving joins the in-flight operation, then closes the recorder streams. It attempts to save an active trip or a pending save if none is already in progress. Keep the recorder alive while presenting a retry to the user. After process death, successfully persisted files are the starting point for recovery.

## Upload integration

Use one store instance for a queue within an isolate. `synchronize()` can run before the first trip and retries interrupted uploads from disk with the original idempotency key. An upload or acknowledgement failure increments `failed`. A local cleanup failure increments `cleanupFailed` and leaves the chunk marked `uploaded`. The caller owns retry scheduling.

## Regression checks

- `flutter analyze` and `flutter test` at the package root.
- `flutter test` in `example/` for the sample screen's start, stop, and save retry.
- Run a trip on Android and iOS when integrating a host app to exercise real permissions, sensor collection, and OS lifecycle behavior.
