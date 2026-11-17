# Drivio example app

A complete trip-recording app built on `driving_telemetry`. It shows how a production app should wire the package:

- **Background recording.** `GeolocatorLocationSource` runs with `BackgroundLocationOptions`: an Android location foreground service with a notification, and iOS background location updates. A trip keeps recording with the screen off or another app in front.
- **Kill recovery.** At startup the app calls `recoverInterruptedTrips()` and shows a notice when a trip was closed after the OS killed the app. When the app goes to the background it calls `recorder.checkpoint()`, so a kill loses as little as possible.
- **SQLite storage.** `SqliteTelemetryStore`, with a one-time import of trips recorded by older builds that used `FileTelemetryStore`.
- **Uploads.** `TelemetrySyncScheduler` uploads while the app is open, backs off when the backend is unreachable and syncs as soon as connectivity returns (`connectivity_plus`). A WorkManager / BGTaskScheduler task calls `runBackgroundTelemetrySync` while the app is suspended or closed.
- **Live screen.** Elapsed time, speed, GPS accuracy, fix and event counts, a "Sensors paused" chip while the vehicle is stationary, the saved trip summary, upload status and trip history.

## Run

```sh
cd example
flutter run
```

Recording works with no backend. To enable uploads, point the app at an endpoint that accepts the package's upload contract, for example the Convex backend in [`docs/CONVEX_BACKEND.md`](../docs/CONVEX_BACKEND.md):

```sh
flutter run \
  --dart-define=DRIVIO_UPLOAD_URL=https://<deployment>.convex.site/v1/telemetry/chunks \
  --dart-define=DRIVIO_USER_ID=<user id from your auth provider> \
  --dart-define=DRIVIO_AUTH_TOKEN=<JWT>
```

| Define | Default | Purpose |
| --- | --- | --- |
| `DRIVIO_UPLOAD_URL` | empty (uploads off) | Chunk upload endpoint |
| `DRIVIO_USER_ID` | `example-user` | User stored with each trip and sent as `X-User-Id` |
| `DRIVIO_AUTH_TOKEN` | empty | Bearer token for uploads |
| `DRIVIO_MATCH_ROUTES` | `true` | Match finished trips against the public OSRM demo server |

The defines are compile-time constants so the background upload isolate sees the same values. A real app should read the token from its auth session instead.

## Platform setup included

**Android** (`android/app/src/main/AndroidManifest.xml`): fine, coarse and background location, `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_LOCATION`, wake lock, notifications (Android 13+), network state and boot-completed for WorkManager. Grant notifications in system settings on Android 13+ to see the recording notification.

**iOS** (`ios/Runner/Info.plist`, `AppDelegate.swift`): location and motion usage descriptions, `UIBackgroundModes` `location`, `fetch` and `processing`, the `BGTaskSchedulerPermittedIdentifiers` entry, and the WorkManager task registration. iOS decides when background refresh runs, so background uploads there are opportunistic; uploads also run every time the app opens.

## Testing on a device

1. Start a trip and lock the screen. Drive or walk for a few minutes, then stop the trip. GPS fixes should keep increasing while the screen is locked.
2. Start a trip, background the app, then kill it from the app switcher. Reopen it: the recovered-trip notice appears and the trip is in the history as "Recovered".
3. With uploads on, enable airplane mode, record a trip, then turn the network back on. The upload card should report the upload within seconds.
4. Stay parked for more than two minutes while recording: the "Sensors paused" chip appears and disappears when you drive off.

## Building with Codemagic

[`codemagic.yaml`](../codemagic.yaml) at the repository root defines three workflows:

| Workflow | What it does | Needs |
| --- | --- | --- |
| `tests` | Analyzer plus package and example tests, on every push and pull request | Nothing |
| `android-debug` | Debug APK to install directly on a phone | Nothing |
| `ios-testflight` | Signed build uploaded to TestFlight | Apple Developer account and an App Store Connect API key integration |

To enable uploads in those builds, add a `drivio` environment variable group with `DRIVIO_UPLOAD_URL`, `DRIVIO_USER_ID` and `DRIVIO_AUTH_TOKEN`, and reference it from the workflow.

## Tests

```sh
flutter test
```

The widget tests use an in-memory store and fake sources. They cover start, stop and save retry, live metrics, the recovered-trip notice, the checkpoint on backgrounding, and uploading on demand.
