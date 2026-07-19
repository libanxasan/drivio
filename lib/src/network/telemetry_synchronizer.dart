import '../model/telemetry_chunk.dart';
import '../storage/telemetry_store.dart';
import 'backend_client.dart';

/// Summary of one synchronization pass.
class TelemetrySyncResult {
  /// Creates a result.
  const TelemetrySyncResult({
    required this.attempted,
    required this.uploaded,
    required this.failed,
  });

  /// Chunks attempted.
  final int attempted;

  /// Chunks acknowledged.
  final int uploaded;

  /// Chunks that failed.
  final int failed;
}

/// Synchronizes locally persisted chunks with idempotent backend uploads.
class TelemetrySynchronizer {
  /// Creates a synchronizer.
  const TelemetrySynchronizer({
    required this.store,
    required this.backend,
    this.deleteUploadedContinuousChunks = true,
    this.deleteUploadedEventEvidence = false,
  });

  /// Local store.
  final TelemetryStore store;

  /// Backend client.
  final TelemetryBackendClient backend;

  /// Whether acknowledged continuous files are removed locally.
  final bool deleteUploadedContinuousChunks;

  /// Whether acknowledged event evidence is removed locally.
  final bool deleteUploadedEventEvidence;

  /// Uploads pending chunks in manifest order.
  Future<TelemetrySyncResult> synchronize({int? maximumChunks}) async {
    final pending = await store.listPendingChunks();
    final selected = maximumChunks == null
        ? pending
        : pending.take(maximumChunks).toList(growable: false);
    var uploaded = 0;
    var failed = 0;

    for (final item in selected) {
      try {
        await store.markUploading(item.tripId, item.chunk.chunkId);
        final bytes = await store.readStoredChunk(item.chunk);
        final receipt = await backend.uploadChunk(
          pending: item,
          compressedBytes: bytes,
        );
        if (!receipt.accepted) {
          throw StateError(receipt.message ?? 'Backend rejected telemetry.');
        }
        await store.markUploaded(item.tripId, item.chunk.chunkId);
        uploaded++;
        if (_shouldDelete(item.chunk.type)) {
          await store.deleteChunkFile(item.tripId, item.chunk.chunkId);
        }
      } catch (error) {
        failed++;
        try {
          await store.markFailed(
            item.tripId,
            item.chunk.chunkId,
            error.toString(),
          );
        } catch (_) {
          // Recording the failure is best-effort; the chunk remains in a
          // non-uploaded state and is retried on the next pass.
        }
      }
    }

    return TelemetrySyncResult(
      attempted: selected.length,
      uploaded: uploaded,
      failed: failed,
    );
  }

  bool _shouldDelete(TelemetryChunkType type) {
    if (type == TelemetryChunkType.continuous) {
      return deleteUploadedContinuousChunks;
    }
    if (type == TelemetryChunkType.eventEvidence) {
      return deleteUploadedEventEvidence;
    }
    return false;
  }
}
