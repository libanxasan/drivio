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
  _FakeLocationSource({this.startGate});

  final Completer<void>? startGate;
  int startCount = 0;
  int stopCount = 0;

  final StreamController<LocationSample> controller =
      StreamController<LocationSample>.broadcast();

  @override
  Stream<LocationSample> get samples => controller.stream;

  @override
  Future<void> start() async {
    startCount++;
    await startGate?.future;
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }
}

class _FlakyStore extends FileTelemetryStore {
  _FlakyStore(Directory root) : super(rootDirectory: root);

  bool failJsonArtifacts = false;
  bool failChunkWrites = false;
  bool failClose = false;
  Completer<void>? closeGate;
  final manifestWriteAttempts = <({String id, int index})>[];
  final chunkWriteAttempts = <TelemetryChunk>[];

  @override
  Future<StoredTelemetryChunk> writeChunk(
    TelemetryChunk chunk,
    Uint8List uncompressedBytes,
  ) {
    chunkWriteAttempts.add(chunk);
    if (failChunkWrites) {
      throw const FileSystemException('Simulated binary write failure.');
    }
    return super.writeChunk(chunk, uncompressedBytes);
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
    if (type == TelemetryChunkType.tripManifest) {
      manifestWriteAttempts.add((id: chunkId, index: chunkIndex));
    }
    if (failJsonArtifacts) {
      throw const FileSystemException('Simulated storage failure.');
    }
    return super.writeJsonArtifact(
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
  }) async {
    await closeGate?.future;
    if (failClose) {
      throw const FileSystemException('Simulated close failure.');
    }
    return super.closeTrip(
      tripId: tripId,
      endedAtMillis: endedAtMillis,
      metadataUpdates: metadataUpdates,
    );
  }
}

void main() {
  test('failed start stops the already-started location source', () async {
    final temporary =
        await Directory.systemTemp.createTemp('telemetry_lifecycle_');
    addTearDown(() => temporary.delete(recursive: true));

    final motion = _FakeMotionSource(failOnStart: true);
    final location = _FakeLocationSource();
    final store = FileTelemetryStore(rootDirectory: temporary);
    final recorder = DrivingTelemetryRecorder(
      store: store,
      motionSource: motion,
      locationSource: location,
    );

    await expectLater(
      recorder.startTrip(userId: 'user-1', tripId: 'failed-start'),
      throwsA(isA<StateError>()),
    );

    expect(location.startCount, 1);
    expect(location.stopCount, 1);
    expect(recorder.state, TelemetryRecorderState.idle);
    expect(recorder.activeTripId, isNull);
    expect(recorder.canRetryTripSave, isFalse);

    await recorder.dispose();
    await motion.controller.close();
    await location.controller.close();
  });

  test('failed manifest write can retry the same trip and artifact', () async {
    final temporary =
        await Directory.systemTemp.createTemp('telemetry_lifecycle_');
    addTearDown(() => temporary.delete(recursive: true));

    final motion = _FakeMotionSource();
    final location = _FakeLocationSource();
    final store = _FlakyStore(temporary);
    final recorder = DrivingTelemetryRecorder(
      store: store,
      motionSource: motion,
      locationSource: location,
    );

    final states = <TelemetryRecorderState>[];
    recorder.states.listen(states.add);
    final tripId = await recorder.startTrip(userId: 'user-1');
    store.failJsonArtifacts = true;

    await expectLater(
      recorder.stopTrip(),
      throwsA(isA<FileSystemException>()),
    );
    expect(recorder.state, TelemetryRecorderState.idle);
    expect(recorder.activeTripId, isNull);
    expect(recorder.canRetryTripSave, isTrue);
    await expectLater(recorder.startTrip(userId: 'user-1'), throwsStateError);

    store.failJsonArtifacts = false;
    final result = await recorder.stopTrip();
    expect(result.tripId, tripId);
    expect(recorder.state, TelemetryRecorderState.idle);
    expect(recorder.canRetryTripSave, isFalse);
    expect(store.manifestWriteAttempts, hasLength(2));
    expect(store.manifestWriteAttempts.toSet(), hasLength(1));
    expect(motion.stopCount, 1);
    expect(location.stopCount, 1);
    expect((await store.readManifest(tripId)).status, 'closed');

    await recorder.dispose();
    expect(states, <TelemetryRecorderState>[
      TelemetryRecorderState.starting,
      TelemetryRecorderState.recording,
      TelemetryRecorderState.stopping,
      TelemetryRecorderState.idle,
      TelemetryRecorderState.stopping,
      TelemetryRecorderState.idle,
      TelemetryRecorderState.disposed,
    ]);
    await motion.controller.close();
    await location.controller.close();
  });

  test('trip stays open when binary writes fail and retains the failed chunk',
      () async {
    final temporary =
        await Directory.systemTemp.createTemp('telemetry_lifecycle_');
    addTearDown(() => temporary.delete(recursive: true));
    final motion = _FakeMotionSource();
    final location = _FakeLocationSource();
    final store = _FlakyStore(temporary)..failChunkWrites = true;
    final recorder = DrivingTelemetryRecorder(
      store: store,
      motionSource: motion,
      locationSource: location,
    );
    final tripId = await recorder.startTrip(userId: 'user-1');
    location.controller.add(
      LocationSample(
        timestampMillis: DateTime.now().millisecondsSinceEpoch,
        latitude: 11.57,
        longitude: 43.14,
        speedMps: 10,
        headingDegrees: 90,
        accuracyMeters: 5,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    await expectLater(recorder.stopTrip(), throwsA(isA<FileSystemException>()));
    final failedId = store.chunkWriteAttempts.first.chunkId;
    expect(recorder.canRetryTripSave, isTrue);
    expect((await store.readManifest(tripId)).status, 'recording');
    expect(store.manifestWriteAttempts, isEmpty);

    store.failChunkWrites = false;
    final result = await recorder.stopTrip();
    final manifest = await store.readManifest(tripId);
    expect(result.locationSampleCount, 1);
    expect(manifest.status, 'closed');
    expect(manifest.chunks.where((chunk) => chunk.chunkId == failedId),
        hasLength(1));
    await recorder.dispose();
    await motion.controller.close();
    await location.controller.close();
  });

  test('retry after a close failure keeps the written manifest artifact',
      () async {
    final temporary =
        await Directory.systemTemp.createTemp('telemetry_lifecycle_');
    addTearDown(() => temporary.delete(recursive: true));
    final motion = _FakeMotionSource();
    final location = _FakeLocationSource();
    final store = _FlakyStore(temporary)..failClose = true;
    final recorder = DrivingTelemetryRecorder(
      store: store,
      motionSource: motion,
      locationSource: location,
    );
    final tripId = await recorder.startTrip(userId: 'user-1');
    await expectLater(recorder.stopTrip(), throwsA(isA<FileSystemException>()));
    final partial = await store.readManifest(tripId);
    expect(partial.status, 'recording');
    expect(partial.chunks.single.type, TelemetryChunkType.tripManifest);
    await store.markUploaded(tripId, partial.chunks.single.chunkId);

    store.failClose = false;
    final result = await recorder.stopTrip();
    final saved = await store.readManifest(tripId);
    expect(result.pendingUploadCount, 0);
    expect(saved.status, 'closed');
    expect(store.manifestWriteAttempts, hasLength(1));
    expect(saved.chunks.single.uploadStatus, ChunkUploadStatus.uploaded);
    await recorder.dispose();
    await motion.controller.close();
    await location.controller.close();
  });

  test('dispose waits for startup, saves the trip, and closes once', () async {
    final temporary =
        await Directory.systemTemp.createTemp('telemetry_lifecycle_');
    addTearDown(() => temporary.delete(recursive: true));
    final startGate = Completer<void>();
    final motion = _FakeMotionSource();
    final location = _FakeLocationSource(startGate: startGate);
    final store = _FlakyStore(temporary);
    final recorder = DrivingTelemetryRecorder(
      store: store,
      motionSource: motion,
      locationSource: location,
    );

    final starting = recorder.startTrip(userId: 'user-1');
    expect(recorder.state, TelemetryRecorderState.starting);
    final disposing = recorder.dispose();
    expect(recorder.dispose(), same(disposing));
    await expectLater(recorder.startTrip(userId: 'user-1'), throwsStateError);
    startGate.complete();
    final tripId = await starting;
    await disposing;

    expect(recorder.state, TelemetryRecorderState.disposed);
    expect(recorder.activeTripId, isNull);
    expect(motion.stopCount, 1);
    expect(location.stopCount, 1);
    expect((await store.readManifest(tripId)).status, 'closed');
    await motion.controller.close();
    await location.controller.close();
  });

  test('dispose joins an in-progress stop without starting another save',
      () async {
    final temporary =
        await Directory.systemTemp.createTemp('telemetry_lifecycle_');
    addTearDown(() => temporary.delete(recursive: true));
    final closeGate = Completer<void>();
    final motion = _FakeMotionSource();
    final location = _FakeLocationSource();
    final store = _FlakyStore(temporary)..closeGate = closeGate;
    final recorder = DrivingTelemetryRecorder(
      store: store,
      motionSource: motion,
      locationSource: location,
    );

    final tripId = await recorder.startTrip(userId: 'user-1');
    final stopping = recorder.stopTrip();
    expect(recorder.state, TelemetryRecorderState.stopping);
    final disposing = recorder.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(recorder.state, TelemetryRecorderState.stopping);
    closeGate.complete();
    expect((await stopping).tripId, tripId);
    await disposing;

    expect(recorder.state, TelemetryRecorderState.disposed);
    expect(store.manifestWriteAttempts, hasLength(1));
    expect(motion.stopCount, 1);
    expect(location.stopCount, 1);
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
