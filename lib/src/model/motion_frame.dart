import 'axis_statistics.dart';

/// Condensed vehicle-relative motion data for a fixed time window.
class MotionFrame {
  /// Creates a condensed frame.
  const MotionFrame({
    required this.startedAtMillis,
    required this.durationMillis,
    required this.longitudinalAcceleration,
    required this.lateralAcceleration,
    required this.verticalAcceleration,
    required this.yawRate,
    required this.pitchRate,
    required this.rollRate,
    required this.phoneStability,
    required this.axisMappingCalibrated,
  });

  /// Frame start time in milliseconds since Unix epoch.
  final int startedAtMillis;

  /// Frame duration.
  final int durationMillis;

  /// Forward and backward acceleration statistics.
  final AxisStatistics longitudinalAcceleration;

  /// Sideways acceleration statistics.
  final AxisStatistics lateralAcceleration;

  /// Vertical acceleration statistics.
  final AxisStatistics verticalAcceleration;

  /// Yaw-rate statistics.
  final AxisStatistics yawRate;

  /// Pitch-rate statistics.
  final AxisStatistics pitchRate;

  /// Roll-rate statistics.
  final AxisStatistics rollRate;

  /// Stability from 0 to 1.
  final double phoneStability;

  /// Whether vehicle axes were explicitly calibrated.
  final bool axisMappingCalibrated;

  /// JSON representation.
  Map<String, Object> toJson() => <String, Object>{
        'startedAtMillis': startedAtMillis,
        'durationMillis': durationMillis,
        'longitudinalAcceleration': longitudinalAcceleration.toJson(),
        'lateralAcceleration': lateralAcceleration.toJson(),
        'verticalAcceleration': verticalAcceleration.toJson(),
        'yawRate': yawRate.toJson(),
        'pitchRate': pitchRate.toJson(),
        'rollRate': rollRate.toJson(),
        'phoneStability': phoneStability,
        'axisMappingCalibrated': axisMappingCalibrated,
      };
}
