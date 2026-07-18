import 'osrm_match_result.dart';

/// Result returned after local trip recording has stopped.
class TelemetryTripResult {
  /// Creates a trip result.
  const TelemetryTripResult({
    required this.tripId,
    required this.startedAtMillis,
    required this.endedAtMillis,
    required this.rawGpsDistanceMeters,
    required this.locationSampleCount,
    required this.motionFrameCount,
    required this.eventCount,
    required this.chunkCount,
    required this.pendingUploadCount,
    this.osrmMatch,
    this.routeProcessingError,
  });

  /// Trip identifier.
  final String tripId;

  /// Start timestamp.
  final int startedAtMillis;

  /// End timestamp.
  final int endedAtMillis;

  /// Distance calculated directly from accepted GPS points.
  final double rawGpsDistanceMeters;

  /// Accepted location record count.
  final int locationSampleCount;

  /// One-second motion frame count.
  final int motionFrameCount;

  /// Candidate event count.
  final int eventCount;

  /// Persisted chunk count.
  final int chunkCount;

  /// Chunks still waiting for backend acknowledgement.
  final int pendingUploadCount;

  /// Optional post-trip OSRM Match result.
  final OsrmMatchResult? osrmMatch;

  /// Non-fatal OSRM processing error.
  final String? routeProcessingError;
}
