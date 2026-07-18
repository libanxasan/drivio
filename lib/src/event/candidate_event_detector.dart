import 'dart:math' as math;

import '../config/telemetry_configuration.dart';
import '../model/effective_speed_limit.dart';
import '../model/event_candidate.dart';
import '../model/location_sample.dart';
import '../model/raw_motion_sample.dart';
import '../utils/id_generator.dart';

class _ThresholdState {
  _ThresholdState(this.type);

  final TelemetryEventType type;
  int? startedAtMillis;
  int? lastActiveAtMillis;
  int sampleCount = 0;
  double minimum = double.infinity;
  double maximum = double.negativeInfinity;
  double sum = 0;
  double? speedBeforeMps;
  double? speedAfterMps;

  bool get active => startedAtMillis != null;

  void start(int timestampMillis, double value, double? speedMps) {
    startedAtMillis = timestampMillis;
    lastActiveAtMillis = timestampMillis;
    speedBeforeMps = speedMps;
    add(timestampMillis, value, speedMps);
  }

  void add(int timestampMillis, double value, double? speedMps) {
    lastActiveAtMillis = timestampMillis;
    sampleCount++;
    minimum = math.min(minimum, value);
    maximum = math.max(maximum, value);
    sum += value;
    speedAfterMps = speedMps;
  }

  void reset() {
    startedAtMillis = null;
    lastActiveAtMillis = null;
    sampleCount = 0;
    minimum = double.infinity;
    maximum = double.negativeInfinity;
    sum = 0;
    speedBeforeMps = null;
    speedAfterMps = null;
  }
}

/// Detects candidate events only, without calculating scores or penalties.
class CandidateEventDetector {
  /// Creates a detector.
  CandidateEventDetector(this.configuration);

  /// Recorder settings.
  final TelemetryConfiguration configuration;

  final Map<TelemetryEventType, _ThresholdState> _states =
      <TelemetryEventType, _ThresholdState>{};
  final Map<TelemetryEventType, int> _lastCompletedAtMillis =
      <TelemetryEventType, int>{};

  LocationSample? _latestLocation;
  EffectiveSpeedLimit _effectiveSpeedLimit = EffectiveSpeedLimit.unavailable;

  _ThresholdState _state(TelemetryEventType type) =>
      _states.putIfAbsent(type, () => _ThresholdState(type));

  /// Updates the limit used only for candidate speeding evidence.
  void updateEffectiveSpeedLimit(EffectiveSpeedLimit value) {
    _effectiveSpeedLimit = value;
  }

  /// Processes a location sample and returns completed candidate events.
  List<TelemetryEventCandidate> addLocation(LocationSample sample) {
    _latestLocation = sample;
    final events = <TelemetryEventCandidate>[];

    final limit = _effectiveSpeedLimit.speedKph;
    final speeding = limit != null &&
        sample.speedKph > limit + configuration.speedingToleranceKph;
    final excess = limit == null ? 0.0 : sample.speedKph - limit;
    final completed = _updateState(
      type: TelemetryEventType.speedingCandidate,
      active: speeding,
      timestampMillis: sample.timestampMillis,
      value: excess,
      minimumDuration: configuration.minimumSpeedingDuration,
      baseConfidence: _effectiveSpeedLimit.confidence,
      speedMps: sample.speedMps,
      effectiveSpeedLimitKph: limit,
    );
    if (completed != null) events.add(completed);

    final gpsQualityLost = sample.accuracyMeters >
            configuration.maximumLocationAccuracyMeters ||
        sample.isMocked;
    final qualityEvent = _updateState(
      type: TelemetryEventType.gpsQualityLoss,
      active: gpsQualityLost,
      timestampMillis: sample.timestampMillis,
      value: sample.accuracyMeters,
      minimumDuration: const Duration(seconds: 5),
      baseConfidence: sample.isMocked ? 1.0 : 0.8,
      speedMps: sample.speedMps,
    );
    if (qualityEvent != null) events.add(qualityEvent);
    return events;
  }

  /// Processes a raw motion sample and returns completed candidate events.
  List<TelemetryEventCandidate> addMotion(RawMotionSample sample) {
    final timestampMillis = sample.timestampMicros ~/ 1000;
    final mapping = configuration.axisMapping;
    final longitudinal = mapping.forward.project(sample.userAcceleration);
    final lateral = mapping.lateral.project(sample.userAcceleration);
    final yaw = mapping.vertical.project(sample.gyroscope);
    final speedMps = _latestLocation?.speedMps;
    final speedKph = _latestLocation?.speedKph ?? 0;
    final events = <TelemetryEventCandidate>[];

    final acceleration = _updateState(
      type: TelemetryEventType.harshAccelerationCandidate,
      active: longitudinal >= configuration.harshAccelerationThresholdMps2,
      timestampMillis: timestampMillis,
      value: longitudinal,
      minimumDuration: configuration.minimumEventDuration,
      baseConfidence: mapping.isCalibrated ? 0.85 : 0.55,
      speedMps: speedMps,
    );
    if (acceleration != null) events.add(acceleration);

    final braking = _updateState(
      type: TelemetryEventType.harshBrakingCandidate,
      active: longitudinal <= configuration.harshBrakingThresholdMps2,
      timestampMillis: timestampMillis,
      value: longitudinal,
      minimumDuration: configuration.minimumEventDuration,
      baseConfidence: mapping.isCalibrated ? 0.88 : 0.58,
      speedMps: speedMps,
    );
    if (braking != null) events.add(braking);

    final swervingActive = speedKph >= configuration.minimumManeuverSpeedKph &&
        lateral.abs() >= configuration.highLateralAccelerationThresholdMps2 &&
        yaw.abs() >= configuration.highYawRateThresholdRadS;
    final swerving = _updateState(
      type: TelemetryEventType.swervingCandidate,
      active: swervingActive,
      timestampMillis: timestampMillis,
      value: lateral.abs() + yaw.abs(),
      minimumDuration: configuration.minimumEventDuration,
      baseConfidence: mapping.isCalibrated ? 0.78 : 0.42,
      speedMps: speedMps,
    );
    if (swerving != null) events.add(swerving);

    final laneChangeActive = speedKph >= configuration.minimumManeuverSpeedKph &&
        lateral.abs() >=
            configuration.highLateralAccelerationThresholdMps2 * 0.55 &&
        yaw.abs() >= configuration.highYawRateThresholdRadS * 0.45 &&
        !swervingActive;
    final laneChange = _updateState(
      type: TelemetryEventType.abruptLaneChangeCandidate,
      active: laneChangeActive,
      timestampMillis: timestampMillis,
      value: lateral.abs() + yaw.abs(),
      minimumDuration: configuration.minimumEventDuration,
      baseConfidence: mapping.isCalibrated ? 0.62 : 0.32,
      speedMps: speedMps,
    );
    if (laneChange != null) events.add(laneChange);

    final phoneMovement = _updateState(
      type: TelemetryEventType.phoneMovement,
      active: sample.gyroscope.magnitude >= 2.5 && speedKph < 10,
      timestampMillis: timestampMillis,
      value: sample.gyroscope.magnitude,
      minimumDuration: const Duration(milliseconds: 250),
      baseConfidence: 0.85,
      speedMps: speedMps,
    );
    if (phoneMovement != null) events.add(phoneMovement);

    return events;
  }


  /// Clears detector state for a new trip.
  void reset() {
    for (final state in _states.values) {
      state.reset();
    }
    _states.clear();
    _lastCompletedAtMillis.clear();
    _latestLocation = null;
    _effectiveSpeedLimit = EffectiveSpeedLimit.unavailable;
  }

  /// Closes active events when a trip ends.
  List<TelemetryEventCandidate> flush(int endedAtMillis) {
    final results = <TelemetryEventCandidate>[];
    for (final state in _states.values) {
      final event = _completeState(
        state,
        endedAtMillis: endedAtMillis,
        minimumDuration: state.type == TelemetryEventType.speedingCandidate
            ? configuration.minimumSpeedingDuration
            : configuration.minimumEventDuration,
        baseConfidence: _baseConfidence(state.type),
        effectiveSpeedLimitKph:
            state.type == TelemetryEventType.speedingCandidate
                ? _effectiveSpeedLimit.speedKph
                : null,
      );
      if (event != null) results.add(event);
    }
    return results;
  }

  TelemetryEventCandidate? _updateState({
    required TelemetryEventType type,
    required bool active,
    required int timestampMillis,
    required double value,
    required Duration minimumDuration,
    required double baseConfidence,
    required double? speedMps,
    double? effectiveSpeedLimitKph,
  }) {
    final state = _state(type);
    if (active) {
      if (!state.active) {
        final last = _lastCompletedAtMillis[type];
        if (last != null &&
            timestampMillis - last < configuration.eventCooldown.inMilliseconds) {
          return null;
        }
        state.start(timestampMillis, value, speedMps);
      } else {
        state.add(timestampMillis, value, speedMps);
      }
      return null;
    }

    return _completeState(
      state,
      endedAtMillis: timestampMillis,
      minimumDuration: minimumDuration,
      baseConfidence: baseConfidence,
      effectiveSpeedLimitKph: effectiveSpeedLimitKph,
    );
  }

  TelemetryEventCandidate? _completeState(
    _ThresholdState state, {
    required int endedAtMillis,
    required Duration minimumDuration,
    required double baseConfidence,
    double? effectiveSpeedLimitKph,
  }) {
    if (!state.active) return null;
    final startedAt = state.startedAtMillis!;
    final lastActive = state.lastActiveAtMillis ?? endedAtMillis;
    final duration = lastActive - startedAt;
    if (duration < minimumDuration.inMilliseconds || state.sampleCount == 0) {
      state.reset();
      return null;
    }

    final location = _latestLocation;
    final confidence = baseConfidence.clamp(0.0, 1.0).toDouble();
    final event = TelemetryEventCandidate(
      id: IdGenerator.create('evt'),
      type: state.type,
      startedAtMillis: startedAt,
      endedAtMillis: lastActive,
      confidence: confidence,
      minimumValue: state.minimum,
      maximumValue: state.maximum,
      meanValue: state.sum / state.sampleCount,
      speedBeforeMps: state.speedBeforeMps,
      speedAfterMps: state.speedAfterMps,
      latitude: location?.latitude,
      longitude: location?.longitude,
      effectiveSpeedLimitKph: effectiveSpeedLimitKph,
      metadata: <String, Object?>{
        'axisMappingCalibrated': configuration.axisMapping.isCalibrated,
        'sampleCount': state.sampleCount,
      },
    );
    _lastCompletedAtMillis[state.type] = lastActive;
    state.reset();
    return event;
  }

  double _baseConfidence(TelemetryEventType type) {
    return switch (type) {
      TelemetryEventType.harshAccelerationCandidate =>
        configuration.axisMapping.isCalibrated ? 0.85 : 0.55,
      TelemetryEventType.harshBrakingCandidate =>
        configuration.axisMapping.isCalibrated ? 0.88 : 0.58,
      TelemetryEventType.swervingCandidate =>
        configuration.axisMapping.isCalibrated ? 0.78 : 0.42,
      TelemetryEventType.abruptLaneChangeCandidate =>
        configuration.axisMapping.isCalibrated ? 0.62 : 0.32,
      TelemetryEventType.speedingCandidate => _effectiveSpeedLimit.confidence,
      TelemetryEventType.gpsQualityLoss => 0.8,
      TelemetryEventType.phoneMovement => 0.85,
      TelemetryEventType.wrongWayCandidate => 0.5,
      TelemetryEventType.signalizedIntersectionCrossingCandidate => 0.4,
    };
  }
}
