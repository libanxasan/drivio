import 'dart:math' as math;

import '../model/trip_manifest.dart';

/// Exponential backoff with jitter for failed chunk uploads.
///
/// The delay after `n` failures is `baseDelay * 2^(n-1)`, capped at
/// [maximumDelay], then spread by up to ±[jitter] so a fleet of phones that
/// went offline together does not retry together. The jitter for a chunk is
/// derived from its ID, so the same chunk always gets the same delay and
/// [isDue] stays stable between calls.
class UploadRetryPolicy {
  /// Creates a policy.
  const UploadRetryPolicy({
    this.baseDelay = const Duration(seconds: 30),
    this.maximumDelay = const Duration(hours: 1),
    this.jitter = 0.2,
  }) : assert(jitter >= 0 && jitter < 1);

  /// A policy that retries every failed chunk on every pass.
  static const UploadRetryPolicy immediate = UploadRetryPolicy(
    baseDelay: Duration.zero,
    maximumDelay: Duration.zero,
    jitter: 0,
  );

  /// Delay after the first failure.
  final Duration baseDelay;

  /// Upper bound before jitter.
  final Duration maximumDelay;

  /// Fraction of the delay used as random spread.
  final double jitter;

  /// Delay before retrying after [failures] failed attempts.
  Duration delayAfter(int failures, {double spread = 0}) {
    if (failures <= 0) return Duration.zero;
    final exponent = math.min(failures - 1, 30);
    final raw = baseDelay.inMilliseconds * math.pow(2, exponent);
    final capped = math.min(raw, maximumDelay.inMilliseconds.toDouble());
    final jittered = capped * (1 + jitter * spread.clamp(-1.0, 1.0));
    return Duration(milliseconds: jittered.round());
  }

  /// Whether [chunk] may be uploaded at [nowMillis].
  bool isDue(StoredTelemetryChunk chunk, int nowMillis) {
    if (chunk.uploadStatus != ChunkUploadStatus.failed) return true;
    final lastAttempt = chunk.lastAttemptAtMillis;
    if (lastAttempt == null) return true;
    final delay = delayAfter(chunk.retryCount, spread: _spreadFor(chunk));
    return nowMillis >= lastAttempt + delay.inMilliseconds;
  }

  /// Stable value in [-1, 1] derived from the chunk ID.
  static double _spreadFor(StoredTelemetryChunk chunk) {
    var hash = 0x811c9dc5;
    for (final unit in chunk.chunkId.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return hash / 0xffffffff * 2 - 1;
  }
}
