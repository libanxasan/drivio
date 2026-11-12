import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:driving_telemetry/driving_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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

class _CleanupFailingStore extends FileTelemetryStore {
  _CleanupFailingStore(Directory root) : super(rootDirectory: root);

  @override
  Future<void> deleteChunkFile(String tripId, String chunkId) async {
    throw const FileSystemException('Simulated cleanup failure.');
  }
}

Future<Directory> _createRoot() async {
  final root = await Directory.systemTemp.createTemp('telemetry_sync_');
  addTearDown(() => root.delete(recursive: true));
  return root;
}

Future<List<StoredTelemetryChunk>> _seedChunks(
  FileTelemetryStore store, {
  int count = 1,
}) async {
  await store.initialize();
  await store.createTrip(
    tripId: 'trip-1',
    userId: 'user-1',
    startedAtMillis: 1000,
    schemaVersion: TelemetryBinaryCodec.schemaVersion,
  );
  final codec = TelemetryBinaryCodec();
  final chunks = <StoredTelemetryChunk>[];
  for (var index = 0; index < count; index++) {
    final chunk = TelemetryChunk(
      schemaVersion: TelemetryBinaryCodec.schemaVersion,
      tripId: 'trip-1',
      chunkId: 'chunk-$index',
      chunkIndex: index,
      type: TelemetryChunkType.continuous,
      startedAtMillis: 1000 + index * 1000,
      endedAtMillis: 2000 + index * 1000,
    );
    chunks.add(await store.writeChunk(chunk, codec.encode(chunk)));
  }
  return chunks;
}

void main() {
  test('one failing upload does not abort the pass', () async {
    final store = FileTelemetryStore(rootDirectory: await _createRoot());
    await _seedChunks(store, count: 3);

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

    final failedChunk =
        manifest.chunks.singleWhere((chunk) => chunk.chunkId == 'chunk-1');
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
    final root = await _createRoot();
    final store = FileTelemetryStore(rootDirectory: root);
    final stored = (await _seedChunks(store)).single;
    final chunkFile = File('${root.path}/driving_telemetry/'
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

  test('a checksum conflict keeps the chunk on disk until acknowledged',
      () async {
    final store = FileTelemetryStore(rootDirectory: await _createRoot());
    final stored = (await _seedChunks(store)).single;
    final keys = <String?>[];
    final backend = HttpTelemetryBackendClient(
      endpoint: Uri.https('example.test', '/telemetry'),
      client: MockClient((request) async {
        keys.add(request.headers['idempotency-key']);
        if (keys.length == 1) {
          return http.Response(
            '{"message":"Existing idempotency key has a different checksum"}',
            409,
          );
        }
        return http.Response('{"accepted":true,"alreadyExisted":true}', 200);
      }),
    );
    addTearDown(backend.close);
    final synchronizer = TelemetrySynchronizer(store: store, backend: backend);

    final conflict = await synchronizer.synchronize();
    expect(conflict.attempted, 1);
    expect(conflict.uploaded, 0);
    expect(conflict.failed, 1);
    final pending = (await store.listPendingChunks()).single.chunk;
    expect(pending.uploadStatus, ChunkUploadStatus.failed);
    expect(pending.retryCount, 1);
    expect(pending.lastError, contains('different checksum'));
    expect(await store.readStoredChunk(pending), isNotEmpty);

    final retry = await synchronizer.synchronize();
    expect(retry.uploaded, 1);
    expect(retry.failed, 0);
    expect(keys, ['trip-1:chunk-0', 'trip-1:chunk-0']);
    expect(await store.listPendingChunks(), isEmpty);
    await expectLater(
        store.readStoredChunk(stored), throwsA(isA<FileSystemException>()));
  });

  test('accepts legacy empty and explicit duplicate 409 responses', () async {
    final store = FileTelemetryStore(rootDirectory: await _createRoot());
    await _seedChunks(store, count: 3);
    final backend = HttpTelemetryBackendClient(
      endpoint: Uri.https('example.test', '/telemetry'),
      client: MockClient((request) async {
        final body = switch (request.headers['x-chunk-index']) {
          '0' => '',
          '1' => '{"alreadyExisted":true}',
          _ => '{"alreadyExisted":true,"accepted":false}',
        };
        return http.Response(body, 409);
      }),
    );
    addTearDown(backend.close);

    final result = await TelemetrySynchronizer(store: store, backend: backend)
        .synchronize();
    expect(result.attempted, 3);
    expect(result.uploaded, 2);
    expect(result.failed, 1);
    expect((await store.listPendingChunks()).single.chunk.chunkId, 'chunk-2');
  });

  test('cleanup failure preserves acknowledgement and avoids another upload',
      () async {
    final store = _CleanupFailingStore(await _createRoot());
    final stored = (await _seedChunks(store)).single;
    final backend = _ScriptedBackend(<String>{});
    final synchronizer = TelemetrySynchronizer(store: store, backend: backend);

    final result = await synchronizer.synchronize();
    expect(result.attempted, 1);
    expect(result.uploaded, 1);
    expect(result.failed, 0);
    expect(result.cleanupFailed, 1);
    expect(await store.readStoredChunk(stored), isNotEmpty);

    await store.markUploading('trip-1', stored.chunkId);
    await store.markFailed('trip-1', stored.chunkId, 'Stale failure');
    final saved = (await store.readManifest('trip-1')).chunks.single;
    expect(saved.uploadStatus, ChunkUploadStatus.uploaded);
    expect(saved.retryCount, 0);
    expect((await synchronizer.synchronize()).attempted, 0);
    expect(backend.uploadedChunkIds, [stored.chunkId]);
  });

  test('concurrent synchronization passes share the same store lock', () async {
    final store = FileTelemetryStore(rootDirectory: await _createRoot());
    await _seedChunks(store);
    final uploadStarted = Completer<void>();
    final allowAcknowledgement = Completer<void>();
    var uploadCount = 0;
    final backend = HttpTelemetryBackendClient(
      endpoint: Uri.https('example.test', '/telemetry'),
      client: MockClient((_) async {
        uploadCount++;
        if (!uploadStarted.isCompleted) uploadStarted.complete();
        await allowAcknowledgement.future;
        return http.Response('', 200);
      }),
    );
    addTearDown(backend.close);

    final first = TelemetrySynchronizer(store: store, backend: backend)
        .synchronize(maximumChunks: 1);
    await uploadStarted.future;
    final second =
        TelemetrySynchronizer(store: store, backend: backend).synchronize();
    final inFlight = await store.readManifest('trip-1');
    expect(inFlight.chunks.single.uploadStatus, ChunkUploadStatus.uploading);
    allowAcknowledgement.complete();

    expect((await first).uploaded, 1);
    expect((await second).attempted, 0);
    expect(uploadCount, 1);
  });

  test('a cold synchronization resumes chunks left uploading', () async {
    final root = await _createRoot();
    final original = FileTelemetryStore(rootDirectory: root);
    final stored = (await _seedChunks(original)).single;
    await original.markUploading('trip-1', stored.chunkId);

    final reopened = FileTelemetryStore(rootDirectory: root);
    final backend = _ScriptedBackend(<String>{});
    final result =
        await TelemetrySynchronizer(store: reopened, backend: backend)
            .synchronize();

    expect(result.uploaded, 1);
    expect(backend.uploadedChunkIds, [stored.chunkId]);
    expect(await reopened.listPendingChunks(), isEmpty);
  });
}
