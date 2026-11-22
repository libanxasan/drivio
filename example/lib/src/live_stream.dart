import 'dart:async';

import 'package:driving_telemetry/driving_telemetry.dart';

import 'convex_session.dart';

/// Sends the current trip's GPS samples, motion frames and events to DriVio's
/// Convex deployment as they happen (`streams:publish`), in small batches.
///
/// While offline, batches are kept up to a limit and then dropped: the trip is
/// still recorded and archived, and Convex backfills the gap from the archive
/// once the recording is uploaded.
class LiveStreamPublisher {
  /// Creates a publisher for [recorder].
  LiveStreamPublisher({
    required this.recorder,
    required this.session,
    this.flushInterval = const Duration(seconds: 5),
    this.maximumPending = 600,
  });

  /// The recorder whose trips are streamed.
  final DrivingTelemetryRecorder recorder;

  /// The signed-in Convex session.
  final ConvexSession session;

  /// How often batches are sent.
  final Duration flushInterval;

  /// Items kept while sending fails; older ones are dropped (and backfilled).
  final int maximumPending;

  static const kinds = <String>['points', 'frames', 'events'];

  final _points = <Map<String, Object?>>[];
  final _frames = <Map<String, Object?>>[];
  final _events = <Map<String, Object?>>[];
  final _subscriptions = <StreamSubscription<Object?>>[];
  Timer? _timer;
  String? _streamId;
  bool _sending = false;

  /// Items sent since start.
  int sent = 0;

  /// When the last batch was accepted.
  DateTime? lastSentAt;

  /// The last send error, cleared by a successful send.
  Object? lastError;

  /// Starts listening to the recorder.
  void start() {
    _subscriptions
      ..add(recorder.locationSource.samples
          .listen(_onLocation, onError: (Object _) {}))
      ..add(recorder.motionFrames.listen(_onFrame))
      ..add(recorder.candidateEvents.listen(_onEvent))
      ..add(recorder.states.listen(_onState));
    _timer = Timer.periodic(flushInterval, (_) => unawaited(flush()));
  }

  void _onState(TelemetryRecorderState state) {
    if (state == TelemetryRecorderState.recording) {
      _streamId = recorder.activeTripId;
    } else if (state == TelemetryRecorderState.idle && _streamId != null) {
      final ended = _streamId!;
      unawaited(flush().whenComplete(() async {
        try {
          await session.mutation('streams:close', {'streamId': ended});
        } catch (_) {
          // The deployment closes silent streams on its own.
        }
      }));
      _streamId = null;
    }
  }

  void _keep(List<Map<String, Object?>> list, Map<String, Object?> item) {
    if (_streamId == null || !recorder.isRecording) return;
    list.add(item);
    if (list.length > maximumPending) list.removeAt(0);
  }

  void _onLocation(LocationSample s) => _keep(_points, {
        't': s.timestampMillis,
        'latitude': s.latitude,
        'longitude': s.longitude,
        'speedMps': s.speedMps,
        'headingDegrees': s.headingDegrees,
        'accuracyMeters': s.accuracyMeters,
        'altitudeMeters': s.altitudeMeters,
        'speedAccuracyMps': s.speedAccuracyMps,
        'headingAccuracyDegrees': s.headingAccuracyDegrees,
        'isMocked': s.isMocked,
      });

  static Map<String, Object?> _axis(AxisStatistics a) => {
        'minimum': a.minimum,
        'maximum': a.maximum,
        'mean': a.mean,
        'standardDeviation': a.standardDeviation,
        'rms': a.rms,
        'sampleCount': a.sampleCount,
      };

  void _onFrame(MotionFrame f) => _keep(_frames, {
        't': f.startedAtMillis,
        'durationMillis': f.durationMillis,
        'longitudinalAcceleration': _axis(f.longitudinalAcceleration),
        'lateralAcceleration': _axis(f.lateralAcceleration),
        'verticalAcceleration': _axis(f.verticalAcceleration),
        'yawRate': _axis(f.yawRate),
        'pitchRate': _axis(f.pitchRate),
        'rollRate': _axis(f.rollRate),
        'phoneStability': f.phoneStability,
        'axisMappingCalibrated': f.axisMappingCalibrated,
      });

  void _onEvent(TelemetryEventCandidate e) => _keep(_events, {
        't': e.startedAtMillis, 'endedAt': e.endedAtMillis, 'eventId': e.id,
        // The enum index, as in archived chunks, so live and backfilled events match.
        'eventType': e.type.index, 'confidence': e.confidence,
        'minimumValue': e.minimumValue, 'maximumValue': e.maximumValue,
        'meanValue': e.meanValue,
        if (e.latitude != null) 'latitude': e.latitude,
        if (e.longitude != null) 'longitude': e.longitude,
        if (e.speedBeforeMps != null) 'speedBeforeMps': e.speedBeforeMps,
        if (e.speedAfterMps != null) 'speedAfterMps': e.speedAfterMps,
        if (e.effectiveSpeedLimitKph != null)
          'effectiveSpeedLimitKph': e.effectiveSpeedLimitKph,
      });

  /// Sends what is pending.
  Future<void> flush() async {
    final streamId = _streamId ?? recorder.activeTripId;
    if (_sending ||
        streamId == null ||
        (_points.isEmpty && _frames.isEmpty && _events.isEmpty)) {
      return;
    }
    _sending = true;
    final points = List.of(_points.take(300));
    final frames = List.of(_frames.take(300));
    final events = List.of(_events.take(100));
    try {
      await session.mutation('streams:publish', {
        'streamId': streamId,
        'kinds': kinds,
        'points': points,
        'frames': frames,
        'events': events,
      });
      _points.removeRange(0, points.length);
      _frames.removeRange(0, frames.length);
      _events.removeRange(0, events.length);
      sent += points.length + frames.length + events.length;
      lastSentAt = DateTime.now();
      lastError = null;
    } catch (error) {
      lastError = error;
    } finally {
      _sending = false;
    }
  }

  /// Stops listening.
  Future<void> stop() async {
    _timer?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
  }
}
