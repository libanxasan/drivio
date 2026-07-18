import 'dart:async';

import 'package:sensors_plus/sensors_plus.dart';

import '../model/raw_motion_sample.dart';
import '../model/vector3_value.dart';
import 'motion_source.dart';

/// Motion source backed by sensors_plus.
class SensorMotionSource implements MotionSource {
  /// Creates a source.
  SensorMotionSource({
    this.samplingPeriod = const Duration(milliseconds: 40),
  });

  /// Requested sensor sampling period.
  final Duration samplingPeriod;

  final StreamController<RawMotionSample> _controller =
      StreamController<RawMotionSample>.broadcast();
  StreamSubscription<UserAccelerometerEvent>? _accelerometerSubscription;
  StreamSubscription<GyroscopeEvent>? _gyroscopeSubscription;
  Vector3Value _latestGyroscope = Vector3Value.zero;
  bool _started = false;

  @override
  Stream<RawMotionSample> get samples => _controller.stream;

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;

    _gyroscopeSubscription = gyroscopeEvents(
      samplingPeriod: samplingPeriod,
    ).listen(
      (event) {
        _latestGyroscope = Vector3Value(event.x, event.y, event.z);
      },
      onError: _controller.addError,
    );

    _accelerometerSubscription = userAccelerometerEvents(
      samplingPeriod: samplingPeriod,
    ).listen(
      (event) {
        _controller.add(
          RawMotionSample(
            timestampMicros: DateTime.now().toUtc().microsecondsSinceEpoch,
            userAcceleration: Vector3Value(event.x, event.y, event.z),
            gyroscope: _latestGyroscope,
          ),
        );
      },
      onError: _controller.addError,
    );
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    await _accelerometerSubscription?.cancel();
    await _gyroscopeSubscription?.cancel();
    _accelerometerSubscription = null;
    _gyroscopeSubscription = null;
  }

  /// Releases the stream controller.
  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}
