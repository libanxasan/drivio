import 'dart:async';
import 'dart:io';

import 'package:driving_telemetry/driving_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

LocationSample fix(
  int t,
  double kph, {
  double accuracy = 5,
  bool mocked = false,
}) => LocationSample(
  timestampMillis: t,
  latitude: 11.57,
  longitude: 43.14,
  speedMps: kph / 3.6,
  headingDegrees: 90,
  accuracyMeters: accuracy,
  isMocked: mocked,
);

RawMotionSample shake(int t, double magnitude) => RawMotionSample(
  timestampMicros: t * 1000,
  userAcceleration: Vector3Value(magnitude, 0, 0),
  gyroscope: Vector3Value.zero,
);

/// Feeds [seconds] of fixes at [kph] and accelerometer samples at 25 Hz.
List<DriveDecision> drive(
  DriveDetector detector,
  int fromMs,
  int seconds,
  double kph, {
  double vibration = 0.6,
  bool motion = true,
}) {
  final decisions = <DriveDecision>[];
  for (var s = 0; s < seconds; s++) {
    final t = fromMs + s * 1000;
    if (motion) {
      for (var i = 0; i < 25; i++) {
        final d = detector.onMotion(
          shake(t + i * 40, i.isEven ? vibration : -vibration),
        );
        if (d != null) decisions.add(d);
      }
    }
    final d = detector.onLocation(fix(t, kph));
    if (d != null) decisions.add(d);
  }
  return decisions;
}

class _Source<T> {
  final controller = StreamController<T>.broadcast();
  int starts = 0;
  int stops = 0;
}

class _FakeLocation implements LocationSource {
  final _Source<LocationSample> s = _Source();
  @override
  Stream<LocationSample> get samples => s.controller.stream;
  @override
  Future<void> start() async => s.starts++;
  @override
  Future<void> stop() async => s.stops++;
}

class _FakeMotion implements MotionSource {
  final _Source<RawMotionSample> s = _Source();
  @override
  Stream<RawMotionSample> get samples => s.controller.stream;
  @override
  Future<void> start() async => s.starts++;
  @override
  Future<void> stop() async => s.stops++;
}

void main() {
  group('DriveDetector', () {
    test('starts after 20 s at driving speed with vehicle vibration', () {
      final detector = DriveDetector();
      expect(drive(detector, 0, 20, 30), isEmpty);
      expect(drive(detector, 20000, 2, 30), [DriveDecision.start]);
      expect(detector.isDriving, isTrue);
    });

    test('does not start on GPS drift while the phone lies still', () {
      final detector = DriveDetector();
      expect(drive(detector, 0, 60, 30, vibration: 0.05), isEmpty);
      expect(detector.isDriving, isFalse);
    });

    test('starts on GPS alone when no motion sensor reports', () {
      final detector = DriveDetector();
      expect(drive(detector, 0, 25, 30, motion: false), [DriveDecision.start]);
    });

    test(
      'ignores mocked and inaccurate fixes and restarts confirmation after a fix gap',
      () {
        final detector = DriveDetector();
        for (var s = 0; s < 30; s++) {
          expect(detector.onLocation(fix(s * 1000, 40, mocked: true)), isNull);
          expect(detector.onLocation(fix(s * 1000, 40, accuracy: 120)), isNull);
        }
        expect(drive(detector, 100000, 15, 30, motion: false), isEmpty);
        // 30 s without a fix: confirmation starts again.
        expect(drive(detector, 145000, 15, 30, motion: false), isEmpty);
        expect(drive(detector, 160000, 10, 30, motion: false), [
          DriveDecision.start,
        ]);
      },
    );

    test('a red light does not end the drive; parking for 3 minutes does', () {
      final detector = DriveDetector();
      drive(detector, 0, 30, 40);
      expect(detector.isDriving, isTrue);
      // 90 s stopped at a light, engine vibrating.
      expect(drive(detector, 30000, 90, 0, vibration: 0.5), isEmpty);
      expect(drive(detector, 120000, 30, 40), isEmpty);
      // Parked: stopped and still for 3 minutes.
      final decisions = drive(detector, 150000, 200, 0, vibration: 0.02);
      expect(decisions, [DriveDecision.stop]);
      expect(detector.isDriving, isFalse);
    });

    test('ends the drive when fixes stop arriving and the phone is still', () {
      final detector = DriveDetector();
      drive(detector, 0, 30, 40, motion: false);
      expect(detector.onTick(30000 + 9 * 60000), isNull);
      expect(detector.onTick(30000 + 10 * 60000), DriveDecision.stop);
    });
  });

  group('SourceLeases', () {
    test(
      'starts the shared source once and stops it with the last lease',
      () async {
        final location = _FakeLocation();
        final shared = LeasedLocationSource.share(location);
        final a = LeasedLocationSource(shared);
        final b = LeasedLocationSource(shared);
        await a.start();
        await b.start();
        await a.start();
        expect(location.s.starts, 1);
        await a.stop();
        expect(location.s.stops, 0);
        await b.stop();
        await b.stop();
        expect(location.s.stops, 1);
      },
    );
  });

  group('AutomaticTripRecorder', () {
    test(
      'records a drive from start to parking, sharing the sensors with the recorder',
      () async {
        final temporary = await Directory.systemTemp.createTemp('auto_trip_');
        addTearDown(() => temporary.delete(recursive: true));
        final location = _FakeLocation();
        final motion = _FakeMotion();
        final locations = LeasedLocationSource.share(location);
        final motions = LeasedMotionSource.share(motion);
        final recorder = DrivingTelemetryRecorder(
          store: FileTelemetryStore(rootDirectory: temporary),
          locationSource: LeasedLocationSource(locations),
          motionSource: LeasedMotionSource(motions),
        );
        var now = 0;
        final automatic = AutomaticTripRecorder(
          recorder: recorder,
          location: LeasedLocationSource(locations),
          motion: LeasedMotionSource(motions),
          userId: () => 'user-1',
          clock: () => now,
          tickInterval: const Duration(hours: 1),
        );
        final decisions = <DriveDecision>[];
        final errors = <Object>[];
        automatic.decisions.listen(decisions.add, onError: errors.add);
        await automatic.start();
        expect((location.s.starts, motion.s.starts), (1, 1));

        Future<void> feed(int seconds, double kph, double vibration) async {
          for (var s = 0; s < seconds; s++) {
            now += 1000;
            for (var i = 0; i < 25; i++) {
              motion.s.controller.add(
                shake(now + i * 40, i.isEven ? vibration : -vibration),
              );
            }
            location.s.controller.add(fix(now, kph));
            await Future<void>.delayed(Duration.zero);
          }
          await pumpEventQueue();
        }

        await feed(25, 35, 0.6);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(errors, isEmpty);
        expect(decisions, [DriveDecision.start]);
        expect(recorder.isRecording, isTrue);
        expect(recorder.activeTripId, isNotNull);
        // The recorder shares the running sensors instead of starting them again.
        expect((location.s.starts, motion.s.starts), (1, 1));

        await feed(200, 0, 0.02);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(errors, isEmpty);
        expect(decisions, [DriveDecision.start, DriveDecision.stop]);
        expect(recorder.isRecording, isFalse);
        expect(location.s.stops, 0, reason: 'detection keeps GPS running');

        await automatic.dispose();
        expect((location.s.stops, motion.s.stops), (1, 1));
        await recorder.dispose();
      },
    );
  });
}
