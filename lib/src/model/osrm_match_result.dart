/// Coordinate in longitude, latitude order.
class RouteCoordinate {
  /// Creates a route coordinate.
  const RouteCoordinate(this.longitude, this.latitude);

  /// Longitude.
  final double longitude;

  /// Latitude.
  final double latitude;

  /// JSON-compatible array.
  List<double> toJson() => <double>[longitude, latitude];
}

/// One OSRM matched sub-trace.
class OsrmSubMatch {
  /// Creates a sub-match.
  const OsrmSubMatch({
    required this.distanceMeters,
    required this.durationSeconds,
    required this.confidence,
    required this.geometry,
    required this.roadNames,
  });

  /// Matched route distance.
  final double distanceMeters;

  /// Matched route duration.
  final double durationSeconds;

  /// OSRM matching confidence.
  final double confidence;

  /// Matched GeoJSON coordinates.
  final List<RouteCoordinate> geometry;

  /// Distinct road names from route steps.
  final List<String> roadNames;

  /// JSON representation.
  Map<String, Object> toJson() => <String, Object>{
        'distanceMeters': distanceMeters,
        'durationSeconds': durationSeconds,
        'confidence': confidence,
        'geometry': geometry.map((value) => value.toJson()).toList(),
        'roadNames': roadNames,
      };
}

/// Complete OSRM Match result, possibly composed of multiple sub-traces.
class OsrmMatchResult {
  /// Creates a match result.
  const OsrmMatchResult({
    required this.subMatches,
    required this.tracepointCount,
    required this.matchedTracepointCount,
  });

  /// Matched sub-traces.
  final List<OsrmSubMatch> subMatches;

  /// Number of input tracepoints.
  final int tracepointCount;

  /// Number of tracepoints matched by OSRM.
  final int matchedTracepointCount;

  /// Total matched distance.
  double get totalDistanceMeters => subMatches.fold<double>(
        0,
        (sum, value) => sum + value.distanceMeters,
      );

  /// Average match confidence weighted by distance.
  double get weightedConfidence {
    final distance = totalDistanceMeters;
    if (distance <= 0) return 0;
    return subMatches.fold<double>(
          0,
          (sum, value) => sum + value.confidence * value.distanceMeters,
        ) /
        distance;
  }

  /// JSON representation.
  Map<String, Object> toJson() => <String, Object>{
        'subMatches': subMatches.map((value) => value.toJson()).toList(),
        'tracepointCount': tracepointCount,
        'matchedTracepointCount': matchedTracepointCount,
        'totalDistanceMeters': totalDistanceMeters,
        'weightedConfidence': weightedConfidence,
      };
}
