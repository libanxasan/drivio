import 'dart:math' as math;

import '../model/location_sample.dart';
import '../model/raw_motion_sample.dart';

/// Thresholds for detecting when driving starts and stops.
class DriveDetectionConfiguration {
  /// Creates a configuration. The defaults suit cars in city traffic.
  const DriveDetectionConfiguration({
    this.startSpeedKph = 15,
    this.startConfirmDuration = const Duration(seconds: 20),
    this.stopSpeedKph = 5,
    this.stopDuration = const Duration(minutes: 3),
    this.lostFixStopDuration = const Duration(minutes: 10),
    this.motionWindow = const Duration(seconds: 5),
    this.motionActiveRmsMps2 = 0.35,
    this.motionRecentDuration = const Duration(seconds: 10),
    this.maximumAccuracyMeters = 50,
    this.maximumFixGap = const Duration(seconds: 8),
  });

  /// GPS speed at or above which a drive may start.
  final double startSpeedKph;

  /// How long that speed must hold before the drive starts.
  final Duration startConfirmDuration;

  /// GPS speed at or below which the vehicle counts as stopped.
  final double stopSpeedKph;

  /// How long the vehicle must be stopped (and still) before the drive ends.
  final Duration stopDuration;

  /// With no usable GPS fix and no motion for this long, the drive ends.
  final Duration lostFixStopDuration;

  /// Window over which accelerometer activity is measured.
  final Duration motionWindow;

  /// RMS of user acceleration above which the phone is in a moving vehicle.
  final double motionActiveRmsMps2;

  /// Motion counts as current for this long after it was last active.
  final Duration motionRecentDuration;

  /// Fixes less accurate than this, and mocked fixes, are ignored.
  final double maximumAccuracyMeters;

  /// A longer gap between fixes restarts the start confirmation.
  final Duration maximumFixGap;
}

/// What the detector decided.
enum DriveDecision {
  /// Driving started: start recording.
  start,

  /// Driving ended: stop recording.
  stop,
}

/// Decides when driving starts and stops from GPS speed and accelerometer
/// activity. GPS speed alone can drift while parked; the accelerometer confirms
/// that the phone is in a moving vehicle, and its stillness confirms a stop.
/// When no motion samples arrive (no sensor, or sensors paused), GPS decides.
///
/// Pure logic with explicit timestamps, so it can be tested with recorded or
/// simulated traces.
class DriveDetector {
  /// Creates a detector, initially not driving.
  DriveDetector([this.configuration = const DriveDetectionConfiguration()]);

  /// The thresholds in use.
  final DriveDetectionConfiguration configuration;

  bool _driving = false;
  int? _fastSinceMillis;
  int? _lastFixMillis;
  int? _slowSinceMillis;
  int? _lastUsableFixMillis;
  int? _lastMotionActiveMillis;
  int? _lastMotionSampleMillis;
  final _window = <(int, double)>[];
  double _windowSquares = 0;

  /// Whether a drive is in progress.
  bool get isDriving => _driving;

  /// Current accelerometer activity (RMS of user acceleration, m/s²).
  double get motionRms =>
      _window.isEmpty ? 0 : math.sqrt(_windowSquares / _window.length);

  bool _motionRecent(int nowMillis) {
    final lastSample = _lastMotionSampleMillis;
    if (lastSample == null ||
        nowMillis - lastSample >
            configuration.motionRecentDuration.inMilliseconds) {
      return true; // No motion data: let GPS decide.
    }
    final active = _lastMotionActiveMillis;
    return active != null &&
        nowMillis - active <= configuration.motionRecentDuration.inMilliseconds;
  }

  bool _motionStill(int nowMillis) {
    final lastSample = _lastMotionSampleMillis;
    if (lastSample == null ||
        nowMillis - lastSample >
            configuration.motionRecentDuration.inMilliseconds) {
      return true;
    }
    final active = _lastMotionActiveMillis;
    return active == null ||
        nowMillis - active > configuration.motionRecentDuration.inMilliseconds;
  }

  /// Feeds one accelerometer sample.
  DriveDecision? onMotion(RawMotionSample sample) {
    final t = sample.timestampMicros ~/ 1000;
    final a = sample.userAcceleration;
    final squared = a.x * a.x + a.y * a.y + a.z * a.z;
    _window.add((t, squared));
    _windowSquares += squared;
    while (_window.isNotEmpty &&
        t - _window.first.$1 > configuration.motionWindow.inMilliseconds) {
      _windowSquares -= _window.removeAt(0).$2;
    }
    _lastMotionSampleMillis = t;
    if (motionRms >= configuration.motionActiveRmsMps2) {
      _lastMotionActiveMillis = t;
    }
    return null;
  }

  /// Feeds one GPS fix.
  DriveDecision? onLocation(LocationSample sample) {
    final t = sample.timestampMillis;
    if (sample.isMocked ||
        !sample.accuracyMeters.isFinite ||
        sample.accuracyMeters > configuration.maximumAccuracyMeters ||
        !sample.speedMps.isFinite) {
      return onTick(t);
    }
    final previous = _lastFixMillis;
    _lastFixMillis = t;
    _lastUsableFixMillis = t;
    final kph = math.max(0, sample.speedMps) * 3.6;
    if (!_driving) {
      final continuous =
          previous != null &&
          t - previous <= configuration.maximumFixGap.inMilliseconds;
      if (kph >= configuration.startSpeedKph) {
        if (_fastSinceMillis == null || !continuous) _fastSinceMillis = t;
        if (t - _fastSinceMillis! >=
                configuration.startConfirmDuration.inMilliseconds &&
            _motionRecent(t)) {
          _driving = true;
          _slowSinceMillis = null;
          _fastSinceMillis = null;
          return DriveDecision.start;
        }
      } else {
        _fastSinceMillis = null;
      }
      return null;
    }
    if (kph <= configuration.stopSpeedKph) {
      _slowSinceMillis ??= t;
    } else {
      _slowSinceMillis = null;
    }
    return onTick(t);
  }

  /// Re-evaluates time-based conditions; call periodically (for example every
  /// few seconds) so a drive also ends when fixes stop arriving.
  DriveDecision? onTick(int nowMillis) {
    if (!_driving) return null;
    final slowSince = _slowSinceMillis;
    final stoppedLongEnough =
        slowSince != null &&
        nowMillis - slowSince >= configuration.stopDuration.inMilliseconds;
    final lastFix = _lastUsableFixMillis;
    final fixLost =
        lastFix == null ||
        nowMillis - lastFix >= configuration.lostFixStopDuration.inMilliseconds;
    if ((stoppedLongEnough || fixLost) && _motionStill(nowMillis)) {
      _driving = false;
      _slowSinceMillis = null;
      return DriveDecision.stop;
    }
    return null;
  }
}
