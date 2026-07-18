import 'dart:math' as math;

import '../model/event_candidate.dart';
import '../model/hourly_aggregate.dart';
import '../model/location_sample.dart';
import '../model/motion_frame.dart';
import 'online_statistics.dart';

/// Builds fast-query hourly telemetry aggregates.
class HourlyAggregator {
  int? _hourStartMillis;
  int? _lastTimestampMillis;
  double _distanceMeters = 0;
  int _movingDurationMillis = 0;
  int _locationCount = 0;
  int _validLocationCount = 0;
  LocationSample? _previousLocation;

  final OnlineStatistics _speed = OnlineStatistics();
  final OnlineStatistics _longitudinal = OnlineStatistics();
  final OnlineStatistics _lateral = OnlineStatistics();
  final OnlineStatistics _yaw = OnlineStatistics();
  final Map<TelemetryEventType, int> _eventCounts =
      <TelemetryEventType, int>{};

  /// Adds a location and returns a completed previous-hour aggregate.
  HourlyTelemetryAggregate? addLocation(
    LocationSample sample, {
    required bool isValid,
  }) {
    final completed = _advanceIfNeeded(sample.timestampMillis);
    _locationCount++;
    if (isValid) {
      _validLocationCount++;
      _speed.add(sample.speedMps);
      final previous = _previousLocation;
      if (previous != null) {
        final deltaMillis = sample.timestampMillis - previous.timestampMillis;
        if (deltaMillis > 0 && deltaMillis <= 10000) {
          if (sample.speedKph >= 5) _movingDurationMillis += deltaMillis;
          _distanceMeters += _haversineMeters(previous, sample);
        }
      }
      _previousLocation = sample;
    }
    _lastTimestampMillis = sample.timestampMillis;
    return completed;
  }

  /// Adds one condensed motion frame.
  HourlyTelemetryAggregate? addMotionFrame(MotionFrame frame) {
    final completed = _advanceIfNeeded(frame.startedAtMillis);
    _longitudinal.addStatistics(frame.longitudinalAcceleration);
    _lateral.addStatistics(frame.lateralAcceleration);
    _yaw.addStatistics(frame.yawRate);
    _lastTimestampMillis = frame.startedAtMillis + frame.durationMillis;
    return completed;
  }

  /// Adds one event candidate.
  HourlyTelemetryAggregate? addEvent(TelemetryEventCandidate event) {
    final completed = _advanceIfNeeded(event.startedAtMillis);
    _eventCounts.update(event.type, (value) => value + 1, ifAbsent: () => 1);
    _lastTimestampMillis = event.endedAtMillis;
    return completed;
  }

  /// Flushes the current hour.
  HourlyTelemetryAggregate? flush() {
    if (_hourStartMillis == null) return null;
    final aggregate = _buildAggregate(
      _lastTimestampMillis ?? _hourStartMillis! + 1,
    );
    _reset(null);
    return aggregate;
  }


  /// Clears the active aggregate.
  void reset() => _reset(null);

  HourlyTelemetryAggregate? _advanceIfNeeded(int timestampMillis) {
    final currentHour = _startOfHour(timestampMillis);
    _hourStartMillis ??= currentHour;
    if (currentHour == _hourStartMillis) return null;

    final completed = _buildAggregate(_hourStartMillis! + 3600000);
    _reset(currentHour);
    return completed;
  }

  HourlyTelemetryAggregate _buildAggregate(int endMillis) {
    return HourlyTelemetryAggregate(
      hourStartedAtMillis: _hourStartMillis!,
      hourEndedAtMillis: endMillis,
      distanceMeters: _distanceMeters,
      movingDurationMillis: _movingDurationMillis,
      speed: _speed.snapshot(),
      longitudinalAcceleration: _longitudinal.snapshot(),
      lateralAcceleration: _lateral.snapshot(),
      yawRate: _yaw.snapshot(),
      locationSampleCount: _locationCount,
      validLocationSampleCount: _validLocationCount,
      eventCounts: Map<TelemetryEventType, int>.unmodifiable(_eventCounts),
    );
  }

  void _reset(int? nextHour) {
    _hourStartMillis = nextHour;
    _lastTimestampMillis = null;
    _distanceMeters = 0;
    _movingDurationMillis = 0;
    _locationCount = 0;
    _validLocationCount = 0;
    _previousLocation = null;
    _speed.reset();
    _longitudinal.reset();
    _lateral.reset();
    _yaw.reset();
    _eventCounts.clear();
  }

  int _startOfHour(int timestampMillis) =>
      timestampMillis - (timestampMillis % 3600000);

  double _haversineMeters(LocationSample a, LocationSample b) {
    const earthRadiusMeters = 6371000.0;
    final lat1 = _radians(a.latitude);
    final lat2 = _radians(b.latitude);
    final deltaLat = _radians(b.latitude - a.latitude);
    final deltaLon = _radians(b.longitude - a.longitude);
    final sinLat = math.sin(deltaLat / 2);
    final sinLon = math.sin(deltaLon / 2);
    final h = sinLat * sinLat +
        math.cos(lat1) * math.cos(lat2) * sinLon * sinLon;
    return earthRadiusMeters * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
  }

  double _radians(double degrees) => degrees * math.pi / 180;
}
