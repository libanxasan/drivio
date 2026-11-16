import 'dart:async';
import 'dart:math' as math;

import 'telemetry_synchronizer.dart';

/// Runs [TelemetrySynchronizer] passes while the app is alive.
///
/// After a complete pass the next one runs after [interval]. After a pass
/// that failed or was interrupted, the scheduler backs off exponentially from
/// [minimumRetryDelay] up to [interval], with jitter. A `true` event on
/// [connectivity] (for example from `connectivity_plus`) triggers a pass
/// immediately, so data goes out as soon as the phone is back online.
///
/// For uploads while the app is suspended or terminated, register an OS
/// background task (WorkManager on Android, BGTaskScheduler on iOS) that
/// calls [runBackgroundTelemetrySync].
class TelemetrySyncScheduler {
  /// Creates a scheduler. Call [start] to begin.
  TelemetrySyncScheduler({
    required this.synchronizer,
    this.interval = const Duration(minutes: 5),
    this.minimumRetryDelay = const Duration(seconds: 15),
    this.maximumChunksPerPass,
    Stream<bool>? connectivity,
    math.Random? random,
  })  : _connectivity = connectivity,
        _random = random ?? math.Random();

  /// Synchronizer used for each pass.
  final TelemetrySynchronizer synchronizer;

  /// Delay between passes while uploads succeed, and the backoff ceiling.
  final Duration interval;

  /// First delay after a failed pass.
  final Duration minimumRetryDelay;

  /// Optional cap on uploads per pass.
  final int? maximumChunksPerPass;

  final Stream<bool>? _connectivity;
  final math.Random _random;
  final StreamController<TelemetrySyncResult> _results =
      StreamController<TelemetrySyncResult>.broadcast();
  final StreamController<Object> _errors = StreamController<Object>.broadcast();

  StreamSubscription<bool>? _connectivitySubscription;
  Timer? _timer;
  Future<TelemetrySyncResult>? _running;
  int _consecutiveFailures = 0;
  bool _online = true;
  bool _started = false;
  bool _disposed = false;
  DateTime? _nextRunAt;

  /// Result of every pass.
  Stream<TelemetrySyncResult> get results => _results.stream;

  /// Errors thrown by a pass, for example a store failure.
  Stream<Object> get errors => _errors.stream;

  /// Whether the scheduler is running.
  bool get isStarted => _started;

  /// When the next pass is planned, or null while offline or stopped.
  DateTime? get nextRunAt => _nextRunAt;

  /// Failed passes in a row.
  int get consecutiveFailures => _consecutiveFailures;

  /// Starts scheduling and runs a first pass right away.
  void start() {
    if (_disposed) throw StateError('TelemetrySyncScheduler is disposed.');
    if (_started) return;
    _started = true;
    _connectivitySubscription = _connectivity?.listen((online) {
      final cameOnline = online && !_online;
      _online = online;
      if (!online) {
        _cancelTimer();
      } else if (cameOnline) {
        unawaited(_runAndReschedule());
      }
    });
    unawaited(_runAndReschedule());
  }

  /// Stops scheduling. A pass already running completes.
  Future<void> stop() async {
    _started = false;
    _cancelTimer();
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
  }

  /// Runs a pass now, or joins the one already running.
  Future<TelemetrySyncResult> syncNow() {
    return _running ??= synchronizer
        .synchronize(maximumChunks: maximumChunksPerPass)
        .whenComplete(() => _running = null);
  }

  Future<void> _runAndReschedule() async {
    _cancelTimer();
    if (!_started || !_online) return;
    try {
      final result = await syncNow();
      if (!_results.isClosed) _results.add(result);
      _consecutiveFailures =
          result.failed > 0 || result.interrupted ? _consecutiveFailures + 1 : 0;
      if (result.remaining > 0 && !result.interrupted && result.failed == 0) {
        // More due chunks than one pass allows: continue right away.
        _schedule(Duration.zero);
        return;
      }
    } catch (error) {
      _consecutiveFailures++;
      if (!_errors.isClosed) _errors.add(error);
    }
    _schedule(_nextDelay());
  }

  Duration _nextDelay() {
    if (_consecutiveFailures == 0) return interval;
    final exponent = math.min(_consecutiveFailures - 1, 20);
    final raw = minimumRetryDelay.inMilliseconds * math.pow(2, exponent);
    final capped = math.min(raw, interval.inMilliseconds.toDouble());
    final jittered = capped * (0.8 + _random.nextDouble() * 0.4);
    return Duration(milliseconds: jittered.round());
  }

  void _schedule(Duration delay) {
    if (!_started || !_online) return;
    _cancelTimer();
    _nextRunAt = DateTime.now().add(delay);
    _timer = Timer(delay, () => unawaited(_runAndReschedule()));
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
    _nextRunAt = null;
  }

  /// Stops the scheduler and closes its streams.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    try {
      await _running;
    } catch (_) {
      // Reported through [errors] already.
    }
    await _results.close();
    await _errors.close();
  }
}

/// One upload pass for an OS background task.
///
/// Returns true when the task can report success. Returning false lets
/// WorkManager or BGTaskScheduler retry with its own backoff. The pass stops
/// starting new uploads after [timeBudget], which keeps it inside the roughly
/// 30 seconds iOS grants to a background refresh task.
///
/// Background tasks run in their own isolate, so use a store that is safe to
/// open from several isolates, such as `SqliteTelemetryStore`. Uploads are
/// idempotent, so a chunk sent by both isolates is acknowledged as a
/// duplicate rather than stored twice.
Future<bool> runBackgroundTelemetrySync(
  TelemetrySynchronizer synchronizer, {
  Duration timeBudget = const Duration(seconds: 25),
  int? maximumChunks,
}) async {
  try {
    final result = await synchronizer.synchronize(
      maximumChunks: maximumChunks,
      timeBudget: timeBudget,
    );
    return result.failed == 0 && !result.interrupted;
  } catch (_) {
    return false;
  }
}
