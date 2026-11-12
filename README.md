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

final store = FileTelemetryStore();

final recorder = DrivingTelemetryRecorder(
  store: store,
  configuration: configuration,
  motionSource: SensorMotionSource(
    samplingPeriod: configuration.motionSamplingPeriod,
  ),
  locationSource: GeolocatorLocationSource(),
  osrmClient: OsrmClient(),
);

final tripId = await recorder.startTrip(
  userId: userId,
  metadata: {
    'vehicleId': vehicleId,
  },
);

final TelemetryTripResult result = await recorder.stopTrip();
```

The recorder does not require a live monitoring screen. The host application only needs to start and stop the trip session, or connect these operations to automatic trip detection.

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

## Local storage structure

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

`GeolocatorLocationSource` accepts any `LocationSettings`. The host application can supply Android-specific settings with a foreground notification:

```dart
final source = GeolocatorLocationSource(
  locationSettings: AndroidSettings(
    accuracy: LocationAccuracy.bestForNavigation,
    distanceFilter: 0,
    intervalDuration: const Duration(seconds: 1),
    foregroundNotificationConfig: const ForegroundNotificationConfig(
      notificationTitle: 'Driving analysis active',
      notificationText: 'Trip telemetry is being recorded securely.',
      enableWakeLock: true,
    ),
  ),
);
```

Add `geolocator_android` as a direct host-application dependency when importing `AndroidSettings`.

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

Enable the `Location updates` background mode in Xcode when background recording is required.

The host application can supply `AppleSettings` to `GeolocatorLocationSource`. iOS controls background execution and may suspend motion processing depending on application state and system policy. Location background capability does not guarantee unrestricted sensor execution.

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
