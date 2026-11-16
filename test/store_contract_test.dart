import 'dart:io';
import 'dart:typed_data';

import 'package:driving_telemetry/driving_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/stores.dart';

Future<StoredTelemetryChunk> _write(
  TelemetryStore store,
  String tripId,
  int index,
) {
  final chunk = TelemetryChunk(
    schemaVersion: TelemetryBinaryCodec.schemaVersion,
    tripId: tripId,
    chunkId: '$tripId-chunk-$index',
    chunkIndex: index,
    type: TelemetryChunkType.continuous,
    startedAtMillis: 1000 + index * 1000,
    endedAtMillis: 2000 + index * 1000,
  );
  return store.writeChunk(chunk, TelemetryBinaryCodec().encode(chunk));
}

Future<void> _createTrip(TelemetryStore store, String tripId, int start) {
  return store.createTrip(
    tripId: tripId,
    userId: 'user-1',
    startedAtMillis: start,
    schemaVersion: TelemetryBinaryCodec.schemaVersion,
    metadata: <String, Object?>{'vehicle': tripId},
  );
}

void main() {
  for (final entry in storeFactories.entries) {
    group('${entry.key} store contract', () {
      late TelemetryStore store;

      setUp(() async {
        store = entry.value(await temporaryDirectory(addTearDown));
        await store.initialize();
        await store.initialize();
      });

      test('round-trips payloads and lists pending chunks in order', () async {
        await _createTrip(store, 'trip-b', 2000);
        await _createTrip(store, 'trip-a', 1000);
        await _write(store, 'trip-b', 1);
        await _write(store, 'trip-b', 0);
        final stored = await _write(store, 'trip-a', 0);

        final pending = await store.listPendingChunks();
        expect(
          pending.map((item) => item.chunk.chunkId),
          <String>['trip-a-chunk-0', 'trip-b-chunk-0', 'trip-b-chunk-1'],
        );
        expect(pending.first.userId, 'user-1');
        expect(pending.first.metadata['vehicle'], 'trip-a');

        final bytes = await store.readStoredChunk(stored);
        expect(bytes, hasLength(stored.byteSize));
        expect(gzip.decode(bytes), isNotEmpty);
      });

      test('tracks upload state and never downgrades uploaded chunks',
          () async {
        await _createTrip(store, 'trip-1', 1000);
        await _write(store, 'trip-1', 0);
        await _write(store, 'trip-1', 1);

        await store.markUploading('trip-1', 'trip-1-chunk-0');
        await store.markFailed('trip-1', 'trip-1-chunk-0', 'offline');
        var manifest = await store.readManifest('trip-1');
        final failed = manifest.chunks.first;
        expect(failed.uploadStatus, ChunkUploadStatus.failed);
        expect(failed.retryCount, 1);
        expect(failed.lastError, 'offline');
        expect(failed.lastAttemptAtMillis, isNotNull);

        await store.markUploaded('trip-1', 'trip-1-chunk-0');
        await store.markFailed('trip-1', 'trip-1-chunk-0', 'late failure');
        manifest = await store.readManifest('trip-1');
        expect(manifest.chunks.first.uploadStatus, ChunkUploadStatus.uploaded);
        expect(await store.pendingChunkCount('trip-1'), 1);

        await store.deleteChunkFile('trip-1', 'trip-1-chunk-1');
        expect(await store.listPendingChunks(), isEmpty);
        expect(await store.pendingChunkCount('trip-1'), 1);
      });

      test('closes trips, merges metadata and lists newest first', () async {
        await _createTrip(store, 'old', 1000);
        await _createTrip(store, 'new', 5000);
        await store.writeJsonArtifact(
          tripId: 'old',
          chunkId: 'manifest',
          chunkIndex: 0,
          type: TelemetryChunkType.tripManifest,
          startedAtMillis: 1000,
          endedAtMillis: 3000,
          schemaVersion: TelemetryBinaryCodec.schemaVersion,
          value: const <String, Object?>{'status': 'closed'},
        );
        await store.closeTrip(
          tripId: 'old',
          endedAtMillis: 3000,
          metadataUpdates: const <String, Object?>{'distance': 12.5},
        );

        final trips = await store.listTrips();
        expect(trips.map((trip) => trip.tripId), <String>['new', 'old']);
        final old = trips.last;
        expect(old.status, 'closed');
        expect(old.endedAtMillis, 3000);
        expect(old.metadata, <String, Object?>{
          'vehicle': 'old',
          'distance': 12.5,
        });
        expect(old.chunks.single.payloadFormat, 'json');
      });

      test('rewriting a chunk ID replaces it', () async {
        await _createTrip(store, 'trip-1', 1000);
        await _write(store, 'trip-1', 0);
        await _write(store, 'trip-1', 0);
        expect((await store.readManifest('trip-1')).chunks, hasLength(1));
      });
    });
  }

  group('sqlite store', () {
    test('data survives reopening and is shared between connections',
        () async {
      final directory = await temporaryDirectory(addTearDown);
      final first = SqliteTelemetryStore(rootDirectory: directory);
      await first.initialize();
      await _createTrip(first, 'trip-1', 1000);
      await _write(first, 'trip-1', 0);

      final second = SqliteTelemetryStore(rootDirectory: directory);
      await second.initialize();
      expect(await second.listPendingChunks(), hasLength(1));
      await second.markUploaded('trip-1', 'trip-1-chunk-0');
      expect(await first.listPendingChunks(), isEmpty);

      await first.close();
      await second.close();
      final reopened = SqliteTelemetryStore(rootDirectory: directory);
      await reopened.initialize();
      expect(
        (await reopened.readManifest('trip-1')).chunks.single.uploadStatus,
        ChunkUploadStatus.uploaded,
      );
      await reopened.close();
    });

    test('imports a file store once and keeps upload state', () async {
      final directory = await temporaryDirectory(addTearDown);
      final files = FileTelemetryStore(rootDirectory: directory);
      await files.initialize();
      await _createTrip(files, 'legacy', 1000);
      await _write(files, 'legacy', 0);
      await _write(files, 'legacy', 1);
      await files.markUploaded('legacy', 'legacy-chunk-0');
      await files.deleteChunkFile('legacy', 'legacy-chunk-0');
      await files.closeTrip(tripId: 'legacy', endedAtMillis: 3000);

      final sqlite = SqliteTelemetryStore(rootDirectory: directory);
      await sqlite.initialize();
      expect(await sqlite.importFileStore(), 1);
      expect(await sqlite.importFileStore(), 0);

      final manifest = await sqlite.readManifest('legacy');
      expect(manifest.status, 'closed');
      expect(manifest.chunks, hasLength(2));
      final pending = await sqlite.listPendingChunks();
      expect(pending.single.chunk.chunkId, 'legacy-chunk-1');
      final original = (await files.readManifest('legacy')).chunks.last;
      expect(
        await sqlite.readStoredChunk(pending.single.chunk),
        await files.readStoredChunk(original),
      );

      expect(await sqlite.importFileStore(deleteImported: true), 0);
      expect(
        await Directory('${directory.path}/driving_telemetry/trips/legacy')
            .exists(),
        isFalse,
      );
      await sqlite.close();
    });

    test('rejects a duplicate trip ID', () async {
      final store = SqliteTelemetryStore(
        rootDirectory: await temporaryDirectory(addTearDown),
      );
      await store.initialize();
      await _createTrip(store, 'trip-1', 1000);
      await expectLater(_createTrip(store, 'trip-1', 1000), throwsA(anything));
      await store.close();
    });
  });

  test('large payloads are compressed in a background isolate', () async {
    const compressor = PayloadCompressor(isolateThresholdBytes: 0);
    final payload = await compressor.compress(
      Uint8List.fromList(List<int>.generate(100000, (index) => index % 7)),
    );
    expect(gzip.decode(payload.bytes), hasLength(100000));
    expect(payload.checksumSha256, hasLength(64));
  });
}
