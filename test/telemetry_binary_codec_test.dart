import 'package:driving_telemetry/driving_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('binary codec round-trips compact telemetry', () {
    final chunk = TelemetryChunk(
      schemaVersion: TelemetryBinaryCodec.schemaVersion,
      tripId: 'trip-1',
      chunkId: 'chunk-1',
      chunkIndex: 0,
      type: TelemetryChunkType.continuous,
      startedAtMillis: 100000,
      endedAtMillis: 101000,
      locations: const <LocationSample>[
        LocationSample(
          timestampMillis: 100000,
          latitude: 11.5729,
          longitude: 43.1456,
          speedMps: 12.5,
          headingDegrees: 90,
          accuracyMeters: 4.2,
        ),
        LocationSample(
          timestampMillis: 101000,
          latitude: 11.5730,
          longitude: 43.1457,
          speedMps: 13.1,
          headingDegrees: 91,
          accuracyMeters: 4.5,
        ),
      ],
      motionFrames: const <MotionFrame>[
        MotionFrame(
          startedAtMillis: 100000,
          durationMillis: 1000,
          longitudinalAcceleration: AxisStatistics(
            minimum: -1.2,
            maximum: 2.8,
            mean: 0.4,
            standardDeviation: 0.7,
            rms: 0.9,
            sampleCount: 25,
          ),
          lateralAcceleration: AxisStatistics.empty,
          verticalAcceleration: AxisStatistics.empty,
          yawRate: AxisStatistics.empty,
          pitchRate: AxisStatistics.empty,
          rollRate: AxisStatistics.empty,
          phoneStability: 0.92,
          axisMappingCalibrated: true,
        ),
      ],
      events: const <TelemetryEventCandidate>[
        TelemetryEventCandidate(
          id: 'event-1',
          type: TelemetryEventType.harshAccelerationCandidate,
          startedAtMillis: 100200,
          endedAtMillis: 100700,
          confidence: 0.85,
          minimumValue: 2.8,
          maximumValue: 3.4,
          meanValue: 3.1,
        ),
      ],
    );

    final codec = TelemetryBinaryCodec();
    final encoded = codec.encode(chunk);
    final decoded = codec.decode(encoded);

    expect(decoded.tripId, chunk.tripId);
    expect(decoded.chunkId, chunk.chunkId);
    expect(decoded.locations, hasLength(2));
    expect(decoded.motionFrames, hasLength(1));
    expect(decoded.events, hasLength(1));
    expect(decoded.locations.last.latitude, closeTo(11.5730, 0.0000001));
    expect(decoded.motionFrames.first.phoneStability, closeTo(0.92, 0.001));
  });
}
