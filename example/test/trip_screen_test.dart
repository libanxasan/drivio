import 'dart:async';
import 'dart:typed_data';

import 'package:driving_telemetry/driving_telemetry.dart';
import 'package:driving_telemetry_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _LocationSource implements LocationSource {
  Completer<void>? permission;
  final controller = StreamController<LocationSample>.broadcast();
  int startCount = 0;

  @override
  Stream<LocationSample> get samples => controller.stream;

  @override
  Future<void> start() async {
    startCount++;
    await permission?.future;
  }

  @override
  Future<void> stop() async {}

  void emit({double speedMps = 12.5, double accuracy = 4}) {
    controller.add(
      LocationSample(
        timestampMillis: DateTime.now().millisecondsSinceEpoch,
        latitude: 11.59,
        longitude: 43.14,
        speedMps: speedMps,
        headingDegrees: 90,
        accuracyMeters: accuracy,
        altitudeMeters: 10,
        speedAccuracyMps: 0.5,
        headingAccuracyDegrees: 5,
        isMocked: false,
      ),
    );
  }
}

class _MotionSource implements MotionSource {
  final controller = StreamController<RawMotionSample>.broadcast();

  @override
  Stream<RawMotionSample> get samples => controller.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

/// In-memory store, so widget tests need no real file or database I/O.
class _MemoryStore implements TelemetryStore {
  final Map<String, TripManifest> _trips = <String, TripManifest>{};
  final Map<String, Uint8List> _payloads = <String, Uint8List>{};
  Completer<void>? manifestGate;
  int manifestFailures = 0;
  int manifestWrites = 0;

  @override
  Future<void> initialize() async {}

  @override
  Future<TripManifest> createTrip({
    required String tripId,
    required String userId,
    required int startedAtMillis,
    required int schemaVersion,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    return _trips[tripId] = TripManifest(
      tripId: tripId,
      userId: userId,
      startedAtMillis: startedAtMillis,
      schemaVersion: schemaVersion,
      status: 'recording',
      chunks: const <StoredTelemetryChunk>[],
      metadata: metadata,
    );
  }

  StoredTelemetryChunk _add(
    String tripId,
    String chunkId,
    int index,
    TelemetryChunkType type,
    int start,
    int end,
    String format,
  ) {
    final chunk = StoredTelemetryChunk(
      chunkId: chunkId,
      chunkIndex: index,
      type: type,
      startedAtMillis: start,
      endedAtMillis: end,
      schemaVersion: TelemetryBinaryCodec.schemaVersion,
      payloadFormat: format,
      byteSize: 1,
      checksumSha256: chunkId,
      relativePath: chunkId,
      uploadStatus: ChunkUploadStatus.pending,
    );
    _payloads[chunkId] = Uint8List.fromList(<int>[1]);
    final trip = _trips[tripId]!;
    _trips[tripId] = trip.copyWith(chunks: <StoredTelemetryChunk>[
      ...trip.chunks.where((value) => value.chunkId != chunkId),
      chunk,
    ]);
    return chunk;
  }

  @override
  Future<StoredTelemetryChunk> writeChunk(
    TelemetryChunk chunk,
    Uint8List uncompressedBytes,
  ) async {
    return _add(
      chunk.tripId,
      chunk.chunkId,
      chunk.chunkIndex,
      chunk.type,
      chunk.startedAtMillis,
      chunk.endedAtMillis,
      'compact-binary',
    );
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
  }) async {
    if (type == TelemetryChunkType.tripManifest) {
      manifestWrites++;
      await manifestGate?.future;
      if (manifestFailures > 0) {
        manifestFailures--;
        throw StateError('Simulated write failure.');
      }
    }
    return _add(
      tripId,
      chunkId,
      chunkIndex,
      type,
      startedAtMillis,
      endedAtMillis,
      'json',
    );
  }

  @override
  Future<void> closeTrip({
    required String tripId,
    required int endedAtMillis,
    Map<String, Object?> metadataUpdates = const <String, Object?>{},
  }) async {
    final trip = _trips[tripId]!;
    _trips[tripId] = trip.copyWith(
      status: 'closed',
      endedAtMillis: endedAtMillis,
      metadata: <String, Object?>{...trip.metadata, ...metadataUpdates},
    );
  }

  @override
  Future<TripManifest> readManifest(String tripId) async => _trips[tripId]!;

  @override
  Future<List<TripManifest>> listTrips() async => _trips.values.toList()
    ..sort((a, b) => b.startedAtMillis.compareTo(a.startedAtMillis));

  @override
  Future<List<PendingTelemetryChunk>> listPendingChunks() async {
    return <PendingTelemetryChunk>[
      for (final trip in _trips.values)
        for (final chunk in trip.chunks)
          if (chunk.uploadStatus != ChunkUploadStatus.uploaded &&
              _payloads.containsKey(chunk.chunkId))
            PendingTelemetryChunk(
              tripId: trip.tripId,
              userId: trip.userId,
              metadata: trip.metadata,
              chunk: chunk,
            ),
    ];
  }

  @override
  Future<Uint8List> readStoredChunk(StoredTelemetryChunk chunk) async =>
      _payloads[chunk.chunkId]!;

  void _update(
    String tripId,
    String chunkId,
    StoredTelemetryChunk Function(StoredTelemetryChunk) change,
  ) {
    final trip = _trips[tripId]!;
    _trips[tripId] = trip.copyWith(
      chunks: <StoredTelemetryChunk>[
        for (final chunk in trip.chunks)
          chunk.chunkId == chunkId &&
                  chunk.uploadStatus != ChunkUploadStatus.uploaded
              ? change(chunk)
              : chunk,
      ],
    );
  }

  @override
  Future<void> markUploading(String tripId, String chunkId) async => _update(
        tripId,
        chunkId,
        (chunk) => chunk.copyWith(uploadStatus: ChunkUploadStatus.uploading),
      );

  @override
  Future<void> markUploaded(String tripId, String chunkId) async => _update(
        tripId,
        chunkId,
        (chunk) => chunk.copyWith(uploadStatus: ChunkUploadStatus.uploaded),
      );

  @override
  Future<void> markFailed(String tripId, String chunkId, String error) async =>
      _update(
        tripId,
        chunkId,
        (chunk) => chunk.copyWith(
          uploadStatus: ChunkUploadStatus.failed,
          retryCount: chunk.retryCount + 1,
          lastError: error,
        ),
      );

  @override
  Future<void> deleteChunkFile(String tripId, String chunkId) async =>
      _payloads.remove(chunkId);

  @override
  Future<int> pendingChunkCount(String tripId) async => _trips[tripId]!
      .chunks
      .where((chunk) => chunk.uploadStatus != ChunkUploadStatus.uploaded)
      .length;
}

class _Backend implements TelemetryBackendClient {
  int uploads = 0;

  @override
  Future<TelemetryUploadReceipt> uploadChunk({
    required PendingTelemetryChunk pending,
    required Uint8List compressedBytes,
  }) async {
    uploads++;
    return const TelemetryUploadReceipt(accepted: true, alreadyExisted: false);
  }
}

class _Harness {
  _Harness({
    TelemetryBackendClient? backend,
    List<RecoveredTrip> recovered = const <RecoveredTrip>[],
  }) {
    recorder = DrivingTelemetryRecorder(
      store: store,
      motionSource: _MotionSource(),
      locationSource: location,
      configuration: const TelemetryConfiguration(
        pauseMotionWhenStationary: false,
      ),
    );
    controller = TripController(
      recorder: recorder,
      store: store,
      userId: 'user-1',
      recovered: recovered,
      scheduler: backend == null
          ? null
          : TelemetrySyncScheduler(
              synchronizer: TelemetrySynchronizer(
                store: store,
                backend: backend,
              ),
              interval: const Duration(hours: 1),
            ),
    );
  }

  final store = _MemoryStore();
  final location = _LocationSource();
  late final DrivingTelemetryRecorder recorder;
  late final TripController controller;

  Future<void> pump(WidgetTester tester) async {
    await controller.initialize();
    await tester.pumpWidget(DrivioExampleApp(controller: controller));
    await tester.pump();
  }

  Future<void> tearDown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.runAsync(() async {
      for (var i = 0; i < 50; i++) {
        if (recorder.state == TelemetryRecorderState.disposed) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(recorder.state, TelemetryRecorderState.disposed);
  }
}

/// Lets recorder work finish. Part of the stop path completes on the real
/// event loop, so fake-time pumps alone do not drain it.
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pump();
}

Finder get _action => find.byKey(const Key('trip-action'));

ButtonStyleButton _actionButton(WidgetTester tester) =>
    tester.widget<ButtonStyleButton>(_action);

void main() {
  testWidgets('records a trip, shows live data, and retries a failed save',
      (tester) async {
    final harness = _Harness();
    harness.location.permission = Completer<void>();
    harness.store
      ..manifestFailures = 1
      ..manifestGate = Completer<void>();
    await harness.pump(tester);
    expect(find.text('Ready'), findsOneWidget);
    expect(find.text('No trips yet.'), findsOneWidget);

    await tester.tap(_action);
    await tester.pump();
    expect(find.text('Starting trip'), findsOneWidget);
    expect(_actionButton(tester).onPressed, isNull);
    await tester.tap(_action);
    expect(harness.location.startCount, 1);

    harness.location.permission!.complete();
    await _settle(tester);
    expect(find.text('Stop trip'), findsOneWidget);

    harness.location.emit();
    await tester.pump();
    expect(find.text('45 km/h'), findsOneWidget);
    expect(find.text('4 m'), findsOneWidget);

    await tester.tap(_action);
    await tester.pump();
    expect(find.text('Saving trip'), findsOneWidget);
    expect(_actionButton(tester).onPressed, isNull);

    harness.store.manifestGate!.complete();
    await _settle(tester);
    expect(find.text('Retry save'), findsOneWidget);
    expect(find.text('Trip save incomplete'), findsOneWidget);

    await tester.tap(_action);
    await _settle(tester);
    expect(find.text('Trip saved'), findsOneWidget);
    expect(find.text('Start trip'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Saved'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Saved'), findsOneWidget);
    expect(harness.store.manifestWrites, 2);
    expect(find.textContaining('Uploads are off'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await harness.tearDown(tester);
  });

  testWidgets('shows recovered trips and hides the notice on dismiss',
      (tester) async {
    final harness = _Harness(
      recovered: const <RecoveredTrip>[
        RecoveredTrip(
          tripId: 'killed',
          startedAtMillis: 0,
          endedAtMillis: 60000,
          chunkCount: 3,
        ),
      ],
    );
    await harness.store.createTrip(
      tripId: 'killed',
      userId: 'user-1',
      startedAtMillis: 0,
      schemaVersion: TelemetryBinaryCodec.schemaVersion,
    );
    await harness.store.closeTrip(
      tripId: 'killed',
      endedAtMillis: 60000,
      metadataUpdates: const <String, Object?>{
        'recovered': true,
        'rawGpsDistanceMeters': 1500.0,
      },
    );
    await harness.pump(tester);

    expect(find.text('1 interrupted trip was recovered'), findsOneWidget);
    expect(find.text('Recovered'), findsOneWidget);
    expect(find.text('0:01:00 · 1.5 km'), findsOneWidget);

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();
    expect(find.text('1 interrupted trip was recovered'), findsNothing);

    await harness.tearDown(tester);
  });

  testWidgets('going to the background checkpoints buffered samples',
      (tester) async {
    final harness = _Harness();
    await harness.pump(tester);
    await tester.tap(_action);
    await _settle(tester);
    harness.location.emit();
    await tester.pump();

    harness.controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    await _settle(tester);

    final trips = await harness.store.listTrips();
    expect(trips.single.status, 'recording');
    expect(trips.single.chunks, hasLength(1));
    expect(harness.recorder.isRecording, isTrue);

    await harness.tearDown(tester);
  });

  testWidgets('uploads saved chunks on demand', (tester) async {
    final backend = _Backend();
    final harness = _Harness(backend: backend);
    await harness.pump(tester);
    expect(find.text('Upload now'), findsOneWidget);

    await tester.tap(_action);
    await _settle(tester);
    harness.location.emit();
    await tester.pump();
    await tester.tap(_action);
    await _settle(tester);

    await tester.tap(find.text('Upload now'));
    await _settle(tester);
    expect(backend.uploads, greaterThan(0));
    expect(find.text('All uploaded'), findsOneWidget);
    expect(find.textContaining('uploaded at'), findsOneWidget);

    await harness.tearDown(tester);
  });
}
