# driving_telemetry

A Flutter package for collecting compact driving telemetry. It records raw location and motion data, condenses continuous telemetry, preserves high-resolution evidence around significant candidate events, stores data locally, matches completed routes through OSRM, and uploads chunks to an application backend.

The package does not calculate driver scores. Scoring and final infraction validation belong in the backend.

## Responsibilities

The package provides:

- User accelerometer and gyroscope collection
- GPS location, speed, heading, accuracy, and mock-location metadata
- One-second statistical motion frames
- Candidate event detection for data-retention purposes
- High-resolution event evidence windows
- Hourly telemetry aggregates
- Delta-encoded compact binary chunks
- Gzip compression and SHA-256 integrity checks
- Atomic local file persistence
- Resumable and idempotent backend upload
- OSRM Match integration for post-trip route reconstruction
- MapTiler style URLs and reverse geocoding
- OpenStreetMap `maxspeed` parsing
- Backend-first speed-limit precedence interfaces

The backend remains responsible for:

- Confirming or rejecting event candidates
- Applying backend road-rule overrides
- Calculating global and category scores
- Reprocessing historical telemetry
- Detecting final wrong-way or traffic-signal infractions
- Producing driver and fleet reports

## Data-retention model

| Data | Collection | Permanent local representation |
|---|---:|---|
| User accelerometer | 25 Hz by default | One-second statistics |
| Gyroscope | 25 Hz by default | One-second statistics |
| GPS while moving | Platform dependent, normally near 1 Hz | Delta-encoded points |
| Raw motion | High frequency | Only short event windows |
| Candidate events | As detected | Compact event summaries |
| Hourly data | Once per hour | Statistical aggregate |
| Matched route | After trip | Compressed JSON artifact |

The default event evidence window keeps five seconds before and five seconds after each candidate event.

## Compact binary format

Continuous chunks use a versioned format with the magic value `DTL1`.

The codec uses:

- Variable-length unsigned integers
- ZigZag signed integers
- Delta timestamps
- Delta latitude and longitude
- Integer quantization
- Gzip compression
- SHA-256 checksums

Examples of quantization:

| Field | Stored unit |
|---|---|
| Latitude and longitude | Degrees multiplied by 10,000,000 |
| Speed | Centimeters per second |
| Heading | Hundredths of a degree |
| Accuracy | Decimeters |
| Acceleration | Millimeters per second squared |
| Angular velocity | Milliradians per second |

## Installation

```yaml
dependencies:
  driving_telemetry:
    path: ../driving_telemetry
```

## Basic integration

```dart
final configuration = const TelemetryConfiguration(
  motionSamplingPeriod: Duration(milliseconds: 40),
  motionFrameDuration: Duration(seconds: 1),
  chunkMaximumDuration: Duration(minutes: 1),
  eventEvidenceBefore: Duration(seconds: 5),
  eventEvidenceAfter: Duration(seconds: 5),
);

final store = SqliteTelemetryStore();
await store.initialize();
// One-time move of trips recorded with FileTelemetryStore.
await store.importFileStore(deleteImported: true);

final recorder = DrivingTelemetryRecorder(
  store: store,
  configuration: configuration,
  motionSource: SensorMotionSource(
    samplingPeriod: configuration.motionSamplingPeriod,
  ),
  // Keeps recording when the screen is off or another app is in front.
  locationSource: GeolocatorLocationSource(
    background: const BackgroundLocationOptions(),
  ),
  osrmClient: OsrmClient(),
);

// Close trips left open by a process the OS killed while recording.
final List<RecoveredTrip> recovered = await recorder.recoverInterruptedTrips();

final tripId = await recorder.startTrip(
  userId: userId,
  metadata: {
    'vehicleId': vehicleId,
  },
);

final TelemetryTripResult result = await recorder.stopTrip();
```

The recorder does not require a live monitoring screen. The host application only needs to start and stop the trip session, or connect these operations to automatic trip detection.

## Surviving the app being killed

Mobile operating systems kill background apps under memory pressure, and users swipe apps away. The package limits what is lost:

- Buffered samples are written to storage at least every `TelemetryConfiguration.checkpointInterval` (30 s by default), even when no new samples arrive.
- `recorder.checkpoint()` writes buffered samples immediately. Call it when the app moves to the background:

  ```dart
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(recorder.checkpoint());
    }
  }
  ```

- On the next start, `recorder.recoverInterruptedTrips()` (or `TelemetryTripRecovery(store).recover()`) closes every trip still marked `recording`. It ends the trip at its last persisted chunk, writes a trip manifest artifact with `recovered: true`, and leaves the chunks queued for upload. Recovery is idempotent and never touches the recorder's own trip. Do not run it while another isolate may still be recording.

## Performance

- `SqliteTelemetryStore` keeps trips, chunk state and compressed payloads in one WAL-mode database. Each write is one transaction instead of a rewrite of the whole trip manifest, pending uploads come from an index, and several isolates can open the database at once.
- gzip and SHA-256 run before the store takes its lock, and in a background isolate for payloads of 16 KiB or more (`PayloadCompressor.isolateThresholdBytes`), so writing a chunk does not drop UI frames.

## Battery

- With `pauseMotionWhenStationary` (on by default), motion sensors stop after the vehicle has stayed at or below `stationarySpeedKph` for `stationaryDuration` (2 min), for example at a long red light or in a parking lot. They resume when GPS speed reaches `resumeMotionSpeedKph` or the phone moves more than 50 m. GPS keeps running throughout, so no movement is missed.
- `GeolocatorLocationSource` uses a 1 s fused-location interval on Android and the automotive navigation activity type on iOS, which lets the OS optimize GPS power for driving.
- GPS settings are not changed during a trip. Restarting the location stream in the background stops the Android foreground service and can suspend an iOS app, which would end recording.

## Backend synchronization

```dart
final backend = HttpTelemetryBackendClient(
  endpoint: Uri.parse(
    'https://api.example.com/v1/telemetry/chunks',
  ),
  authorizationTokenProvider: () async {
    return supabase.auth.currentSession?.accessToken;
  },
);

final synchronizer = TelemetrySynchronizer(
  store: store,
  backend: backend,
  deleteUploadedContinuousChunks: true,
  deleteUploadedEventEvidence: false,
);

final recorder = DrivingTelemetryRecorder(
  store: store,
  motionSource: SensorMotionSource(),
  locationSource: GeolocatorLocationSource(),
  synchronizer: synchronizer,
);

await recorder.synchronizePendingData();
```

Failed chunks are retried with exponential backoff and jitter (`UploadRetryPolicy`, 30 s doubling to 1 h by default). A pass stops early after a network error, a timeout or an HTTP 429 or 503, instead of trying every queued chunk against a backend it cannot reach. `TelemetrySyncResult` reports `deferred`, `remaining` and `interrupted` counts.

### Scheduling uploads

While the app runs, `TelemetrySyncScheduler` uploads every 5 minutes, backs off after failures and syncs immediately when connectivity returns:

```dart
final scheduler = TelemetrySyncScheduler(
  synchronizer: synchronizer,
  connectivity: Connectivity()
      .onConnectivityChanged
      .map((results) => !results.contains(ConnectivityResult.none)),
)..start();
```

For uploads while the app is suspended or closed, register an OS background task (WorkManager on Android, `BGTaskScheduler` on iOS) and call `runBackgroundTelemetrySync`. It stops starting new uploads after its time budget (25 s by default) and returns `false` so the OS retries later:

```dart
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, input) async {
    final store = SqliteTelemetryStore();
    final synchronizer = TelemetrySynchronizer(store: store, backend: backend);
    try {
      return await runBackgroundTelemetrySync(synchronizer);
    } finally {
      await store.close();
    }
  });
}
```

Use `SqliteTelemetryStore` when uploads run in a background isolate. `FileTelemetryStore` has no cross-isolate locking. Uploads are idempotent, so a chunk sent from two isolates at once is acknowledged as a duplicate.

### Upload contract

The default HTTP client sends the compressed payload as `application/octet-stream` with `content-encoding: gzip`.

Headers:

```text
Idempotency-Key: {tripId}:{chunkId}
X-Trip-Id
X-User-Id
X-Chunk-Id
X-Chunk-Index
X-Chunk-Type
X-Schema-Version
X-Payload-Format
X-Checksum-Sha256
X-Started-At-Ms
X-Ended-At-Ms
```

The backend should return a 2xx status for an accepted upload or a duplicate with the same checksum. For legacy endpoints, an empty HTTP 409 is still an acknowledgement. A 409 response with a body needs `alreadyExisted: true` and may include `accepted: true`. Other conflict responses leave the local chunk queued for retry.

`TelemetrySyncResult.cleanupFailed` counts acknowledged chunks whose local files could not be removed. These chunks remain uploaded in the manifest.

The optional [Convex backend](docs/CONVEX_BACKEND.md) accepts this upload contract and adds trip location search and GPS replay. The guide includes local and cloud setup, authentication and a smoke test.

## Local storage structure

`SqliteTelemetryStore` (recommended) stores everything in `driving_telemetry/telemetry.db`: a `trips` table and a `chunks` table holding chunk metadata, upload state and the compressed payload. Deleting an uploaded chunk clears its payload and keeps its row.

`FileTelemetryStore` uses one directory per trip:

```text
driving_telemetry/
  trips/
    {tripId}/
      manifest.json
      chunks/
        chunk_*.dtl.gz
        evidence_*.dtl.gz
        hour_*.dtl.gz
        route_*.json.gz
```

The manifest tracks:

- Chunk type
- Schema version
- Compressed size
- SHA-256 checksum
- Upload status
- Retry count
- Last upload error

## OSRM integration

The recorder optionally calls OSRM Match after the trip ends.

```dart
final osrm = OsrmClient(
  configuration: const OsrmConfiguration(
    baseUrl: 'https://router.project-osrm.org',
    profile: 'driving',
    maximumPointsPerRequest: 80,
  ),
);
```

Large traces are split into overlapping requests. OSRM coordinates are sent in `longitude,latitude` order with timestamps and location-accuracy radiuses.

For production, use a self-hosted or managed OSRM server rather than depending permanently on the shared demonstration endpoint.

## MapTiler integration

```dart
final mapTiler = MapTilerClient(
  configuration: MapTilerConfiguration(
    apiKey: mapTilerApiKey,
    styleId: 'streets-v2',
  ),
);

final mapStyleUrl = mapTiler.styleUrl;

final street = await mapTiler.reverseGeocode(
  longitude: 43.1456,
  latitude: 11.5729,
);
```

The host application can pass `mapStyleUrl` to a MapLibre-compatible Flutter map widget.

Review MapTiler licensing and retention rules before persisting or redistributing reverse-geocoding results. The recorder does not automatically store MapTiler responses.

## Speed-limit precedence

The package exposes a composite provider:

```text
Backend override
    ↓
OpenStreetMap maxspeed
    ↓
Optional statutory fallback
    ↓
Unknown
```

```dart
final provider = CompositeSpeedLimitProvider(
  backend: backendSpeedLimitProvider,
  openStreetMap: const OpenStreetMapSpeedLimitProvider(),
  fallback: statutoryProvider,
);
```

The OpenStreetMap parser supports:

- Numeric kilometer-per-hour values
- `km/h`, `kmh`, and `kph`
- `mph` conversion
- `maxspeed:forward`
- `maxspeed:backward`
- General `maxspeed`

The effective limit may be supplied to the recorder to retain candidate speeding windows:

```dart
recorder.updateEffectiveSpeedLimit(limit);
```

This does not calculate a speeding score.

## Vehicle-axis calibration

Default device-axis assumptions are not reliable for every mounting position. A calibrated mapping should be supplied when possible:

```dart
const mapping = VehicleAxisMapping(
  forward: SignedSensorAxis(SensorAxis.y, sign: -1),
  lateral: SignedSensorAxis(SensorAxis.x),
  vertical: SignedSensorAxis(SensorAxis.z),
  isCalibrated: true,
);

const configuration = TelemetryConfiguration(
  axisMapping: mapping,
);
```

Uncalibrated maneuver candidates receive lower confidence.

## Android configuration

Add location and foreground-service permissions as appropriate for the host application's target SDK:

```xml
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
```

Pass `BackgroundLocationOptions` to run location updates in a foreground service with a persistent notification and a wake lock, so recording continues with the screen off:

```dart
final source = GeolocatorLocationSource(
  background: const BackgroundLocationOptions(
    notificationTitle: 'Driving analysis active',
    notificationText: 'Trip telemetry is being recorded securely.',
  ),
);
```

Start trips while the app is in the foreground. Android 12 and later do not allow a foreground service to start from the background. A trip started in the foreground keeps running with "While in use" permission; set `requireAlwaysPermission: true` only if trips start from the background.

`GeolocatorLocationSource` still accepts any `LocationSettings` through `locationSettings`, which overrides the defaults above.

## iOS configuration

Add:

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Location is used to record trip telemetry.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Location is used to record active trips in the background.</string>
<key>NSMotionUsageDescription</key>
<string>Motion sensors are used to record driving telemetry.</string>
```

Enable the `Location updates` background mode in Xcode when background recording is required:

```xml
<key>UIBackgroundModes</key>
<array>
  <string>location</string>
  <string>fetch</string>
  <string>processing</string>
</array>
```

`fetch` and `processing` are needed only for background uploads with `BGTaskScheduler`. With `BackgroundLocationOptions`, `GeolocatorLocationSource` sets `allowsBackgroundLocationUpdates`, turns off automatic pausing and shows the blue background-location indicator. iOS controls background execution and may suspend motion processing depending on application state and system policy. Location background capability does not guarantee unrestricted sensor execution.

## Candidate events

Candidate events exist to preserve useful evidence, not to accuse or score the driver.

Included candidates:

- Harsh acceleration
- Harsh braking
- Swerving pattern
- Abrupt lane-change pattern
- Speeding interval
- Phone movement
- GPS quality loss

External map or backend components may record:

- Wrong-way candidate
- Signalized intersection crossing candidate

```dart
recorder.recordExternalCandidate(candidate);
```

## Hourly aggregates

Hourly records include:

- GPS distance
- Moving duration
- Speed statistics
- Longitudinal acceleration statistics
- Lateral acceleration statistics
- Yaw-rate statistics
- Location quality counts
- Candidate event counts

Hourly data is an index for reporting. One-second motion frames and event evidence remain the primary backend analysis dataset.

## Privacy and security

The package records sensitive location and motion data. A production application should:

- Explain collection clearly before requesting permissions
- Encrypt data at rest when required by the threat model
- Use TLS for uploads
- Apply Supabase Row Level Security or equivalent authorization
- Define raw-data retention periods
- Allow users to delete trips
- Restrict access to event evidence
- Record backend processing and override audit history

## Trip completion

Stopping a trip creates a compressed JSON `tripManifest` artifact. The reference backend uses it to close the trip and persist final telemetry metadata.

Use `recorder.states` to drive the host UI. If `stopTrip()` throws and `recorder.canRetryTripSave` is true, call `stopTrip()` again to finish saving the same trip. See [Drivio state machines](docs/STATE_MACHINES.md) for the full transition inventory.
