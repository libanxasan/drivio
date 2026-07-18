import 'axis_statistics.dart';
import 'event_candidate.dart';

/// Fast-query aggregate for one hour of telemetry.
class HourlyTelemetryAggregate {
  /// Creates an hourly aggregate.
  const HourlyTelemetryAggregate({
    required this.hourStartedAtMillis,
    required this.hourEndedAtMillis,
    required this.distanceMeters,
    required this.movingDurationMillis,
    required this.speed,
    required this.longitudinalAcceleration,
    required this.lateralAcceleration,
    required this.yawRate,
    required this.locationSampleCount,
    required this.validLocationSampleCount,
    required this.eventCounts,
  });

  /// Start of the aggregate hour.
  final int hourStartedAtMillis;

  /// End represented by this aggregate.
  final int hourEndedAtMillis;

  /// Raw GPS distance accumulated during the hour.
  final double distanceMeters;

  /// Time considered moving.
  final int movingDurationMillis;

  /// Speed statistics.
  final AxisStatistics speed;

  /// Longitudinal acceleration statistics.
  final AxisStatistics longitudinalAcceleration;

  /// Lateral acceleration statistics.
  final AxisStatistics lateralAcceleration;

  /// Yaw-rate statistics.
  final AxisStatistics yawRate;

  /// Total location samples.
  final int locationSampleCount;

  /// Valid location samples.
  final int validLocationSampleCount;

  /// Candidate event counts by type.
  final Map<TelemetryEventType, int> eventCounts;

  /// JSON representation.
  Map<String, Object> toJson() => <String, Object>{
        'hourStartedAtMillis': hourStartedAtMillis,
        'hourEndedAtMillis': hourEndedAtMillis,
        'distanceMeters': distanceMeters,
        'movingDurationMillis': movingDurationMillis,
        'speed': speed.toJson(),
        'longitudinalAcceleration': longitudinalAcceleration.toJson(),
        'lateralAcceleration': lateralAcceleration.toJson(),
        'yawRate': yawRate.toJson(),
        'locationSampleCount': locationSampleCount,
        'validLocationSampleCount': validLocationSampleCount,
        'eventCounts': <String, int>{
          for (final entry in eventCounts.entries) entry.key.name: entry.value,
        },
      };
}
