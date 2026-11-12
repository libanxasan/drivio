import 'dart:async';

import 'package:driving_telemetry/driving_telemetry.dart';
import 'package:driving_telemetry_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _LocationSource implements LocationSource {
  final permission = Completer<void>();
  final controller = StreamController<LocationSample>(onCancel: () async {});
  int startCount = 0;

  @override
  Stream<LocationSample> get samples => controller.stream;

  @override
  Future<void> start() {
    startCount++;
    return permission.future;
  }

  @override
  Future<void> stop() async {}
}

class _MotionSource implements MotionSource {
  final controller = StreamController<RawMotionSample>(onCancel: () async {});

  @override
  Stream<RawMotionSample> get samples => controller.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

class _TripStore extends FileTelemetryStore {
  final firstSave = Completer<void>();
  late TripManifest _manifest;
  int writeCount = 0;

  @override
  Future<void> initialize() async {}

  @override
  Future<TripManifest> createTrip({
    required String tripId,
    required String userId,
    required int startedAtMillis,
    required int schemaVersion,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async =>
      _manifest = TripManifest(
        tripId: tripId,
        userId: userId,
        startedAtMillis: startedAtMillis,
        schemaVersion: schemaVersion,
        status: 'recording',
        chunks: const [],
        metadata: metadata,
      );

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
  }) async {
    writeCount++;
    if (writeCount == 1) {
      await firstSave.future;
      throw StateError('Simulated write failure.');
    }
    final chunk = StoredTelemetryChunk(
      chunkId: chunkId,
      chunkIndex: chunkIndex,
      type: type,
      startedAtMillis: startedAtMillis,
      endedAtMillis: endedAtMillis,
      schemaVersion: schemaVersion,
      payloadFormat: 'json',
      byteSize: 0,
      checksumSha256: '',
      relativePath: '',
      uploadStatus: ChunkUploadStatus.pending,
    );
    _manifest = _manifest.copyWith(chunks: [chunk]);
    return chunk;
  }

  @override
  Future<void> closeTrip({
    required String tripId,
    required int endedAtMillis,
    Map<String, Object?> metadataUpdates = const <String, Object?>{},
  }) async {
    _manifest =
        _manifest.copyWith(status: 'closed', endedAtMillis: endedAtMillis);
  }

  @override
  Future<TripManifest> readManifest(String tripId) async => _manifest;

  @override
  Future<int> pendingChunkCount(String tripId) async => _manifest.chunks.length;
}

void main() {
  testWidgets('trip screen disables duplicate actions and offers a save retry',
      (tester) async {
    final location = _LocationSource();
    final motion = _MotionSource();
    final store = _TripStore();
    final recorder = DrivingTelemetryRecorder(
      store: store,
      motionSource: motion,
      locationSource: location,
    );
    await tester
        .pumpWidget(TelemetryExampleApp(createRecorder: () => recorder));
    final action = find.byType(FilledButton);

    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(find.text('Starting trip'), findsOneWidget);
    expect(tester.widget<FilledButton>(action).onPressed, isNull);
    await tester.tap(action);
    expect(location.startCount, 1);

    location.permission.complete();
    await tester.pumpAndSettle();
    expect(find.text('Stop trip'), findsOneWidget);

    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(find.text('Saving trip telemetry'), findsOneWidget);
    expect(tester.widget<FilledButton>(action).onPressed, isNull);
    await tester.tap(action);
    expect(store.writeCount, 1);

    store.firstSave.complete();
    await tester.pumpAndSettle();
    expect(find.text('Retry save'), findsOneWidget);
    expect(find.text('Trip saved locally'), findsNothing);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(find.text('Trip saved locally'), findsOneWidget);
    expect(find.text('Chunks: 1'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(recorder.state, TelemetryRecorderState.disposed);
    unawaited(motion.controller.close());
    unawaited(location.controller.close());
  });
}
