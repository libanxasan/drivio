import 'dart:math' as math;

import '../codec/telemetry_binary_codec.dart';
import '../model/telemetry_chunk.dart';
import '../model/trip_manifest.dart';
import '../storage/telemetry_store.dart';

/// A trip that was still open in storage and has been closed by recovery.
class RecoveredTrip {
  /// Creates a recovered trip summary.
  const RecoveredTrip({
    required this.tripId,
    required this.startedAtMillis,
    required this.endedAtMillis,
    required this.chunkCount,
  });

  /// Trip identifier.
  final String tripId;

  /// Trip start time.
  final int startedAtMillis;

  /// End time derived from the last persisted chunk.
  final int endedAtMillis;

  /// Chunks persisted for the trip, including the recovery manifest.
  final int chunkCount;
}

/// Closes trips left open when the app was killed while recording.
///
/// Everything already written to the store is kept. Samples that were still
/// buffered in memory when the process died cannot be recovered; the
/// recorder's checkpoint interval bounds that loss.
///
/// Recovery is idempotent: the manifest chunk ID is derived from the trip ID,
/// and an existing manifest chunk is reused when a previous recovery was
/// interrupted before the trip was closed.
class TelemetryTripRecovery {
  /// Creates a recovery helper for [store].
  const TelemetryTripRecovery(this.store);

  /// Store to recover.
  final TelemetryStore store;

  /// Chunk ID used for the manifest written by recovery.
  static String manifestChunkId(String tripId) => 'manifest_recovered_$tripId';

  /// Closes every open trip except those in [excludeTripIds].
  ///
  /// Call this at app start, before starting a new trip, and never while
  /// another recorder instance (for example a background isolate) may still
  /// be writing to one of the open trips.
  Future<List<RecoveredTrip>> recover({
    Set<String> excludeTripIds = const <String>{},
  }) async {
    await store.initialize();
    final trips = await store.listTrips();
    final recovered = <RecoveredTrip>[];
    for (final manifest in trips) {
      if (manifest.status != 'recording') continue;
      if (excludeTripIds.contains(manifest.tripId)) continue;
      recovered.add(await _recoverTrip(manifest));
    }
    return recovered;
  }

  Future<RecoveredTrip> _recoverTrip(TripManifest manifest) async {
    final tripId = manifest.tripId;
    final dataChunks = manifest.chunks
        .where((chunk) => chunk.type != TelemetryChunkType.tripManifest);
    var endedAt = manifest.startedAtMillis;
    var nextIndex = 0;
    for (final chunk in manifest.chunks) {
      nextIndex = math.max(nextIndex, chunk.chunkIndex + 1);
    }
    for (final chunk in dataChunks) {
      endedAt = math.max(endedAt, chunk.endedAtMillis);
    }

    final hasManifestChunk = manifest.chunks
        .any((chunk) => chunk.type == TelemetryChunkType.tripManifest);
    final metadata = <String, Object?>{
      'recovered': true,
      'recoveredChunkCount': dataChunks.length,
    };
    if (!hasManifestChunk) {
      await store.writeJsonArtifact(
        tripId: tripId,
        chunkId: manifestChunkId(tripId),
        chunkIndex: nextIndex,
        type: TelemetryChunkType.tripManifest,
        startedAtMillis: manifest.startedAtMillis,
        endedAtMillis: endedAt,
        schemaVersion: TelemetryBinaryCodec.schemaVersion,
        value: <String, Object?>{
          'tripId': tripId,
          'startedAtMillis': manifest.startedAtMillis,
          'endedAtMillis': endedAt,
          'schemaVersion': TelemetryBinaryCodec.schemaVersion,
          'status': 'closed',
          'telemetry': metadata,
        },
      );
    }
    await store.closeTrip(
      tripId: tripId,
      endedAtMillis: endedAt,
      metadataUpdates: metadata,
    );
    return RecoveredTrip(
      tripId: tripId,
      startedAtMillis: manifest.startedAtMillis,
      endedAtMillis: endedAt,
      chunkCount: dataChunks.length + 1,
    );
  }
}
