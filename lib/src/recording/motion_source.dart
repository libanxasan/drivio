import '../model/raw_motion_sample.dart';

/// High-frequency motion source abstraction.
abstract interface class MotionSource {
  /// Motion sample stream.
  Stream<RawMotionSample> get samples;

  /// Starts sensor collection.
  Future<void> start();

  /// Stops sensor collection.
  Future<void> stop();
}
