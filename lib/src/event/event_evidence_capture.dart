import '../model/event_candidate.dart';
import '../model/location_sample.dart';
import '../model/raw_motion_sample.dart';

/// Mutable capture of raw telemetry around one candidate event.
class EventEvidenceCapture {
  /// Creates a capture.
  EventEvidenceCapture({
    required this.event,
    required this.captureUntilMillis,
    required List<RawMotionSample> initialMotion,
    required List<LocationSample> initialLocations,
  })  : motionSamples = <RawMotionSample>[...initialMotion],
        locationSamples = <LocationSample>[...initialLocations];

  /// Candidate being documented.
  TelemetryEventCandidate event;

  /// Time after which no more evidence is required.
  final int captureUntilMillis;

  /// High-resolution motion samples.
  final List<RawMotionSample> motionSamples;

  /// Location samples around the event.
  final List<LocationSample> locationSamples;

  /// Whether the supplied timestamp completes the capture.
  bool isCompleteAt(int timestampMillis) => timestampMillis >= captureUntilMillis;
}
