import 'dart:typed_data';

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

  test('encoding tolerates out-of-order timestamps', () {
    final chunk = TelemetryChunk(
      schemaVersion: TelemetryBinaryCodec.schemaVersion,
      tripId: 'trip-1',
      chunkId: 'chunk-1',
      chunkIndex: 0,
      type: TelemetryChunkType.continuous,
      startedAtMillis: 100000,
      endedAtMillis: 103000,
      locations: const <LocationSample>[
        LocationSample(
          timestampMillis: 100000,
          latitude: 11.5729,
          longitude: 43.1456,
          speedMps: 12.5,
          headingDegrees: 90,
          accuracyMeters: 4.2,
        ),
        // A GPS clock correction can move one sample backwards in time.
        LocationSample(
          timestampMillis: 99500,
          latitude: 11.5730,
          longitude: 43.1457,
          speedMps: 13.1,
          headingDegrees: 91,
          accuracyMeters: 4.5,
        ),
        LocationSample(
          timestampMillis: 103000,
          latitude: 11.5731,
          longitude: 43.1458,
          speedMps: 13.4,
          headingDegrees: 92,
          accuracyMeters: 4.4,
        ),
      ],
    );

    final codec = TelemetryBinaryCodec();
    final decoded = codec.decode(codec.encode(chunk));

    expect(decoded.locations, hasLength(3));
    // The out-of-order sample collapses onto its predecessor and later
    // timestamps stay exact instead of the whole chunk being lost.
    expect(decoded.locations[0].timestampMillis, 100000);
    expect(decoded.locations[1].timestampMillis, 100000);
    expect(decoded.locations[2].timestampMillis, 103000);
    expect(decoded.locations[1].latitude, closeTo(11.5730, 0.0000001));
  });

  test('encoding tolerates events with negative speeds and early starts', () {
    final chunk = TelemetryChunk(
      schemaVersion: TelemetryBinaryCodec.schemaVersion,
      tripId: 'trip-1',
      chunkId: 'chunk-1',
      chunkIndex: 0,
      type: TelemetryChunkType.continuous,
      startedAtMillis: 100000,
      endedAtMillis: 101000,
      events: const <TelemetryEventCandidate>[
        TelemetryEventCandidate(
          id: 'event-1',
          type: TelemetryEventType.wrongWayCandidate,
          // External candidates can carry timestamps outside the chunk range
          // and platform speed conventions can be negative for "unknown".
          startedAtMillis: 99000,
          endedAtMillis: 98000,
          confidence: 0.5,
          minimumValue: 0,
          maximumValue: 0,
          meanValue: 0,
          speedBeforeMps: -1,
          speedAfterMps: -1,
        ),
      ],
    );

    final codec = TelemetryBinaryCodec();
    final decoded = codec.decode(codec.encode(chunk));

    expect(decoded.events, hasLength(1));
    expect(decoded.events.single.speedBeforeMps, 0);
    expect(decoded.events.single.durationMillis, 0);
  });

  test('rejects payloads with a bad magic value', () {
    final codec = TelemetryBinaryCodec();
    expect(
      () => codec.decode(Uint8List.fromList(<int>[0, 1, 2, 3, 4, 5])),
      throwsFormatException,
    );
  });
}
