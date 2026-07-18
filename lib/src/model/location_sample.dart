/// Compact-friendly GPS location sample.
class LocationSample {
  /// Creates a location sample.
  const LocationSample({
    required this.timestampMillis,
    required this.latitude,
    required this.longitude,
    required this.speedMps,
    required this.headingDegrees,
    required this.accuracyMeters,
    this.altitudeMeters = 0,
    this.speedAccuracyMps = 0,
    this.headingAccuracyDegrees = 0,
    this.isMocked = false,
  });

  /// UTC timestamp in milliseconds since Unix epoch.
  final int timestampMillis;

  /// WGS84 latitude.
  final double latitude;

  /// WGS84 longitude.
  final double longitude;

  /// GPS speed in meters per second.
  final double speedMps;

  /// Heading in degrees clockwise from north.
  final double headingDegrees;

  /// Horizontal accuracy in meters.
  final double accuracyMeters;

  /// Altitude in meters.
  final double altitudeMeters;

  /// Speed accuracy in meters per second.
  final double speedAccuracyMps;

  /// Heading accuracy in degrees.
  final double headingAccuracyDegrees;

  /// Whether the operating system reports a mocked location.
  final bool isMocked;

  /// Latitude quantized to 1e-7 degrees.
  int get latitudeE7 => (latitude * 10000000).round();

  /// Longitude quantized to 1e-7 degrees.
  int get longitudeE7 => (longitude * 10000000).round();

  /// Speed in kilometers per hour.
  double get speedKph => speedMps * 3.6;

  /// JSON representation.
  Map<String, Object> toJson() => <String, Object>{
        'timestampMillis': timestampMillis,
        'latitude': latitude,
        'longitude': longitude,
        'speedMps': speedMps,
        'headingDegrees': headingDegrees,
        'accuracyMeters': accuracyMeters,
        'altitudeMeters': altitudeMeters,
        'speedAccuracyMps': speedAccuracyMps,
        'headingAccuracyDegrees': headingAccuracyDegrees,
        'isMocked': isMocked,
      };
}
