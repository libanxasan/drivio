import 'dart:async';

import '../model/location_sample.dart';
import '../model/raw_motion_sample.dart';
import 'drive_detector.dart';
import 'driving_telemetry_recorder.dart';
import 'location_source.dart';
import 'motion_source.dart';

/// Starts and stops [recorder] automatically from GPS speed and accelerometer
/// activity, so every drive is recorded without the user pressing a button.
///
/// Detection keeps the location and motion sources running while idle. Give it
/// and the recorder leases on the same shared sources (see `SourceLeases`), so
/// each sensor starts once.
class AutomaticTripRecorder {
  /// Creates the controller. [userId] is read when a drive starts.
  AutomaticTripRecorder({
    required this.recorder,
    required LocationSource location,
    MotionSource? motion,
    required this.userId,
    DriveDetector? detector,
    this.metadata = const {},
    this.tickInterval = const Duration(seconds: 5),
    int Function()? clock,
  }) : _location = location,
       _motion = motion,
       detector = detector ?? DriveDetector(),
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// The recorder to start and stop.
  final DrivingTelemetryRecorder recorder;

  /// The decision logic.
  final DriveDetector detector;

  /// The owner of automatic recordings.
  final String? Function() userId;

  /// Metadata added to every automatic recording.
  final Map<String, Object?> metadata;

  /// How often time-based stop conditions are checked.
  final Duration tickInterval;

  final LocationSource _location;
  final MotionSource? _motion;
  final int Function() _clock;
  final _decisions = StreamController<DriveDecision>.broadcast();
  StreamSubscription<LocationSample>? _locations;
  StreamSubscription<RawMotionSample>? _motions;
  Timer? _ticker;
  Future<void> _tail = Future.value();
  bool _running = false;

  /// Decisions as they are acted on.
  Stream<DriveDecision> get decisions => _decisions.stream;

  /// Whether automatic detection is running.
  bool get isRunning => _running;

  /// Starts detection.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _locations = _location.samples.listen(
      (sample) => _apply(detector.onLocation(sample)),
    );
    _motions = _motion?.samples.listen(
      (sample) => _apply(detector.onMotion(sample)),
    );
    await _location.start();
    await _motion?.start();
    _ticker = Timer.periodic(
      tickInterval,
      (_) => _apply(detector.onTick(_clock())),
    );
  }

  void _apply(DriveDecision? decision) {
    if (decision == null) return;
    _tail = _tail.then((_) async {
      try {
        if (decision == DriveDecision.start && recorder.activeTripId == null) {
          final owner = userId();
          if (owner == null) return;
          await recorder.startTrip(
            userId: owner,
            metadata: {...metadata, 'trigger': 'automatic'},
          );
        } else if (decision == DriveDecision.stop && recorder.isRecording) {
          await recorder.stopTrip();
        }
        if (!_decisions.isClosed) _decisions.add(decision);
      } catch (error) {
        if (!_decisions.isClosed) _decisions.addError(error);
      }
    });
  }

  /// Stops detection. A recording in progress keeps running until [stopRecording].
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _ticker?.cancel();
    await _locations?.cancel();
    await _motions?.cancel();
    await _location.stop();
    await _motion?.stop();
    await _tail;
  }

  /// Stops detection and ends any recording it started.
  Future<void> dispose() async {
    await stop();
    if (recorder.isRecording) await recorder.stopTrip();
    await _decisions.close();
  }
}
