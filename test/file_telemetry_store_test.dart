import 'dart:io';

import 'package:driving_telemetry/driving_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('persists, queues, and acknowledges a chunk', () async {
    final temporary = await Directory.systemTemp.createTemp('telemetry_store_');
    addTearDown(() => temporary.delete(recursive: true));

    final store = FileTelemetryStore(rootDirectory: temporary);
    await store.initialize();
    await store.createTrip(
      tripId: 'trip-1',
      userId: 'user-1',
      startedAtMillis: 1000,
      schemaVersion: TelemetryBinaryCodec.schemaVersion,
    );

    final chunk = TelemetryChunk(
      schemaVersion: TelemetryBinaryCodec.schemaVersion,
      tripId: 'trip-1',
      chunkId: 'chunk-1',
      chunkIndex: 0,
      type: TelemetryChunkType.continuous,
      startedAtMillis: 1000,
      endedAtMillis: 2000,
    );
    final codec = TelemetryBinaryCodec();
    await store.writeChunk(chunk, codec.encode(chunk));

    var pending = await store.listPendingChunks();
    expect(pending, hasLength(1));
    expect(pending.single.chunk.checksumSha256, hasLength(64));

    await store.markUploaded('trip-1', 'chunk-1');
    pending = await store.listPendingChunks();
    expect(pending, isEmpty);

    await store.closeTrip(tripId: 'trip-1', endedAtMillis: 2000);
    final manifest = await store.readManifest('trip-1');
    expect(manifest.status, 'closed');
  });
}
