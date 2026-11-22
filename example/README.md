# Drivio example app

A complete trip-recording app built on `driving_telemetry`. It shows how a production app should wire the package:

- **Background recording.** `GeolocatorLocationSource` runs with `BackgroundLocationOptions`: an Android location foreground service with a notification, and iOS background location updates. A trip keeps recording with the screen off or another app in front.
- **Kill recovery.** At startup the app calls `recoverInterruptedTrips()` and shows a notice when a trip was closed after the OS killed the app. When the app goes to the background it calls `recorder.checkpoint()`, so a kill loses as little as possible.
- **SQLite storage.** `SqliteTelemetryStore`, with a one-time import of trips recorded by older builds that used `FileTelemetryStore`.
- **Uploads.** `TelemetrySyncScheduler` uploads while the app is open, backs off when the backend is unreachable and syncs as soon as connectivity returns (`connectivity_plus`). A WorkManager / BGTaskScheduler task calls `runBackgroundTelemetrySync` while the app is suspended or closed.
- **Live stream to Convex.** With a Convex deployment configured, the app signs in anonymously (Convex Auth), streams GPS points, motion frames and events to `streams:publish` every 5 seconds, and uploads archive chunks to the same deployment. Items recorded while offline reach the stream later through backfill.
- **Automatic recording.** With the switch on, GPS and the accelerometer start a trip when the phone is driving (15 km/h for 20 seconds and vehicle vibration) and stop it after 3 minutes still at walking speed or 10 minutes without a fix.
- **Live screen.** Elapsed time, speed, GPS accuracy, fix and event counts, a "Sensors paused" chip while the vehicle is stationary, the saved trip summary, upload status and trip history.

## Run

```sh
cd example
flutter run
```

Recording works with no backend. To stream and upload, point the app at a Convex deployment set up as in [`docs/CONVEX_BACKEND.md`](../docs/CONVEX_BACKEND.md):

```sh
flutter run --dart-define=DRIVIO_CONVEX_URL=https://<deployment>.convex.cloud
```

| Define | Default | Purpose |
| --- | --- | --- |
| `DRIVIO_CONVEX_URL` | empty (streaming and uploads off) | Convex deployment URL |
| `DRIVIO_CONVEX_SITE_URL` | derived from `DRIVIO_CONVEX_URL` | HTTP actions URL for chunk uploads |
| `DRIVIO_AUTOMATIC` | `true` | Start with automatic recording on |
| `DRIVIO_MATCH_ROUTES` | `true` | Match finished trips against the public OSRM demo server |

The defines are compile-time constants so the background upload isolate sees the same values. The anonymous session is kept in the app's support directory and shared with the background isolate.

## Platform setup included

**Android** (`android/app/src/main/AndroidManifest.xml`): fine, coarse and background location, `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_LOCATION`, wake lock, notifications (Android 13+), network state and boot-completed for WorkManager. Grant notifications in system settings on Android 13+ to see the recording notification.

**iOS** (`ios/Runner/Info.plist`, `AppDelegate.swift`): location and motion usage descriptions, `UIBackgroundModes` `location`, `fetch` and `processing`, the `BGTaskSchedulerPermittedIdentifiers` entry, and the WorkManager task registration. iOS decides when background refresh runs, so background uploads there are opportunistic; uploads also run every time the app opens.

## Testing on a device

1. Start a trip and lock the screen. Drive or walk for a few minutes, then stop the trip. GPS fixes should keep increasing while the screen is locked.
2. Start a trip, background the app, then kill it from the app switcher. Reopen it: the recovered-trip notice appears and the trip is in the history as "Recovered".
3. With uploads on, enable airplane mode, record a trip, then turn the network back on. The upload card should report the upload within seconds, and the stream's gap is filled from the archive.
4. Stay parked for more than two minutes while recording: the "Sensors paused" chip appears and disappears when you drive off.

## Building with Codemagic

[`codemagic.yaml`](../codemagic.yaml) at the repository root defines three workflows:

| Workflow | What it does | Needs |
| --- | --- | --- |
| `tests` | Analyzer plus package and example tests, on every push and pull request | Nothing |
| `android-debug` | Debug APK to install directly on a phone | Nothing |
| `ios-testflight` | Signed build uploaded to TestFlight | Apple Developer account and an App Store Connect API key integration |

To enable streaming and uploads in those builds, add a `drivio` environment variable group with `DRIVIO_CONVEX_URL` and reference it from the workflow.

## Tests

```sh
flutter test
```

The widget tests use an in-memory store and fake sources. They cover start, stop and save retry, live metrics, the recovered-trip notice, the checkpoint on backgrounding, and uploading on demand.
