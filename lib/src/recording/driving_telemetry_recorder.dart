import 'dart:async';
import 'dart:math' as math;

import '../aggregation/hourly_aggregator.dart';
import '../aggregation/motion_frame_aggregator.dart';
import '../codec/telemetry_binary_codec.dart';
import '../config/telemetry_configuration.dart';
import '../event/candidate_event_detector.dart';
import '../event/event_evidence_capture.dart';
import '../event/time_ring_buffer.dart';
import '../model/effective_speed_limit.dart';
import '../model/event_candidate.dart';
import '../model/hourly_aggregate.dart';
import '../model/location_sample.dart';
import '../model/motion_frame.dart';
import '../model/osrm_match_result.dart';
import '../model/raw_motion_sample.dart';
import '../model/telemetry_chunk.dart';
import '../model/trip_result.dart';
import '../network/osrm_client.dart';
import '../network/telemetry_synchronizer.dart';
import '../storage/telemetry_store.dart';
import '../utils/id_generator.dart';
import 'location_source.dart';
import 'motion_source.dart';

/// Recorder state.
enum TelemetryRecorderState {
  /// No trip is active.
  idle,

  /// A trip is being started.
  starting,

  /// A trip is being recorded.
  recording,

  /// A trip is being stopped and persisted.
  stopping,

  /// The recorder has been disposed and can no longer be used.
  disposed,
}

/// Raw telemetry recorder with no scoring logic.
class DrivingTelemetryRecorder {
  /// Creates a recorder.
  DrivingTelemetryRecorder({
    required this.store,
    required this.motionSource,
    required this.locationSource,
    this.configuration = const TelemetryConfiguration(),
    this.osrmClient,
    this.synchronizer,
  })  : _motionAggregator = MotionFrameAggregator(
          configuration: configuration,
        ),
        _detector = CandidateEventDetector(configuration),
        _motionRing = TimeRingBuffer<RawMotionSample>(
          capacity: configuration.motionRingBufferDuration,
          timestampMillis: (value) => value.timestampMicros ~/ 1000,
        ),
        _locationRing = TimeRingBuffer<LocationSample>(
          capacity: configuration.motionRingBufferDuration,
          timestampMillis: (value) => value.timestampMillis,
        ) {
    configuration.validate();
  }

  /// Durable local storage.
  final TelemetryStore store;

  /// High-frequency motion source.
  final MotionSource motionSource;

  /// GPS source.
  final LocationSource locationSource;

  /// Recorder configuration.
  final TelemetryConfiguration configuration;

  /// Optional OSRM client used after a trip.
  final OsrmClient? osrmClient;

  /// Optional backend synchronizer.
  final TelemetrySynchronizer? synchronizer;

  final TelemetryBinaryCodec _codec = TelemetryBinaryCodec();
  final MotionFrameAggregator _motionAggregator;
  final HourlyAggregator _hourlyAggregator = HourlyAggregator();
  final CandidateEventDetector _detector;
  final TimeRingBuffer<RawMotionSample> _motionRing;
  final TimeRingBuffer<LocationSample> _locationRing;

  final StreamController<TelemetryEventCandidate> _eventController =
      StreamController<TelemetryEventCandidate>.broadcast();
  final StreamController<Object> _errorController =
      StreamController<Object>.broadcast();

  StreamSubscription<RawMotionSample>? _motionSubscription;
  StreamSubscription<LocationSample>? _locationSubscription;

  final List<LocationSample> _continuousLocations = <LocationSample>[];
  final List<MotionFrame> _continuousFrames = <MotionFrame>[];
  final List<TelemetryEventCandidate> _continuousEvents =
      <TelemetryEventCandidate>[];
  final List<LocationSample> _completeLocationTrace = <LocationSample>[];
  final List<EventEvidenceCapture> _activeEvidence = <EventEvidenceCapture>[];

  Future<void> _writeTail = Future<void>.value();
  TelemetryRecorderState _state = TelemetryRecorderState.idle;
  String? _tripId;
  int? _startedAtMillis;
  int? _chunkStartedAtMillis;
  int _chunkIndex = 0;
  int _motionFrameCount = 0;
  int _eventCount = 0;
  double _rawGpsDistanceMeters = 0;
  LocationSample? _previousValidLocation;

  /// Current lifecycle state.
  TelemetryRecorderState get state => _state;

  /// Whether a trip is currently being recorded.
  bool get isRecording => _state == TelemetryRecorderState.recording;

  /// Current trip identifier.
  String? get activeTripId => _tripId;

  /// Candidate events, exposed for optional diagnostics only.
  Stream<TelemetryEventCandidate> get candidateEvents =>
      _eventController.stream;

  /// Non-fatal stream and network errors.
  Stream<Object> get errors => _errorController.stream;

  /// Starts a telemetry trip.
  Future<String> startTrip({
    required String userId,
    String? tripId,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    _ensureNotDisposed();
    if (_state != TelemetryRecorderState.idle) {
      throw StateError('Recorder must be idle before starting a trip.');
    }

    _state = TelemetryRecorderState.starting;
    final resolvedTripId = tripId ?? IdGenerator.create('trip');
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;

    try {
      await store.initialize();
      await store.createTrip(
        tripId: resolvedTripId,
        userId: userId,
        startedAtMillis: now,
        schemaVersion: TelemetryBinaryCodec.schemaVersion,
        metadata: metadata,
      );

      _tripId = resolvedTripId;
      _startedAtMillis = now;
      _chunkStartedAtMillis = now;
      _resetRuntimeBuffers();

      _motionSubscription = motionSource.samples.listen(
        _handleMotion,
        onError: _handleSourceError,
      );
      _locationSubscription = locationSource.samples.listen(
        _handleLocation,
        onError: _handleSourceError,
      );

      await locationSource.start();
      await motionSource.start();
      _state = TelemetryRecorderState.recording;
      return resolvedTripId;
    } catch (_) {
      await _stopSources();
      _tripId = null;
      _startedAtMillis = null;
      _chunkStartedAtMillis = null;
      _state = TelemetryRecorderState.idle;
      rethrow;
    }
  }

  /// Cancels subscriptions and stops both sources, reporting rather than
  /// throwing teardown errors so buffered telemetry can still be persisted.
  Future<void> _stopSources() async {
    final subscriptions = <StreamSubscription<Object?>?>[
      _motionSubscription,
      _locationSubscription,
    ];
    _motionSubscription = null;
    _locationSubscription = null;
    for (final subscription in subscriptions) {
      try {
        await subscription?.cancel();
      } catch (error) {
        _reportError(error);
      }
    }
    try {
      await motionSource.stop();
    } catch (error) {
      _reportError(error);
    }
    try {
      await locationSource.stop();
    } catch (error) {
      _reportError(error);
    }
  }

  void _reportError(Object error) {
    if (!_errorController.isClosed) _errorController.add(error);
  }

  /// Updates the effective limit used only to detect a candidate speeding window.
  void updateEffectiveSpeedLimit(EffectiveSpeedLimit limit) {
    _detector.updateEffectiveSpeedLimit(limit);
  }

  /// Adds a candidate generated by an external road-context component.
  void recordExternalCandidate(TelemetryEventCandidate event) {
    if (!isRecording) {
      throw StateError('A trip must be active to record a candidate.');
    }
    _registerCandidate(event);
  }

  /// Stops the trip, persists all remaining data, and optionally matches the route.
  Future<TelemetryTripResult> stopTrip() async {
    _ensureNotDisposed();
    if (_state != TelemetryRecorderState.recording) {
      throw StateError('No active telemetry trip.');
    }
    _state = TelemetryRecorderState.stopping;

    await _stopSources();

    try {
      return await _finishTrip();
    } finally {
      _state = TelemetryRecorderState.idle;
      _tripId = null;
      _startedAtMillis = null;
      _chunkStartedAtMillis = null;
      _resetRuntimeBuffers();
    }
  }

  Future<TelemetryTripResult> _finishTrip() async {
    final endedAt = DateTime.now().toUtc().millisecondsSinceEpoch;
    final partialFrame = _motionAggregator.flush();
    if (partialFrame != null) _registerFrame(partialFrame);

    for (final event in _detector.flush(endedAt)) {
      _registerCandidate(event);
    }

    _finalizeAllEvidence(endedAt);
    _enqueueContinuousFlush(force: true, endedAtMillis: endedAt);

    final hourly = _hourlyAggregator.flush();
    if (hourly != null) _enqueueHourly(hourly);

    await _writeTail;

    OsrmMatchResult? osrmMatch;
    String? routeError;
    if (osrmClient != null && _completeLocationTrace.length >= 2) {
      try {
        osrmMatch = await osrmClient!.matchTrace(_completeLocationTrace);
        final chunkId = IdGenerator.create('route');
        final index = _nextChunkIndex();
        await store.writeJsonArtifact(
          tripId: _tripId!,
          chunkId: chunkId,
          chunkIndex: index,
          type: TelemetryChunkType.route,
          startedAtMillis: _startedAtMillis!,
          endedAtMillis: endedAt,
          schemaVersion: TelemetryBinaryCodec.schemaVersion,
          value: osrmMatch.toJson().cast<String, Object?>(),
        );
      } catch (error) {
        routeError = error.toString();
        _reportError(error);
      }
    }

    final tripMetadata = <String, Object?>{
      'rawGpsDistanceMeters': _rawGpsDistanceMeters,
      'locationSampleCount': _completeLocationTrace.length,
      'motionFrameCount': _motionFrameCount,
      'eventCount': _eventCount,
      'osrmMatchedDistanceMeters': osrmMatch?.totalDistanceMeters,
      'osrmMatchConfidence': osrmMatch?.weightedConfidence,
      'routeProcessingError': routeError,
    };

    await store.writeJsonArtifact(
      tripId: _tripId!,
      chunkId: IdGenerator.create('manifest'),
      chunkIndex: _nextChunkIndex(),
      type: TelemetryChunkType.tripManifest,
      startedAtMillis: _startedAtMillis!,
      endedAtMillis: endedAt,
      schemaVersion: TelemetryBinaryCodec.schemaVersion,
      value: <String, Object?>{
        'tripId': _tripId!,
        'startedAtMillis': _startedAtMillis!,
        'endedAtMillis': endedAt,
        'schemaVersion': TelemetryBinaryCodec.schemaVersion,
        'status': 'closed',
        'telemetry': tripMetadata,
      },
    );

    await store.closeTrip(
      tripId: _tripId!,
      endedAtMillis: endedAt,
      metadataUpdates: tripMetadata,
    );

    final manifest = await store.readManifest(_tripId!);
    final pending = await store.pendingChunkCount(_tripId!);
    return TelemetryTripResult(
      tripId: _tripId!,
      startedAtMillis: _startedAtMillis!,
      endedAtMillis: endedAt,
      rawGpsDistanceMeters: _rawGpsDistanceMeters,
      locationSampleCount: _completeLocationTrace.length,
      motionFrameCount: _motionFrameCount,
      eventCount: _eventCount,
      chunkCount: manifest.chunks.length,
      pendingUploadCount: pending,
      osrmMatch: osrmMatch,
      routeProcessingError: routeError,
    );
  }

  /// Runs one backend synchronization pass.
  ///
  /// Returns null when no [synchronizer] was supplied.
  Future<TelemetrySyncResult?> synchronizePendingData({
    int? maximumChunks,
  }) async {
    return synchronizer?.synchronize(maximumChunks: maximumChunks);
  }

  void _handleMotion(RawMotionSample sample) {
    if (!isRecording) return;
    _motionRing.add(sample);
    for (final capture in _activeEvidence) {
      if (sample.timestampMicros ~/ 1000 <= capture.captureUntilMillis) {
        capture.motionSamples.add(sample);
      }
    }

    final frame = _motionAggregator.add(sample);
    if (frame != null) _registerFrame(frame);

    for (final event in _detector.addMotion(sample)) {
      _registerCandidate(event);
    }
    _finalizeCompletedEvidence(sample.timestampMicros ~/ 1000);
    _checkChunkFlush(sample.timestampMicros ~/ 1000);
  }

  void _handleLocation(LocationSample sample) {
    if (!isRecording) return;
    _locationRing.add(sample);
    for (final capture in _activeEvidence) {
      if (sample.timestampMillis <= capture.captureUntilMillis) {
        capture.locationSamples.add(sample);
      }
    }

    final valid = _isValidLocation(sample);
    final hourly = _hourlyAggregator.addLocation(sample, isValid: valid);
    if (hourly != null) _enqueueHourly(hourly);

    if (valid) {
      _continuousLocations.add(sample);
      _completeLocationTrace.add(sample);
      _accumulateDistance(sample);
    }

    for (final event in _detector.addLocation(sample)) {
      _registerCandidate(event);
    }
    _finalizeCompletedEvidence(sample.timestampMillis);
    _checkChunkFlush(sample.timestampMillis);
  }

  void _registerFrame(MotionFrame frame) {
    _continuousFrames.add(frame);
    _motionFrameCount++;
    final hourly = _hourlyAggregator.addMotionFrame(frame);
    if (hourly != null) _enqueueHourly(hourly);
  }

  void _registerCandidate(TelemetryEventCandidate event) {
    _continuousEvents.add(event);
    _eventCount++;
    if (!_eventController.isClosed) _eventController.add(event);
    final hourly = _hourlyAggregator.addEvent(event);
    if (hourly != null) _enqueueHourly(hourly);

    final evidenceId = IdGenerator.create('evidence');
    final updated = event.withEvidenceChunkId(evidenceId);
    _replaceBufferedEvent(updated);
    final minimumTime = event.startedAtMillis -
        configuration.eventEvidenceBefore.inMilliseconds;
    _activeEvidence.add(
      EventEvidenceCapture(
        event: updated,
        captureUntilMillis:
            event.endedAtMillis + configuration.eventEvidenceAfter.inMilliseconds,
        initialMotion: _motionRing.since(minimumTime),
        initialLocations: _locationRing.since(minimumTime),
      ),
    );
  }

  void _replaceBufferedEvent(TelemetryEventCandidate updated) {
    final index = _continuousEvents.indexWhere((value) => value.id == updated.id);
    if (index >= 0) _continuousEvents[index] = updated;
  }

  void _finalizeCompletedEvidence(int timestampMillis) {
    final completed = _activeEvidence
        .where((capture) => capture.isCompleteAt(timestampMillis))
        .toList(growable: false);
    for (final capture in completed) {
      _activeEvidence.remove(capture);
      _enqueueEvidence(capture);
    }
  }

  void _finalizeAllEvidence(int timestampMillis) {
    final remaining = List<EventEvidenceCapture>.from(_activeEvidence);
    _activeEvidence.clear();
    for (final capture in remaining) {
      _enqueueEvidence(capture, actualEndedAtMillis: timestampMillis);
    }
  }

  void _enqueueEvidence(
    EventEvidenceCapture capture, {
    int? actualEndedAtMillis,
  }) {
    // The chunk start must not exceed any captured sample timestamp, or the
    // delta encoding would fail. GPS fixes can carry timestamps earlier than
    // the nominal evidence window, for example a cached first fix.
    var start = math.max(
      _startedAtMillis!,
      capture.event.startedAtMillis -
          configuration.eventEvidenceBefore.inMilliseconds,
    );
    for (final sample in capture.locationSamples) {
      start = math.min(start, sample.timestampMillis);
    }
    for (final sample in capture.motionSamples) {
      start = math.min(start, sample.timestampMicros ~/ 1000);
    }

    final chunk = TelemetryChunk(
      schemaVersion: TelemetryBinaryCodec.schemaVersion,
      tripId: _tripId!,
      chunkId: capture.event.evidenceChunkId!,
      chunkIndex: _nextChunkIndex(),
      type: TelemetryChunkType.eventEvidence,
      startedAtMillis: start,
      endedAtMillis: math.max(
        capture.event.endedAtMillis,
        actualEndedAtMillis ?? capture.captureUntilMillis,
      ),
      locations: List<LocationSample>.unmodifiable(capture.locationSamples),
      rawMotionSamples:
          List<RawMotionSample>.unmodifiable(capture.motionSamples),
      events: <TelemetryEventCandidate>[capture.event],
    );
    _enqueueWrite(() async {
      await store.writeChunk(chunk, _codec.encode(chunk));
    });
  }

  void _enqueueHourly(HourlyTelemetryAggregate aggregate) {
    final chunk = TelemetryChunk(
      schemaVersion: TelemetryBinaryCodec.schemaVersion,
      tripId: _tripId!,
      chunkId: IdGenerator.create('hour'),
      chunkIndex: _nextChunkIndex(),
      type: TelemetryChunkType.hourlyAggregate,
      startedAtMillis: aggregate.hourStartedAtMillis,
      endedAtMillis: aggregate.hourEndedAtMillis,
      hourlyAggregate: aggregate,
    );
    _enqueueWrite(() async {
      await store.writeChunk(chunk, _codec.encode(chunk));
    });
  }

  void _checkChunkFlush(int timestampMillis) {
    final start = _chunkStartedAtMillis ?? timestampMillis;
    final durationReached = timestampMillis - start >=
        configuration.chunkMaximumDuration.inMilliseconds;
    final estimatedBytes = _continuousLocations.length * 36 +
        _continuousFrames.length * 170 +
        _continuousEvents.length * 120;
    if (durationReached ||
        estimatedBytes >= configuration.chunkMaximumEstimatedBytes) {
      _enqueueContinuousFlush(
        force: false,
        endedAtMillis: timestampMillis,
      );
    }
  }

  void _enqueueContinuousFlush({
    required bool force,
    required int endedAtMillis,
  }) {
    if (_continuousLocations.isEmpty &&
        _continuousFrames.isEmpty &&
        _continuousEvents.isEmpty) {
      if (force) _chunkStartedAtMillis = endedAtMillis;
      return;
    }

    final locations = List<LocationSample>.from(_continuousLocations);
    final frames = List<MotionFrame>.from(_continuousFrames);
    final events = List<TelemetryEventCandidate>.from(_continuousEvents);
    _continuousLocations.clear();
    _continuousFrames.clear();
    _continuousEvents.clear();

    // Scan every element rather than assuming list order matches time order:
    // events complete in end order, not start order, and GPS timestamps can
    // regress. The chunk start must not exceed any contained timestamp, or
    // the delta encoding would fail.
    var start = endedAtMillis;
    var end = endedAtMillis;
    for (final value in locations) {
      start = math.min(start, value.timestampMillis);
      end = math.max(end, value.timestampMillis);
    }
    for (final value in frames) {
      start = math.min(start, value.startedAtMillis);
      end = math.max(end, value.startedAtMillis + value.durationMillis);
    }
    for (final value in events) {
      start = math.min(start, value.startedAtMillis);
      end = math.max(end, value.endedAtMillis);
    }

    final chunk = TelemetryChunk(
      schemaVersion: TelemetryBinaryCodec.schemaVersion,
      tripId: _tripId!,
      chunkId: IdGenerator.create('chunk'),
      chunkIndex: _nextChunkIndex(),
      type: TelemetryChunkType.continuous,
      startedAtMillis: start,
      endedAtMillis: end,
      locations: locations,
      motionFrames: frames,
      events: events,
    );
    _chunkStartedAtMillis = endedAtMillis;
    _enqueueWrite(() async {
      await store.writeChunk(chunk, _codec.encode(chunk));
    });
  }

  void _enqueueWrite(Future<void> Function() action) {
    _writeTail = _writeTail.then((_) => action()).catchError((Object error) {
      if (!_errorController.isClosed) _errorController.add(error);
    });
  }

  int _nextChunkIndex() => _chunkIndex++;

  bool _isValidLocation(LocationSample sample) {
    return !sample.isMocked &&
        sample.accuracyMeters <= configuration.maximumLocationAccuracyMeters &&
        sample.speedKph <= configuration.maximumPlausibleSpeedKph &&
        sample.latitude >= -90 &&
        sample.latitude <= 90 &&
        sample.longitude >= -180 &&
        sample.longitude <= 180;
  }

  void _accumulateDistance(LocationSample sample) {
    final previous = _previousValidLocation;
    if (previous != null) {
      final deltaMillis = sample.timestampMillis - previous.timestampMillis;
      if (deltaMillis > 0 && deltaMillis <= 10000) {
        final distance = _haversineMeters(previous, sample);
        final maximumMeters =
            configuration.maximumPlausibleSpeedKph / 3.6 *
                (deltaMillis / 1000) *
                1.25;
        if (distance <= maximumMeters) _rawGpsDistanceMeters += distance;
      }
    }
    _previousValidLocation = sample;
  }

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
    return earthRadiusMeters *
        2 *
        math.atan2(math.sqrt(h), math.sqrt(math.max(0, 1 - h)));
  }

  double _radians(double degrees) => degrees * math.pi / 180;

  void _handleSourceError(Object error, StackTrace stackTrace) {
    _reportError(error);
  }

  void _resetRuntimeBuffers() {
    _continuousLocations.clear();
    _continuousFrames.clear();
    _continuousEvents.clear();
    _completeLocationTrace.clear();
    _activeEvidence.clear();
    _motionRing.clear();
    _locationRing.clear();
    _motionAggregator.reset();
    _hourlyAggregator.reset();
    _detector.reset();
    _chunkIndex = 0;
    _motionFrameCount = 0;
    _eventCount = 0;
    _rawGpsDistanceMeters = 0;
    _previousValidLocation = null;
  }

  void _ensureNotDisposed() {
    if (_state == TelemetryRecorderState.disposed) {
      throw StateError('Recorder has been disposed.');
    }
  }

  /// Stops an active trip when possible and closes recorder streams.
  Future<void> dispose() async {
    if (_state == TelemetryRecorderState.disposed) return;
    if (_state == TelemetryRecorderState.recording) {
      try {
        await stopTrip();
      } catch (error) {
        // stopTrip already tears down the sources on failure; dispose only
        // reports the error so it never throws itself.
        _reportError(error);
      }
    }
    _state = TelemetryRecorderState.disposed;
    await _eventController.close();
    await _errorController.close();
  }
}
