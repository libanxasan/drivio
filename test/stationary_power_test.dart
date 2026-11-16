import 'package:driving_telemetry/driving_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_sources.dart';
import 'support/stores.dart';

void main() {
  Future<(DrivingTelemetryRecorder, FakeMotionSource, FakeLocationSource)>
      startRecorder(TelemetryConfiguration configuration) async {
    final recorder = DrivingTelemetryRecorder(
      store: FileTelemetryStore(
        rootDirectory: await temporaryDirectory(addTearDown),
      ),
      motionSource: FakeMotionSource(),
      locationSource: FakeLocationSource(),
      configuration: configuration,
    );
    await recorder.startTrip(userId: 'user-1');
    return (
      recorder,
      recorder.motionSource as FakeMotionSource,
      recorder.locationSource as FakeLocationSource,
    );
  }

  const configuration = TelemetryConfiguration(
    stationaryDuration: Duration(seconds: 10),
  );

  test('pauses motion sensors after a stationary period', () async {
    final (recorder, motion, location) = await startRecorder(configuration);
    expect(motion.running, isTrue);

    location.emit(0, speedMps: 0);
    location.emit(5000, speedMps: 0);
    await pump();
    expect(recorder.isMotionPaused, isFalse);

    location.emit(10000, speedMps: 0.5);
    await pump();
    await pump();
    expect(recorder.isMotionPaused, isTrue);
    expect(motion.running, isFalse);

    location.emit(12000, speedMps: 3);
    await pump();
    await pump();
    expect(recorder.isMotionPaused, isFalse);
    expect(motion.running, isTrue);
    expect(motion.startCount, 2);

    await recorder.dispose();
  });

  test('movement resets the stationary timer', () async {
    final (recorder, motion, location) = await startRecorder(configuration);

    location.emit(0, speedMps: 0);
    location.emit(6000, speedMps: 10);
    location.emit(12000, speedMps: 0);
    await pump();
    expect(recorder.isMotionPaused, isFalse);
    expect(motion.running, isTrue);

    await recorder.dispose();
  });

  test('resumes after moving away even without a speed reading', () async {
    final (recorder, motion, location) = await startRecorder(configuration);

    location.emit(0, speedMps: 0);
    location.emit(10000, speedMps: 0);
    await pump();
    await pump();
    expect(recorder.isMotionPaused, isTrue);

    location.emit(20000, speedMps: 0, latitude: 11.5910);
    await pump();
    await pump();
    expect(recorder.isMotionPaused, isFalse);
    expect(motion.running, isTrue);

    await recorder.dispose();
  });

  test('stays active when pausing is disabled', () async {
    final (recorder, motion, location) = await startRecorder(
      const TelemetryConfiguration(
        pauseMotionWhenStationary: false,
        stationaryDuration: Duration(seconds: 10),
      ),
    );

    location.emit(0, speedMps: 0);
    location.emit(20000, speedMps: 0);
    await pump();
    expect(recorder.isMotionPaused, isFalse);
    expect(motion.running, isTrue);

    await recorder.dispose();
  });
}
