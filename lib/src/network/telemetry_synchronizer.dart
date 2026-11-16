import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../model/telemetry_chunk.dart';
import '../storage/telemetry_store.dart';
import '../utils/async_mutex.dart';
import 'backend_client.dart';
import 'http_backend_client.dart';
import 'retry_policy.dart';

/// Summary of one synchronization pass.
class TelemetrySyncResult {
  /// Creates a result.
  const TelemetrySyncResult({
    required this.attempted,
    required this.uploaded,
    required this.failed,
    this.cleanupFailed = 0,
    this.deferred = 0,
    this.remaining = 0,
    this.interrupted = false,
  });

  /// Chunks attempted.
  final int attempted;

  /// Chunks acknowledged.
  final int uploaded;

  /// Chunks whose upload or local acknowledgement failed.
  final int failed;

  /// Acknowledged chunks whose local file could not be removed.
  final int cleanupFailed;

  /// Failed chunks skipped because their retry delay has not elapsed.
  final int deferred;

  /// Chunks left for a later pass because of [maximumChunks], the time
  /// budget, or an interrupted pass.
  final int remaining;

  /// Whether the pass stopped early after a connectivity or server
  /// availability failure.
  final bool interrupted;

  /// Whether every due chunk was uploaded.
  bool get isComplete => failed == 0 && remaining == 0 && !interrupted;
}

/// Synchronizes locally persisted chunks with idempotent backend uploads.
class TelemetrySynchronizer {
  /// Creates a synchronizer.
  const TelemetrySynchronizer({
    required this.store,
    required this.backend,
    this.deleteUploadedContinuousChunks = true,
    this.deleteUploadedEventEvidence = false,
    this.retryPolicy = const UploadRetryPolicy(),
    this.stopOnUnavailable = true,
    this.clock = _systemMillis,
  });

  static int _systemMillis() => DateTime.now().millisecondsSinceEpoch;

  /// Local store.
  final TelemetryStore store;

  /// Backend client.
  final TelemetryBackendClient backend;

  /// Whether acknowledged continuous files are removed locally.
  final bool deleteUploadedContinuousChunks;

  /// Whether acknowledged event evidence is removed locally.
  final bool deleteUploadedEventEvidence;

  /// Backoff applied to chunks whose last upload failed.
  final UploadRetryPolicy retryPolicy;

  /// Ends the pass after a network failure, a timeout, or an HTTP 429 or
  /// 503 response, instead of trying every remaining chunk against a backend
  /// that cannot be reached.
  final bool stopOnUnavailable;

  /// Wall clock in milliseconds, replaceable in tests.
  final int Function() clock;

  static final _storeLocks = Expando<AsyncMutex>();

  /// Uploads pending chunks in manifest order.
  /// Passes using the same store instance run in order.
  ///
  /// With [timeBudget], no new upload starts once the budget is spent, which
  /// keeps a pass inside the short windows OS background tasks allow.
  Future<TelemetrySyncResult> synchronize({
    int? maximumChunks,
    Duration? timeBudget,
  }) {
    final lock = _storeLocks[store] ??= AsyncMutex();
    return lock.protect(() => _synchronize(maximumChunks, timeBudget));
  }

  Future<TelemetrySyncResult> _synchronize(
    int? maximumChunks,
    Duration? timeBudget,
  ) async {
    final stopwatch = Stopwatch()..start();
    await store.initialize();
    final pending = await store.listPendingChunks();
    final now = clock();
    final due = pending
        .where((item) => retryPolicy.isDue(item.chunk, now))
        .toList(growable: false);
    final selected = maximumChunks == null
        ? due
        : due.take(maximumChunks).toList(growable: false);
    var attempted = 0;
    var uploaded = 0;
    var failed = 0;
    var cleanupFailed = 0;
    var interrupted = false;

    for (final item in selected) {
      if (timeBudget != null && stopwatch.elapsed >= timeBudget) break;
      attempted++;
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
        if (stopOnUnavailable && _isUnavailable(error)) {
          interrupted = true;
          break;
        }
        continue;
      }

      uploaded++;
      if (_shouldDelete(item.chunk.type)) {
        try {
          await store.deleteChunkFile(item.tripId, item.chunk.chunkId);
        } catch (_) {
          cleanupFailed++;
        }
      }
    }

    return TelemetrySyncResult(
      attempted: attempted,
      uploaded: uploaded,
      failed: failed,
      cleanupFailed: cleanupFailed,
      deferred: pending.length - due.length,
      remaining: due.length - attempted,
      interrupted: interrupted,
    );
  }

  static bool _isUnavailable(Object error) {
    if (error is IOException ||
        error is TimeoutException ||
        error is http.ClientException) {
      return true;
    }
    return error is TelemetryUploadException &&
        (error.statusCode == 429 || error.statusCode == 503);
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
