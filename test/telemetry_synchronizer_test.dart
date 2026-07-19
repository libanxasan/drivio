import 'dart:io';
import 'dart:typed_data';

import 'package:driving_telemetry/driving_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

class _ScriptedBackend implements TelemetryBackendClient {
  _ScriptedBackend(this.failingChunkIds);

  final Set<String> failingChunkIds;
  final List<String> uploadedChunkIds = <String>[];

  @override
  Future<TelemetryUploadReceipt> uploadChunk({
    required PendingTelemetryChunk pending,
    required Uint8List compressedBytes,
  }) async {
    if (failingChunkIds.contains(pending.chunk.chunkId)) {
      throw const TelemetryUploadException(
        statusCode: 503,
        message: 'Service unavailable.',
      );
    }
    uploadedChunkIds.add(pending.chunk.chunkId);
    return const TelemetryUploadReceipt(accepted: true, alreadyExisted: false);
  }
}

void main() {
  test('one failing upload does not abort the pass', () async {
    final temporary = await Directory.systemTemp.createTemp('telemetry_sync_');
    addTearDown(() => temporary.delete(recursive: true));

    final store = FileTelemetryStore(rootDirectory: temporary);
    await store.initialize();
    await store.createTrip(
      tripId: 'trip-1',
      userId: 'user-1',
      startedAtMillis: 1000,
      schemaVersion: TelemetryBinaryCodec.schemaVersion,
    );

    final codec = TelemetryBinaryCodec();
    for (var index = 0; index < 3; index++) {
      final chunk = TelemetryChunk(
        schemaVersion: TelemetryBinaryCodec.schemaVersion,
        tripId: 'trip-1',
        chunkId: 'chunk-$index',
        chunkIndex: index,
        type: TelemetryChunkType.continuous,
        startedAtMillis: 1000 + index * 1000,
        endedAtMillis: 2000 + index * 1000,
      );
      await store.writeChunk(chunk, codec.encode(chunk));
    }

    final backend = _ScriptedBackend(<String>{'chunk-1'});
    final synchronizer = TelemetrySynchronizer(store: store, backend: backend);

    final result = await synchronizer.synchronize();
    expect(result.attempted, 3);
    expect(result.uploaded, 2);
    expect(result.failed, 1);
    expect(backend.uploadedChunkIds, <String>['chunk-0', 'chunk-2']);

    final manifest = await store.readManifest('trip-1');
    final statuses = <String, ChunkUploadStatus>{
      for (final chunk in manifest.chunks) chunk.chunkId: chunk.uploadStatus,
    };
    expect(statuses['chunk-0'], ChunkUploadStatus.uploaded);
    expect(statuses['chunk-1'], ChunkUploadStatus.failed);
    expect(statuses['chunk-2'], ChunkUploadStatus.uploaded);

    final failedChunk = manifest.chunks
        .singleWhere((chunk) => chunk.chunkId == 'chunk-1');
    expect(failedChunk.retryCount, 1);
    expect(failedChunk.lastError, contains('503'));

    // The failed chunk remains pending for the next pass.
    final pending = await store.listPendingChunks();
    expect(pending.map((item) => item.chunk.chunkId), <String>['chunk-1']);

    // A follow-up pass with a healthy backend drains the queue.
    backend.failingChunkIds.clear();
    final retry = await synchronizer.synchronize();
    expect(retry.attempted, 1);
    expect(retry.uploaded, 1);
    expect(retry.failed, 0);
    expect(await store.listPendingChunks(), isEmpty);
  });

  test('uploaded continuous chunk files are deleted when configured', () async {
    final temporary = await Directory.systemTemp.createTemp('telemetry_sync_');
    addTearDown(() => temporary.delete(recursive: true));

    final store = FileTelemetryStore(rootDirectory: temporary);
    await store.initialize();
    await store.createTrip(
      tripId: 'trip-1',
      userId: 'user-1',
      startedAtMillis: 1000,
      schemaVersion: TelemetryBinaryCodec.schemaVersion,
    );

    final codec = TelemetryBinaryCodec();
    final chunk = TelemetryChunk(
      schemaVersion: TelemetryBinaryCodec.schemaVersion,
      tripId: 'trip-1',
      chunkId: 'chunk-0',
      chunkIndex: 0,
      type: TelemetryChunkType.continuous,
      startedAtMillis: 1000,
      endedAtMillis: 2000,
    );
    final stored = await store.writeChunk(chunk, codec.encode(chunk));
    final chunkFile = File('${temporary.path}/driving_telemetry/'
        '${stored.relativePath}');
    expect(await chunkFile.exists(), isTrue);

    final synchronizer = TelemetrySynchronizer(
      store: store,
      backend: _ScriptedBackend(<String>{}),
    );
    final result = await synchronizer.synchronize();
    expect(result.uploaded, 1);
    expect(await chunkFile.exists(), isFalse);

    // Manifest history is retained even though the file is gone.
    final manifest = await store.readManifest('trip-1');
    expect(manifest.chunks.single.uploadStatus, ChunkUploadStatus.uploaded);
  });
}
