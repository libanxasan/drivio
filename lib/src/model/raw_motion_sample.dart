import 'vector3_value.dart';

/// High-frequency motion sample retained temporarily or around an event.
class RawMotionSample {
  /// Creates a motion sample.
  const RawMotionSample({
    required this.timestampMicros,
    required this.userAcceleration,
    required this.gyroscope,
  });

  /// UTC timestamp in microseconds since Unix epoch.
  final int timestampMicros;

  /// Gravity-removed device acceleration in meters per second squared.
  final Vector3Value userAcceleration;

  /// Device angular velocity in radians per second.
  final Vector3Value gyroscope;
}
