import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:driving_telemetry/driving_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeMotionSource implements MotionSource {
  _FakeMotionSource({this.failOnStart = false});

  final bool failOnStart;
  int startCount = 0;
  int stopCount = 0;

  final StreamController<RawMotionSample> controller =
      StreamController<RawMotionSample>.broadcast();

  @override
  Stream<RawMotionSample> get samples => controller.stream;

  @override
  Future<void> start() async {
    startCount++;
    if (failOnStart) {
      throw StateError('Motion sensors are unavailable.');
    }
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }
}

class _FakeLocationSource implements LocationSource {
  int startCount = 0;
  int stopCount = 0;

  final StreamController<LocationSample> controller =
      StreamController<LocationSample>.broadcast();

  @override
  Stream<LocationSample> get samples => controller.stream;

  @override
  Future<void> start() async {
    startCount++;
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }
}

/// Delegating store that can fail JSON artifact writes.
class _FlakyStore implements TelemetryStore {
  _FlakyStore(this.inner);

  final TelemetryStore inner;
  bool failJsonArtifacts = false;

  @override
  Future<void> initialize() => inner.initialize();

  @override
  Future<TripManifest> createTrip({
    required String tripId,
    required String userId,
    required int startedAtMillis,
    required int schemaVersion,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    return inner.createTrip(
      tripId: tripId,
      userId: userId,
      startedAtMillis: startedAtMillis,
      schemaVersion: schemaVersion,
      metadata: metadata,
    );
  }

  @override
  Future<StoredTelemetryChunk> writeChunk(
    TelemetryChunk chunk,
    Uint8List uncompressedBytes,
  ) {
    return inner.writeChunk(chunk, uncompressedBytes);
  }

  @override
  Future<StoredTelemetryChunk> writeJsonArtifact({
    required String tripId,
    required String chunkId,
    required int chunkIndex,
    required TelemetryChunkType type,
    required int startedAtMillis,
    required int endedAtMillis,
    required int schemaVersion,
    required Map<String, Object?> value,
  }) {
    if (failJsonArtifacts) {
      throw const FileSystemException('Simulated storage failure.');
    }
    return inner.writeJsonArtifact(
      tripId: tripId,
      chunkId: chunkId,
      chunkIndex: chunkIndex,
      type: type,
      startedAtMillis: startedAtMillis,
      endedAtMillis: endedAtMillis,
      schemaVersion: schemaVersion,
      value: value,
    );
  }

  @override
  Future<void> closeTrip({
    required String tripId,
    required int endedAtMillis,
    Map<String, Object?> metadataUpdates = const <String, Object?>{},
  }) {
    return inner.closeTrip(
      tripId: tripId,
      endedAtMillis: endedAtMillis,
      metadataUpdates: metadataUpdates,
    );
  }

  @override
  Future<TripManifest> readManifest(String tripId) =>
      inner.readManifest(tripId);

  @override
  Future<List<PendingTelemetryChunk>> listPendingChunks() =>
      inner.listPendingChunks();

  @override
  Future<Uint8List> readStoredChunk(StoredTelemetryChunk chunk) =>
      inner.readStoredChunk(chunk);

  @override
  Future<void> markUploading(String tripId, String chunkId) =>
      inner.markUploading(tripId, chunkId);

  @override
  Future<void> markUploaded(String tripId, String chunkId) =>
      inner.markUploaded(tripId, chunkId);

  @override
  Future<void> markFailed(String tripId, String chunkId, String error) =>
      inner.markFailed(tripId, chunkId, error);

  @override
  Future<void> deleteChunkFile(String tripId, String chunkId) =>
      inner.deleteChunkFile(tripId, chunkId);

  @override
  Future<int> pendingChunkCount(String tripId) =>
      inner.pendingChunkCount(tripId);
}

void main() {
  test('failed start stops the already-started location source', () async {
    final temporary =
        await Directory.systemTemp.createTemp('telemetry_lifecycle_');
    addTearDown(() => temporary.delete(recursive: true));

    final motion = _FakeMotionSource(failOnStart: true);
    final location = _FakeLocationSource();
    final recorder = DrivingTelemetryRecorder(
      store: FileTelemetryStore(rootDirectory: temporary),
      motionSource: motion,
      locationSource: location,
    );

    await expectLater(
      recorder.startTrip(userId: 'user-1'),
      throwsA(isA<StateError>()),
    );

    expect(location.startCount, 1);
    expect(location.stopCount, 1);
    expect(recorder.state, TelemetryRecorderState.idle);
    expect(recorder.activeTripId, isNull);

    await recorder.dispose();
    await motion.controller.close();
    await location.controller.close();
  });

  test('recorder recovers to idle when stop-time persistence fails', () async {
    final temporary =
        await Directory.systemTemp.createTemp('telemetry_lifecycle_');
    addTearDown(() => temporary.delete(recursive: true));

    final motion = _FakeMotionSource();
    final location = _FakeLocationSource();
    final store = _FlakyStore(FileTelemetryStore(rootDirectory: temporary));
    final recorder = DrivingTelemetryRecorder(
      store: store,
      motionSource: motion,
      locationSource: location,
    );

    await recorder.startTrip(userId: 'user-1');
    store.failJsonArtifacts = true;

    await expectLater(
      recorder.stopTrip(),
      throwsA(isA<FileSystemException>()),
    );
    expect(recorder.state, TelemetryRecorderState.idle);
    expect(recorder.activeTripId, isNull);

    // The recorder must remain usable for the next trip.
    store.failJsonArtifacts = false;
    final tripId = await recorder.startTrip(userId: 'user-1');
    final result = await recorder.stopTrip();
    expect(result.tripId, tripId);
    expect(recorder.state, TelemetryRecorderState.idle);

    await recorder.dispose();
    await motion.controller.close();
    await location.controller.close();
  });

  test('rejects invalid duration configuration at construction', () async {
    final temporary =
        await Directory.systemTemp.createTemp('telemetry_lifecycle_');
    addTearDown(() => temporary.delete(recursive: true));

    expect(
      () => DrivingTelemetryRecorder(
        store: FileTelemetryStore(rootDirectory: temporary),
        motionSource: _FakeMotionSource(),
        locationSource: _FakeLocationSource(),
        configuration: const TelemetryConfiguration(
          motionFrameDuration: Duration.zero,
        ),
      ),
      throwsArgumentError,
    );
  });
}
