import '../config/telemetry_configuration.dart';
import '../model/motion_frame.dart';
import '../model/raw_motion_sample.dart';
import 'online_statistics.dart';

/// Condenses high-frequency motion samples into fixed-duration frames.
class MotionFrameAggregator {
  /// Creates an aggregator.
  MotionFrameAggregator({
    required this.configuration,
  });

  /// Recorder settings.
  final TelemetryConfiguration configuration;

  int? _frameStartMillis;
  int? _lastTimestampMillis;

  final OnlineStatistics _longitudinal = OnlineStatistics();
  final OnlineStatistics _lateral = OnlineStatistics();
  final OnlineStatistics _vertical = OnlineStatistics();
  final OnlineStatistics _yaw = OnlineStatistics();
  final OnlineStatistics _pitch = OnlineStatistics();
  final OnlineStatistics _roll = OnlineStatistics();
  final OnlineStatistics _gyroMagnitude = OnlineStatistics();

  /// Adds a sample and returns a completed frame when the window advances.
  MotionFrame? add(RawMotionSample sample) {
    final timestampMillis = sample.timestampMicros ~/ 1000;
    _frameStartMillis ??= _alignedFrameStart(timestampMillis);

    final frameDurationMillis =
        configuration.motionFrameDuration.inMilliseconds;
    if (timestampMillis >= _frameStartMillis! + frameDurationMillis &&
        _longitudinal.count > 0) {
      final completed = _buildFrame(
        durationMillis: frameDurationMillis,
      );
      _resetWindow(_alignedFrameStart(timestampMillis));
      _addValues(sample);
      _lastTimestampMillis = timestampMillis;
      return completed;
    }

    _addValues(sample);
    _lastTimestampMillis = timestampMillis;
    return null;
  }

  /// Flushes the current partial frame.
  MotionFrame? flush() {
    if (_frameStartMillis == null || _longitudinal.count == 0) return null;
    final end = _lastTimestampMillis ?? _frameStartMillis!;
    final duration = (end - _frameStartMillis! + 1)
        .clamp(1, configuration.motionFrameDuration.inMilliseconds)
        .toInt();
    final frame = _buildFrame(durationMillis: duration);
    _resetWindow(null);
    return frame;
  }


  /// Clears any partial frame.
  void reset() => _resetWindow(null);

  int _alignedFrameStart(int timestampMillis) {
    final duration = configuration.motionFrameDuration.inMilliseconds;
    return timestampMillis - (timestampMillis % duration);
  }

  void _addValues(RawMotionSample sample) {
    final mapping = configuration.axisMapping;
    final acceleration = sample.userAcceleration;
    final gyroscope = sample.gyroscope;

    _longitudinal.add(mapping.forward.project(acceleration));
    _lateral.add(mapping.lateral.project(acceleration));
    _vertical.add(mapping.vertical.project(acceleration));

    _yaw.add(mapping.vertical.project(gyroscope));
    _pitch.add(mapping.lateral.project(gyroscope));
    _roll.add(mapping.forward.project(gyroscope));
    _gyroMagnitude.add(gyroscope.magnitude);
  }

  MotionFrame _buildFrame({required int durationMillis}) {
    final gyro = _gyroMagnitude.snapshot();
    final stability = (1 - (gyro.rms / 2.5)).clamp(0.0, 1.0).toDouble();
    return MotionFrame(
      startedAtMillis: _frameStartMillis!,
      durationMillis: durationMillis,
      longitudinalAcceleration: _longitudinal.snapshot(),
      lateralAcceleration: _lateral.snapshot(),
      verticalAcceleration: _vertical.snapshot(),
      yawRate: _yaw.snapshot(),
      pitchRate: _pitch.snapshot(),
      rollRate: _roll.snapshot(),
      phoneStability: stability,
      axisMappingCalibrated: configuration.axisMapping.isCalibrated,
    );
  }

  void _resetWindow(int? nextStart) {
    _frameStartMillis = nextStart;
    _lastTimestampMillis = null;
    _longitudinal.reset();
    _lateral.reset();
    _vertical.reset();
    _yaw.reset();
    _pitch.reset();
    _roll.reset();
    _gyroMagnitude.reset();
  }
}
