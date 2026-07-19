import 'event_candidate.dart';
import 'hourly_aggregate.dart';
import 'location_sample.dart';
import 'motion_frame.dart';
import 'raw_motion_sample.dart';

/// Telemetry chunk categories.
enum TelemetryChunkType {
  /// Condensed continuous locations, motion frames, and event summaries.
  continuous,

  /// High-resolution raw telemetry around one candidate event.
  eventEvidence,

  /// One statistical aggregate per hour.
  hourlyAggregate,

  /// Compressed matched-route JSON artifact.
  route,

  /// Compressed trip-manifest JSON artifact.
  tripManifest,
}

/// In-memory telemetry payload before binary encoding.
class TelemetryChunk {
  /// Creates a chunk.
  const TelemetryChunk({
    required this.schemaVersion,
    required this.tripId,
    required this.chunkId,
    required this.chunkIndex,
    required this.type,
    required this.startedAtMillis,
    required this.endedAtMillis,
    this.locations = const <LocationSample>[],
    this.motionFrames = const <MotionFrame>[],
    this.rawMotionSamples = const <RawMotionSample>[],
    this.events = const <TelemetryEventCandidate>[],
    this.hourlyAggregate,
  });

  /// Binary schema version.
  final int schemaVersion;

  /// Parent trip identifier.
  final String tripId;

  /// Stable chunk identifier.
  final String chunkId;

  /// Monotonic trip-local chunk index.
  final int chunkIndex;

  /// Chunk category.
  final TelemetryChunkType type;

  /// Earliest represented time.
  final int startedAtMillis;

  /// Latest represented time.
  final int endedAtMillis;

  /// Compact location records.
  final List<LocationSample> locations;

  /// One-second motion frames.
  final List<MotionFrame> motionFrames;

  /// High-resolution event evidence.
  final List<RawMotionSample> rawMotionSamples;

  /// Candidate event summaries.
  final List<TelemetryEventCandidate> events;

  /// Optional hourly aggregate.
  final HourlyTelemetryAggregate? hourlyAggregate;
}
