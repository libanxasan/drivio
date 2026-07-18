import '../model/vector3_value.dart';

/// Maps device sensor axes into vehicle-relative axes.
enum SensorAxis { x, y, z }

/// A device axis and its sign.
class SignedSensorAxis {
  /// Creates an axis mapping.
  const SignedSensorAxis(this.axis, {this.sign = 1})
      : assert(sign == 1 || sign == -1);

  /// Device axis.
  final SensorAxis axis;

  /// Axis sign, either 1 or -1.
  final int sign;

  /// Projects a vector onto this axis.
  double project(Vector3Value value) {
    final raw = switch (axis) {
      SensorAxis.x => value.x,
      SensorAxis.y => value.y,
      SensorAxis.z => value.z,
    };
    return raw * sign;
  }
}

/// Device-to-vehicle coordinate mapping.
class VehicleAxisMapping {
  /// Creates a mapping.
  const VehicleAxisMapping({
    this.forward = const SignedSensorAxis(SensorAxis.y, sign: -1),
    this.lateral = const SignedSensorAxis(SensorAxis.x),
    this.vertical = const SignedSensorAxis(SensorAxis.z),
    this.isCalibrated = false,
  });

  /// Vehicle-forward acceleration axis.
  final SignedSensorAxis forward;

  /// Vehicle-lateral acceleration axis.
  final SignedSensorAxis lateral;

  /// Vehicle-vertical acceleration axis.
  final SignedSensorAxis vertical;

  /// Whether the mapping was explicitly calibrated for the mounted phone.
  final bool isCalibrated;
}

/// Motion and location collection settings.
class TelemetryConfiguration {
  /// Creates telemetry settings.
  const TelemetryConfiguration({
    this.motionSamplingPeriod = const Duration(milliseconds: 40),
    this.motionFrameDuration = const Duration(seconds: 1),
    this.locationDistanceFilterMeters = 0,
    this.maximumLocationAccuracyMeters = 50,
    this.maximumPlausibleSpeedKph = 240,
    this.chunkMaximumDuration = const Duration(minutes: 1),
    this.chunkMaximumEstimatedBytes = 256 * 1024,
    this.eventEvidenceBefore = const Duration(seconds: 5),
    this.eventEvidenceAfter = const Duration(seconds: 5),
    this.motionRingBufferDuration = const Duration(seconds: 12),
    this.axisMapping = const VehicleAxisMapping(),
    this.harshAccelerationThresholdMps2 = 2.8,
    this.harshBrakingThresholdMps2 = -3.5,
    this.highLateralAccelerationThresholdMps2 = 2.5,
    this.highYawRateThresholdRadS = 0.8,
    this.minimumManeuverSpeedKph = 20,
    this.minimumEventDuration = const Duration(milliseconds: 300),
    this.eventCooldown = const Duration(seconds: 4),
    this.speedingToleranceKph = 5,
    this.minimumSpeedingDuration = const Duration(seconds: 5),
    this.retainContinuousChunksAfterUpload = false,
    this.retainEventEvidenceAfterUpload = true,
  })  : assert(motionSamplingPeriod > Duration.zero),
        assert(motionFrameDuration > Duration.zero),
        assert(locationDistanceFilterMeters >= 0),
        assert(maximumLocationAccuracyMeters > 0),
        assert(maximumPlausibleSpeedKph > 0),
        assert(chunkMaximumDuration > Duration.zero),
        assert(chunkMaximumEstimatedBytes > 0),
        assert(eventEvidenceBefore >= Duration.zero),
        assert(eventEvidenceAfter >= Duration.zero),
        assert(motionRingBufferDuration > Duration.zero),
        assert(harshAccelerationThresholdMps2 > 0),
        assert(harshBrakingThresholdMps2 < 0),
        assert(highLateralAccelerationThresholdMps2 > 0),
        assert(highYawRateThresholdRadS > 0),
        assert(minimumManeuverSpeedKph >= 0),
        assert(minimumEventDuration > Duration.zero),
        assert(eventCooldown >= Duration.zero),
        assert(speedingToleranceKph >= 0),
        assert(minimumSpeedingDuration > Duration.zero);

  /// Requested sensor sampling period.
  final Duration motionSamplingPeriod;

  /// Duration represented by one condensed motion frame.
  final Duration motionFrameDuration;

  /// Minimum distance before a location update is requested.
  final int locationDistanceFilterMeters;

  /// Maximum accepted horizontal location accuracy.
  final double maximumLocationAccuracyMeters;

  /// Maximum accepted GPS speed.
  final double maximumPlausibleSpeedKph;

  /// Maximum time represented by a continuous chunk.
  final Duration chunkMaximumDuration;

  /// Estimated uncompressed size that triggers a chunk flush.
  final int chunkMaximumEstimatedBytes;

  /// Raw sensor evidence retained before an event.
  final Duration eventEvidenceBefore;

  /// Raw sensor evidence retained after an event.
  final Duration eventEvidenceAfter;

  /// In-memory raw sensor history duration.
  final Duration motionRingBufferDuration;

  /// Device-to-vehicle axis mapping.
  final VehicleAxisMapping axisMapping;

  /// Candidate acceleration threshold.
  final double harshAccelerationThresholdMps2;

  /// Candidate braking threshold.
  final double harshBrakingThresholdMps2;

  /// Candidate lateral acceleration threshold.
  final double highLateralAccelerationThresholdMps2;

  /// Candidate yaw-rate threshold.
  final double highYawRateThresholdRadS;

  /// Minimum speed for lateral maneuver candidates.
  final double minimumManeuverSpeedKph;

  /// Minimum time a threshold must be sustained.
  final Duration minimumEventDuration;

  /// Minimum gap between candidate events of the same type.
  final Duration eventCooldown;

  /// Allowed speed above an effective limit before an event begins.
  final double speedingToleranceKph;

  /// Minimum continuous speeding duration.
  final Duration minimumSpeedingDuration;

  /// Whether uploaded continuous chunks remain on the device.
  final bool retainContinuousChunksAfterUpload;

  /// Whether uploaded event evidence remains on the device.
  final bool retainEventEvidenceAfterUpload;
}
