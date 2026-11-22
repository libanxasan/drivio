import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:driving_telemetry/driving_telemetry.dart';

import 'example_config.dart';
import 'live_stream.dart';
import 'trip_controller.dart';

/// Wires the package together the way a production app would.
class ExampleServices {
  ExampleServices._();

  /// Opens storage, signs in, recovers killed trips and builds a [TripController].
  static Future<TripController> create(ExampleConfig config) async {
    final store = SqliteTelemetryStore();
    await store.initialize();
    // Trips recorded by earlier versions of this example used the file store.
    await store.importFileStore(deleteImported: true);

    // Anonymous Convex sign-in. Offline on first launch: record locally and
    // sign in on a later start.
    final session = config.createSession();
    String? userId;
    try {
      userId = await session?.ensureSignedIn();
    } catch (_) {
      userId = null;
    }
    final online = session != null && userId != null;

    const configuration = TelemetryConfiguration();
    final synchronizer = online
        ? TelemetrySynchronizer(
            store: store, backend: config.createBackend(session))
        : null;

    // One GPS and one motion source, shared by automatic detection and the recorder.
    final locations = LeasedLocationSource.share(
      GeolocatorLocationSource(
        background: const BackgroundLocationOptions(
          notificationTitle: 'Drivio is recording',
          notificationText: 'Drives are recorded automatically.',
        ),
      ),
    );
    final motions = LeasedMotionSource.share(
      SensorMotionSource(samplingPeriod: configuration.motionSamplingPeriod),
    );

    final recorder = DrivingTelemetryRecorder(
      store: store,
      configuration: configuration,
      motionSource: LeasedMotionSource(motions),
      locationSource: LeasedLocationSource(locations),
      osrmClient: config.matchRoutes ? OsrmClient() : null,
      synchronizer: synchronizer,
    );

    // Must run before the first trip starts in this process.
    final recovered = await recorder.recoverInterruptedTrips();

    final scheduler = synchronizer == null
        ? null
        : TelemetrySyncScheduler(
            synchronizer: synchronizer,
            connectivity: Connectivity().onConnectivityChanged.map(
                  (results) => !results.contains(ConnectivityResult.none),
                ),
          );
    final owner = userId ?? 'local-user';

    return TripController(
      recorder: recorder,
      store: store,
      userId: owner,
      scheduler: scheduler,
      recovered: recovered,
      liveStream: online
          ? LiveStreamPublisher(recorder: recorder, session: session)
          : null,
      automatic: config.automatic
          ? AutomaticTripRecorder(
              recorder: recorder,
              location: LeasedLocationSource(locations),
              motion: LeasedMotionSource(motions),
              userId: () => owner,
            )
          : null,
      onDispose: store.close,
    );
  }
}
