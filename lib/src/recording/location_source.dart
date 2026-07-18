import '../model/location_sample.dart';

/// Location source abstraction.
abstract interface class LocationSource {
  /// Location sample stream.
  Stream<LocationSample> get samples;

  /// Starts location collection and requests required permissions when needed.
  Future<void> start();

  /// Stops location collection.
  Future<void> stop();
}
