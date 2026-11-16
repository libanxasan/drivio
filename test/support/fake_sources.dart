import 'dart:async';

import 'package:driving_telemetry/driving_telemetry.dart';

/// Motion source driven by tests.
class FakeMotionSource implements MotionSource {
  int startCount = 0;
  int stopCount = 0;
  bool running = false;

  final StreamController<RawMotionSample> controller =
      StreamController<RawMotionSample>.broadcast();

  @override
  Stream<RawMotionSample> get samples => controller.stream;

  @override
  Future<void> start() async {
    startCount++;
    running = true;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    running = false;
  }

  void emit(int timestampMillis) {
    controller.add(
      RawMotionSample(
        timestampMicros: timestampMillis * 1000,
        userAcceleration: const Vector3Value(0.1, 0.2, 0.3),
        gyroscope: Vector3Value.zero,
      ),
    );
  }
}

/// Location source driven by tests.
class FakeLocationSource implements LocationSource {
  int startCount = 0;
  int stopCount = 0;

  final StreamController<LocationSample> controller =
      StreamController<LocationSample>.broadcast();

  @override
  Stream<LocationSample> get samples => controller.stream;

  @override
  Future<void> start() async => startCount++;

  @override
  Future<void> stop() async => stopCount++;

  void emit(
    int timestampMillis, {
    double speedMps = 15,
    double latitude = 11.59,
    double longitude = 43.14,
  }) {
    controller.add(
      LocationSample(
        timestampMillis: timestampMillis,
        latitude: latitude,
        longitude: longitude,
        speedMps: speedMps,
        headingDegrees: 90,
        accuracyMeters: 5,
        altitudeMeters: 10,
        speedAccuracyMps: 0.5,
        headingAccuracyDegrees: 5,
        isMocked: false,
      ),
    );
  }
}

/// Lets queued microtasks and stream deliveries run.
Future<void> pump() => Future<void>.delayed(Duration.zero);
