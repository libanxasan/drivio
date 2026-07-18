import 'dart:async';
import 'dart:io';

import 'package:driving_telemetry/driving_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeMotionSource implements MotionSource {
  final StreamController<RawMotionSample> controller =
      StreamController<RawMotionSample>.broadcast();

  @override
  Stream<RawMotionSample> get samples => controller.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

class _FakeLocationSource implements LocationSource {
  final StreamController<LocationSample> controller =
      StreamController<LocationSample>.broadcast();

  @override
  Stream<LocationSample> get samples => controller.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

void main() {
  test('records condensed telemetry without calculating a score', () async {
    final temporary = await Directory.systemTemp.createTemp('telemetry_recorder_');
    addTearDown(() => temporary.delete(recursive: true));

    final motion = _FakeMotionSource();
    final location = _FakeLocationSource();
    final recorder = DrivingTelemetryRecorder(
      store: FileTelemetryStore(rootDirectory: temporary),
      motionSource: motion,
      locationSource: location,
      configuration: const TelemetryConfiguration(
        motionFrameDuration: Duration(milliseconds: 500),
        minimumEventDuration: Duration(milliseconds: 100),
      ),
    );

    final tripId = await recorder.startTrip(userId: 'user-1');
    final base = DateTime.now().toUtc();

    location.controller.add(
      LocationSample(
        timestampMillis: base.millisecondsSinceEpoch,
        latitude: 11.57,
        longitude: 43.14,
        speedMps: 10,
        headingDegrees: 90,
        accuracyMeters: 5,
      ),
    );

    for (var index = 0; index < 30; index++) {
      motion.controller.add(
        RawMotionSample(
          timestampMicros:
              base.add(Duration(milliseconds: index * 40)).microsecondsSinceEpoch,
          userAcceleration: const Vector3Value(0.1, -0.2, 0.05),
          gyroscope: const Vector3Value(0.01, 0.02, 0.01),
        ),
      );
    }

    location.controller.add(
      LocationSample(
        timestampMillis:
            base.add(const Duration(seconds: 2)).millisecondsSinceEpoch,
        latitude: 11.5702,
        longitude: 43.1402,
        speedMps: 11,
        headingDegrees: 91,
        accuracyMeters: 5,
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 20));
    final result = await recorder.stopTrip();

    expect(result.tripId, tripId);
    expect(result.motionFrameCount, greaterThan(0));
    expect(result.locationSampleCount, 2);
    expect(result.chunkCount, greaterThan(0));
    expect(result.rawGpsDistanceMeters, greaterThan(0));

    await motion.controller.close();
    await location.controller.close();
    await recorder.dispose();
  });
}
