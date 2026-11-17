import 'dart:async';

import 'package:driving_telemetry/driving_telemetry.dart';
import 'package:flutter/widgets.dart';

/// Screen state for one recorder, separate from the widgets so it can be
/// tested and reused.
class TripController extends ChangeNotifier with WidgetsBindingObserver {
  /// Creates a controller. Call [initialize] before use.
  TripController({
    required this.recorder,
    required this.store,
    required this.userId,
    this.scheduler,
    List<RecoveredTrip> recovered = const <RecoveredTrip>[],
    this.onDispose,
    DateTime Function()? clock,
  })  : _recovered = recovered,
        _clock = clock ?? DateTime.now;

  /// Recorder owned by this controller.
  final DrivingTelemetryRecorder recorder;

  /// Store shared with [recorder].
  final TelemetryStore store;

  /// User recorded with each trip.
  final String userId;

  /// Foreground upload scheduler, or null when uploads are off.
  final TelemetrySyncScheduler? scheduler;

  /// Called after the recorder is disposed, for example to close storage.
  final Future<void> Function()? onDispose;

  final DateTime Function() _clock;
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];
  Timer? _ticker;
  bool _disposed = false;

  List<RecoveredTrip> _recovered;
  DateTime? _tripStartedAt;
  LocationSample? _lastLocation;
  int _fixCount = 0;
  int _eventCount = 0;
  TelemetryTripResult? _lastTrip;
  String? _error;
  List<TripManifest> _trips = const <TripManifest>[];
  int _pendingUploads = 0;
  TelemetrySyncResult? _lastSync;
  DateTime? _lastSyncAt;
  bool _syncing = false;

  /// Recorder lifecycle state.
  TelemetryRecorderState get recorderState => recorder.state;

  /// Whether a trip is being recorded.
  bool get isRecording => recorder.isRecording;

  /// Whether the last trip still needs its save retried.
  bool get canRetrySave => recorder.canRetryTripSave;

  /// Whether a start or stop is in progress.
  bool get isBusy =>
      recorder.state == TelemetryRecorderState.starting ||
      recorder.state == TelemetryRecorderState.stopping;

  /// Identifier of the trip being recorded.
  String? get activeTripId => recorder.activeTripId;

  /// Time since the current trip started.
  Duration get elapsed {
    final started = _tripStartedAt;
    if (started == null || !isRecording) return Duration.zero;
    return _clock().difference(started);
  }

  /// Latest GPS fix of the current trip.
  LocationSample? get lastLocation => _lastLocation;

  /// GPS fixes received during the current trip.
  int get fixCount => _fixCount;

  /// Candidate events detected during the current trip.
  int get eventCount => _eventCount;

  /// Whether motion sensors are paused while the vehicle is stationary.
  bool get isMotionPaused => recorder.isMotionPaused;

  /// Result of the last trip saved in this session.
  TelemetryTripResult? get lastTrip => _lastTrip;

  /// User-facing error from the last action.
  String? get error => _error;

  /// Trips killed in an earlier session and closed at startup.
  List<RecoveredTrip> get recovered => _recovered;

  /// Stored trips, newest first.
  List<TripManifest> get trips => _trips;

  /// Chunks waiting for upload.
  int get pendingUploads => _pendingUploads;

  /// Whether an upload endpoint is configured.
  bool get uploadsEnabled => scheduler != null;

  /// Result of the last upload pass.
  TelemetrySyncResult? get lastSync => _lastSync;

  /// When the last upload pass finished.
  DateTime? get lastSyncAt => _lastSyncAt;

  /// Whether an upload pass triggered from the screen is running.
  bool get isSyncing => _syncing;

  /// Starts listening and loads stored trips.
  Future<void> initialize() async {
    WidgetsBinding.instance.addObserver(this);
    _subscriptions
      ..add(recorder.states.listen(_onState))
      ..add(
        recorder.locationSource.samples.listen(
          _onLocation,
          onError: (Object _) {},
        ),
      )
      ..add(recorder.candidateEvents.listen((_) {
        _eventCount++;
        _notify();
      }))
      ..add(recorder.errors.listen((_) {}, onError: (Object _) {}));
    final scheduler = this.scheduler;
    if (scheduler != null) {
      _subscriptions.add(scheduler.results.listen(_onSync));
      scheduler.start();
    }
    await refreshTrips();
  }

  void _onState(TelemetryRecorderState state) {
    if (state == TelemetryRecorderState.recording) {
      _tripStartedAt = _clock();
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _notify());
    } else if (state != TelemetryRecorderState.stopping) {
      _ticker?.cancel();
      _ticker = null;
    }
    _notify();
  }

  void _onLocation(LocationSample sample) {
    if (!isRecording) return;
    _lastLocation = sample;
    _fixCount++;
    _notify();
  }

  void _onSync(TelemetrySyncResult result) {
    _lastSync = result;
    _lastSyncAt = _clock();
    unawaited(refreshTrips());
  }

  /// Starts a trip, stops it, or retries a failed save.
  Future<void> toggleTrip() async {
    if (isBusy) return;
    final saving = isRecording || canRetrySave;
    _error = null;
    try {
      if (saving) {
        _lastTrip = await recorder.stopTrip();
        _notify();
        unawaited(scheduler?.syncNow().then(_onSync, onError: (Object _) {}));
      } else {
        _lastLocation = null;
        _fixCount = 0;
        _eventCount = 0;
        await recorder.startTrip(userId: userId);
      }
    } catch (error) {
      _error = switch (error) {
        LocationSourceException(:final message) => message,
        _ when saving => 'Trip save incomplete. Retry to finish saving.',
        _ => 'Could not start the trip. Try again.',
      };
      _notify();
    }
    await refreshTrips();
  }

  /// Runs an upload pass now.
  Future<void> syncNow() async {
    final scheduler = this.scheduler;
    if (scheduler == null || _syncing) return;
    _syncing = true;
    _notify();
    try {
      _onSync(await scheduler.syncNow());
    } catch (error) {
      _error = 'Upload failed: $error';
    } finally {
      _syncing = false;
      _notify();
    }
  }

  /// Hides the recovered-trips notice.
  void dismissRecovered() {
    _recovered = const <RecoveredTrip>[];
    _notify();
  }

  /// Reloads trip history and the upload queue size.
  Future<void> refreshTrips() async {
    try {
      final trips = await store.listTrips();
      final pending = await store.listPendingChunks();
      _trips = trips;
      _pendingUploads = pending.length;
    } catch (_) {
      // Keep the previous list; the next refresh retries.
    }
    _notify();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // The OS may kill a backgrounded app at any time. Persist buffered
        // samples now so a kill loses as little as possible.
        if (isRecording) unawaited(recorder.checkpoint());
      case AppLifecycleState.resumed:
        unawaited(refreshTrips());
      case AppLifecycleState.inactive:
        break;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_shutDown());
    super.dispose();
  }

  Future<void> _shutDown() async {
    await scheduler?.dispose();
    await recorder.dispose();
    await onDispose?.call();
  }
}
