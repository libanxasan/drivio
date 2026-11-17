import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:driving_telemetry/driving_telemetry.dart';

import 'example_config.dart';
import 'trip_controller.dart';

/// Wires the package together the way a production app would.
class ExampleServices {
  ExampleServices._();

  /// Opens storage, recovers killed trips and builds a [TripController].
  static Future<TripController> create(ExampleConfig config) async {
    final store = SqliteTelemetryStore();
    await store.initialize();
    // Trips recorded by earlier versions of this example used the file store.
    await store.importFileStore(deleteImported: true);

    const configuration = TelemetryConfiguration();
    final backend = config.createBackend();
    final synchronizer = backend == null
        ? null
        : TelemetrySynchronizer(store: store, backend: backend);

    final recorder = DrivingTelemetryRecorder(
      store: store,
      configuration: configuration,
      motionSource: SensorMotionSource(
        samplingPeriod: configuration.motionSamplingPeriod,
      ),
      locationSource: GeolocatorLocationSource(
        background: const BackgroundLocationOptions(
          notificationTitle: 'Drivio is recording',
          notificationText: 'Your trip is being recorded.',
        ),
      ),
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

    return TripController(
      recorder: recorder,
      store: store,
      userId: config.userId,
      scheduler: scheduler,
      recovered: recovered,
      onDispose: store.close,
    );
  }
}
