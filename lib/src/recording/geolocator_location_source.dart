import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../model/location_sample.dart';
import 'location_source.dart';

/// Location source backed by geolocator.
class GeolocatorLocationSource implements LocationSource {
  /// Creates a source.
  GeolocatorLocationSource({
    LocationSettings? locationSettings,
    this.requestPermission = true,
  }) : locationSettings = locationSettings ??
            const LocationSettings(
              accuracy: LocationAccuracy.bestForNavigation,
              distanceFilter: 0,
            );

  /// Settings passed directly to geolocator.
  final LocationSettings locationSettings;

  /// Whether the source requests permission during start.
  final bool requestPermission;

  final StreamController<LocationSample> _controller =
      StreamController<LocationSample>.broadcast();
  StreamSubscription<Position>? _subscription;
  bool _started = false;

  @override
  Stream<LocationSample> get samples => _controller.stream;

  @override
  Future<void> start() async {
    if (_started) return;
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw const LocationSourceException('Location services are disabled.');
    }

    var permission = await Geolocator.checkPermission();
    if (requestPermission && permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw LocationSourceException(
        'Location permission is not available: ${permission.name}.',
      );
    }

    _started = true;
    _subscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      (position) {
        final timestamp = position.timestamp.toUtc().millisecondsSinceEpoch;
        _controller.add(
          LocationSample(
            timestampMillis: timestamp,
            latitude: position.latitude,
            longitude: position.longitude,
            speedMps: position.speed < 0 ? 0 : position.speed,
            headingDegrees: position.heading < 0 ? 0 : position.heading,
            accuracyMeters: position.accuracy,
            altitudeMeters: position.altitude,
            speedAccuracyMps: position.speedAccuracy,
            headingAccuracyDegrees: position.headingAccuracy,
            isMocked: position.isMocked,
          ),
        );
      },
      onError: _controller.addError,
    );
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    await _subscription?.cancel();
    _subscription = null;
  }

  /// Releases the stream controller.
  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}

/// Location collection failure.
class LocationSourceException implements Exception {
  /// Creates an exception.
  const LocationSourceException(this.message);

  /// Error description.
  final String message;

  @override
  String toString() => 'LocationSourceException: $message';
}
